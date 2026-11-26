import XCTest
@testable import CodexTokenBar

private final class ManualUnreadRenderExecutor: FloatingUnreadFrameRenderExecuting, @unchecked Sendable {
    private var operations: [@Sendable () -> Void] = []

    var pendingCount: Int { operations.count }

    func execute(_ operation: @escaping @Sendable () -> Void) {
        operations.append(operation)
    }

    func runNext() {
        operations.removeFirst()()
    }
}

private final class ManualUnreadCompletionDispatcher: FloatingUnreadFrameCompletionDispatching, @unchecked Sendable {
    private var operations: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int { operations.count }

    func dispatch(_ operation: @escaping @MainActor @Sendable () -> Void) {
        operations.append(operation)
    }

    @MainActor
    func runAll() {
        let pending = operations
        operations.removeAll()
        pending.forEach { $0() }
    }
}

private final class UnreadRenderCounter: @unchecked Sendable {
    var value = 0
}

private final class UnreadFrameReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func recordRelease() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@MainActor
private final class UnreadApplyRecorder {
    var frameCounts: [Int] = []
}

final class FloatingUnreadEffectsTests: XCTestCase {
    @MainActor
    func testFrameCacheMissReturnsImmediatelyAndSingleFlightsSameDescriptor() throws {
        let renderExecutor = ManualUnreadRenderExecutor()
        let completionDispatcher = ManualUnreadCompletionDispatcher()
        let storage = FloatingUnreadFrameCacheStorage(
            renderExecutor: renderExecutor,
            completionDispatcher: completionDispatcher
        )
        let consumer = storage.registerConsumer()
        defer { withExtendedLifetime(consumer) {} }
        let descriptor = makeDescriptor(effect: "single-flight")
        let frame = try makeFrame()
        let renderCounter = UnreadRenderCounter()
        let applyRecorder = UnreadApplyRecorder()
        let render: @Sendable () -> [CGImage] = {
            renderCounter.value += 1
            return [frame]
        }

        let first = storage.requestFrames(
            descriptor: descriptor,
            render: render,
            completion: { applyRecorder.frameCounts.append($0.count) }
        )
        let second = storage.requestFrames(
            descriptor: descriptor,
            render: render,
            completion: { applyRecorder.frameCounts.append($0.count) }
        )

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(renderCounter.value, 0, "A miss must only enqueue background rendering.")
        XCTAssertEqual(renderExecutor.pendingCount, 1)

        renderExecutor.runNext()
        XCTAssertEqual(renderCounter.value, 1)
        XCTAssertEqual(completionDispatcher.pendingCount, 1)
        XCTAssertTrue(applyRecorder.frameCounts.isEmpty)

        completionDispatcher.runAll()
        XCTAssertEqual(applyRecorder.frameCounts, [1, 1])

        let cached = storage.requestFrames(
            descriptor: descriptor,
            render: render,
            completion: { _ in XCTFail("A cache hit should be returned directly.") }
        )
        XCTAssertEqual(cached?.count, 1)
        XCTAssertEqual(renderCounter.value, 1)
        XCTAssertEqual(renderExecutor.pendingCount, 0)
    }

    @MainActor
    func testFrameCacheKeepsSharedFramesUntilLastConsumerLeaves() throws {
        let executor = ManualUnreadRenderExecutor()
        let dispatcher = ManualUnreadCompletionDispatcher()
        let storage = FloatingUnreadFrameCacheStorage(renderExecutor: executor, completionDispatcher: dispatcher)
        var first: FloatingUnreadFrameCacheConsumer? = storage.registerConsumer()
        var second: FloatingUnreadFrameCacheConsumer? = storage.registerConsumer()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        let descriptor = makeDescriptor(effect: "shared-consumers")
        let frame = try makeFrame()
        XCTAssertNil(storage.requestFrames(descriptor: descriptor, render: { [frame] }, completion: { _ in }))
        executor.runNext()
        dispatcher.runAll()

        first = nil
        XCTAssertNotNil(storage.requestFrames(descriptor: descriptor, render: { [frame] }, completion: { _ in
            XCTFail("The remaining consumer must keep the shared cache usable.")
        }))
        XCTAssertEqual(executor.pendingCount, 0)

        second = nil
        let next = storage.registerConsumer()
        defer { withExtendedLifetime(next) {} }
        XCTAssertNil(storage.requestFrames(descriptor: descriptor, render: { [frame] }, completion: { _ in }))
        XCTAssertEqual(executor.pendingCount, 1, "The last departure must evict the previous lifecycle's frames.")
    }

    @MainActor
    func testFrameCacheReleasesImageStorageAfterLastConsumerLeaves() {
        let executor = ManualUnreadRenderExecutor()
        let dispatcher = ManualUnreadCompletionDispatcher()
        let storage = FloatingUnreadFrameCacheStorage(renderExecutor: executor, completionDispatcher: dispatcher)
        var consumer: FloatingUnreadFrameCacheConsumer? = storage.registerConsumer()
        XCTAssertNotNil(consumer)
        let releases = UnreadFrameReleaseCounter()
        XCTAssertNil(storage.requestFrames(
            descriptor: makeDescriptor(effect: "release-storage"),
            render: { Self.makeTrackedFrames(releases: releases) }, completion: { _ in }
        ))
        executor.runNext()
        dispatcher.runAll()
        XCTAssertEqual(releases.value, 0)

        consumer = nil
        XCTAssertEqual(releases.value, 1, "Eviction must release actual image-provider storage, not just a key.")
    }

    @MainActor
    func testFrameCacheDoesNotRefillAfterLastConsumerLeavesDuringRender() {
        let executor = ManualUnreadRenderExecutor()
        let dispatcher = ManualUnreadCompletionDispatcher()
        let storage = FloatingUnreadFrameCacheStorage(renderExecutor: executor, completionDispatcher: dispatcher)
        var consumer: FloatingUnreadFrameCacheConsumer? = storage.registerConsumer()
        XCTAssertNotNil(consumer)
        let releases = UnreadFrameReleaseCounter()
        let recorder = UnreadApplyRecorder()
        let descriptor = makeDescriptor(effect: "late-render")
        XCTAssertNil(storage.requestFrames(
            descriptor: descriptor,
            render: { Self.makeTrackedFrames(releases: releases) },
            completion: { recorder.frameCounts.append($0.count) }
        ))
        consumer = nil
        executor.runNext()
        XCTAssertEqual(releases.value, 0, "The queued completion still owns its result until delivery.")
        dispatcher.runAll()
        XCTAssertEqual(recorder.frameCounts, [1], "Delivery semantics and caller generation checks stay intact.")
        XCTAssertEqual(releases.value, 1, "A render finishing after departure must not repopulate the cache.")

        let next = storage.registerConsumer()
        defer { withExtendedLifetime(next) {} }
        XCTAssertNil(storage.requestFrames(descriptor: descriptor, render: { [] }, completion: { _ in }))
        XCTAssertEqual(executor.pendingCount, 1)
    }

    @MainActor
    func testFrameCacheNewConsumerReusesPendingRenderAfterPriorDeparture() throws {
        let executor = ManualUnreadRenderExecutor()
        let dispatcher = ManualUnreadCompletionDispatcher()
        let storage = FloatingUnreadFrameCacheStorage(renderExecutor: executor, completionDispatcher: dispatcher)
        var prior: FloatingUnreadFrameCacheConsumer? = storage.registerConsumer()
        XCTAssertNotNil(prior)
        let descriptor = makeDescriptor(effect: "rejoin-in-flight")
        let frame = try makeFrame()
        let recorder = UnreadApplyRecorder()
        XCTAssertNil(storage.requestFrames(descriptor: descriptor, render: { [frame] }, completion: {
            recorder.frameCounts.append($0.count)
        }))
        prior = nil
        let current = storage.registerConsumer()
        defer { withExtendedLifetime(current) {} }
        XCTAssertNil(storage.requestFrames(descriptor: descriptor, render: { [frame] }, completion: {
            recorder.frameCounts.append($0.count)
        }))
        XCTAssertEqual(executor.pendingCount, 1)
        executor.runNext()
        dispatcher.runAll()
        XCTAssertEqual(recorder.frameCounts, [1, 1])
        XCTAssertNotNil(storage.requestFrames(descriptor: descriptor, render: { [frame] }, completion: { _ in }))
        XCTAssertEqual(executor.pendingCount, 0)
    }

    @MainActor
    func testRenderCoordinatorRejectsOldGenerationAndInvalidatedView() {
        let coordinator = FloatingUnreadRenderRequestCoordinator()
        let firstDescriptor = makeDescriptor(effect: "ripple-a")
        let secondDescriptor = makeDescriptor(effect: "ripple-b")

        let first = coordinator.begin(descriptor: firstDescriptor)
        XCTAssertNotNil(first)
        XCTAssertNil(coordinator.begin(descriptor: firstDescriptor), "One view should not resubmit the same pending descriptor.")

        let second = coordinator.begin(descriptor: secondDescriptor)
        XCTAssertNotNil(second)
        XCTAssertFalse(coordinator.accepts(first!))
        XCTAssertTrue(coordinator.accepts(second!))

        coordinator.invalidate()
        XCTAssertFalse(coordinator.accepts(second!))
        XCTAssertNotNil(coordinator.begin(descriptor: secondDescriptor), "A new view lifecycle may retry once.")
    }

    func testDefaultUnreadCompletionDispatcherReturnsToMainActor() async {
        let dispatcher = FloatingUnreadMainCompletionDispatcher()

        await withCheckedContinuation { continuation in
            dispatcher.dispatch {
                XCTAssertTrue(Thread.isMainThread)
                continuation.resume()
            }
        }
    }

    func testRippleEffectDoesNotDrawEdgeGlowHighlight() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rippleEffect = projectRoot.appendingPathComponent("Sources/CodexTokenBar/FloatingUnreadRippleEffect.swift")
        let source = try String(contentsOf: rippleEffect, encoding: .utf8)

        XCTAssertFalse(source.contains("drawEdgeContact"))
        XCTAssertFalse(source.contains("drawEdgeGlow"))
    }

    func testDefaultRippleSizeKeepsRetinaBackingScaleWithinBudget() throws {
        let size = FloatingTokenPanelMetrics.baseSize
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: 3.25,
            targetFramesPerSecond: 30
        )

        let scale = try XCTUnwrap(FloatingUnreadFrameBudget.cappedBackingScale(
            size: size,
            preferredScale: 2,
            frameCount: frameCount
        ))

        XCTAssertEqual(scale, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            FloatingUnreadFrameBudget.estimatedBytes(size: size, backingScale: scale, frameCount: frameCount),
            FloatingUnreadFrameBudget.maxFrameSequenceBytes
        )
    }

    func testLargeRippleSizeDownsamplesInsteadOfExceedingFrameBudget() throws {
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: 3.25,
            targetFramesPerSecond: 30
        )
        let largeSize = CGSize(width: 516, height: 176)

        let scale = try XCTUnwrap(FloatingUnreadFrameBudget.cappedBackingScale(
            size: largeSize,
            preferredScale: 2,
            frameCount: frameCount
        ))

        XCTAssertLessThan(scale, 2)
        XCTAssertGreaterThanOrEqual(scale, 1)
        XCTAssertLessThanOrEqual(
            FloatingUnreadFrameBudget.estimatedBytes(size: largeSize, backingScale: scale, frameCount: frameCount),
            FloatingUnreadFrameBudget.maxFrameSequenceBytes
        )
    }

    func testOversizedUnreadEffectSkipsPrerenderingWhenOneXStillExceedsBudget() {
        let frameCount = FloatingUnreadFrameBudget.frameCount(
            cycleDuration: 3.25,
            targetFramesPerSecond: 30
        )

        let scale = FloatingUnreadFrameBudget.cappedBackingScale(
            size: CGSize(width: 800, height: 400),
            preferredScale: 2,
            frameCount: frameCount
        )

        XCTAssertNil(scale)
    }

    private func makeDescriptor(effect: String) -> FloatingUnreadFrameCacheDescriptor {
        FloatingUnreadFrameCacheDescriptor(
            effect: effect,
            size: CGSize(width: 1, height: 1),
            backingScale: 1,
            color: FloatingUnreadRenderColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1),
            cornerRadius: 1,
            scale: 1,
            cycleDuration: 1,
            activeFraction: 1,
            framesPerSecond: 1
        )
    }

    private func makeFrame() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    private static func makeTrackedFrames(releases: UnreadFrameReleaseCounter) -> [CGImage] {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 4)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: 4)
        let info = Unmanaged.passRetained(releases).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: bytes, size: 4, releaseData: { info, bytes, _ in
            UnsafeMutableRawPointer(mutating: bytes).deallocate()
            if let info {
                Unmanaged<UnreadFrameReleaseCounter>.fromOpaque(info).takeRetainedValue().recordRelease()
            }
        }) else {
            bytes.deallocate()
            Unmanaged<UnreadFrameReleaseCounter>.fromOpaque(info).release()
            return []
        }
        guard let image = CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return [] }
        return [image]
    }
}

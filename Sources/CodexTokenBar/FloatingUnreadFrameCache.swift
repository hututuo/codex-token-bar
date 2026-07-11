import AppKit
import Foundation

enum FloatingUnreadFrameBudget {
    static let maxFrameSequenceBytes = 48 * 1024 * 1024
    static let frameCacheLimitBytes = 96 * 1024 * 1024
    static let minBackingScale: CGFloat = 1
    static let maxBackingScale: CGFloat = 2

    static func frameCount(cycleDuration: CFTimeInterval, targetFramesPerSecond: Int) -> Int {
        max(1, Int((cycleDuration * Double(targetFramesPerSecond)).rounded(.up)))
    }

    static func estimatedBytes(size: CGSize, backingScale: CGFloat, frameCount: Int) -> Int {
        let pixelWidth = max(1, Int((size.width * backingScale).rounded(.up)))
        let pixelHeight = max(1, Int((size.height * backingScale).rounded(.up)))
        return estimatedBytes(pixelWidth: pixelWidth, pixelHeight: pixelHeight, frameCount: frameCount)
    }

    static func estimatedBytes(pixelWidth: Int, pixelHeight: Int, frameCount: Int) -> Int {
        max(1, pixelWidth) * max(1, pixelHeight) * 4 * max(1, frameCount)
    }

    static func cappedBackingScale(size: CGSize, preferredScale: CGFloat, frameCount: Int) -> CGFloat? {
        let preferredScale = min(max(preferredScale, minBackingScale), maxBackingScale)
        if estimatedBytes(size: size, backingScale: preferredScale, frameCount: frameCount) <= maxFrameSequenceBytes {
            return preferredScale
        }

        let logicalPixels = max(size.width * size.height, 1)
        let maxScale = sqrt(CGFloat(maxFrameSequenceBytes) / (logicalPixels * 4 * CGFloat(max(frameCount, 1))))
        var cappedScale = min(preferredScale, maxScale) * 0.99
        while cappedScale >= minBackingScale,
              estimatedBytes(size: size, backingScale: cappedScale, frameCount: frameCount) > maxFrameSequenceBytes {
            cappedScale -= 0.01
        }
        guard cappedScale >= minBackingScale,
              estimatedBytes(size: size, backingScale: cappedScale, frameCount: frameCount) <= maxFrameSequenceBytes else {
            return nil
        }
        return cappedScale
    }
}

struct FloatingUnreadRenderColor: Hashable, Sendable {
    static let clear = FloatingUnreadRenderColor(red: 0, green: 0, blue: 0, alpha: 0)
    static let white = FloatingUnreadRenderColor(red: 1, green: 1, blue: 1, alpha: 1)

    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    @MainActor
    init(_ color: NSColor) {
        let color = FloatingPanelColorTools.deviceRGB(color)
        self.init(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }

    func isApproximatelyEqual(to other: Self) -> Bool {
        abs(red - other.red) < 0.001
            && abs(green - other.green) < 0.001
            && abs(blue - other.blue) < 0.001
            && abs(alpha - other.alpha) < 0.001
    }

    nonisolated func cgColor(alpha overrideAlpha: CGFloat? = nil) -> CGColor {
        CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [red, green, blue, min(max(overrideAlpha ?? alpha, 0), 1)]
        )!
    }
}

struct FloatingUnreadFrameCacheDescriptor: Hashable, Sendable {
    let effect: String
    let pixelWidth: Int
    let pixelHeight: Int
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int
    let cornerRadius: Int
    let scale: Int
    let cycleMilliseconds: Int
    let activeFractionPermille: Int
    let framesPerSecond: Int

    init(
        effect: String,
        size: CGSize,
        backingScale: CGFloat,
        color: FloatingUnreadRenderColor,
        cornerRadius: CGFloat,
        scale: CGFloat,
        cycleDuration: CFTimeInterval,
        activeFraction: Double,
        framesPerSecond: Int
    ) {
        self.effect = effect
        self.pixelWidth = max(1, Int((size.width * backingScale).rounded(.up)))
        self.pixelHeight = max(1, Int((size.height * backingScale).rounded(.up)))
        self.red = Self.quantizeColor(color.red)
        self.green = Self.quantizeColor(color.green)
        self.blue = Self.quantizeColor(color.blue)
        self.alpha = Self.quantizeColor(color.alpha)
        self.cornerRadius = Self.quantize(cornerRadius, multiplier: 100)
        self.scale = Self.quantize(scale, multiplier: 100)
        self.cycleMilliseconds = Self.quantize(CGFloat(cycleDuration), multiplier: 1000)
        self.activeFractionPermille = Self.quantize(CGFloat(activeFraction), multiplier: 1000)
        self.framesPerSecond = framesPerSecond
    }

    private static func quantizeColor(_ value: CGFloat) -> Int {
        min(max(Int((value * 255).rounded()), 0), 255)
    }

    private static func quantize(_ value: CGFloat, multiplier: CGFloat) -> Int {
        Int((value * multiplier).rounded())
    }
}

private final class FloatingUnreadFrameCacheKey: NSObject {
    let descriptor: FloatingUnreadFrameCacheDescriptor

    init(_ descriptor: FloatingUnreadFrameCacheDescriptor) {
        self.descriptor = descriptor
    }

    override var hash: Int {
        descriptor.hashValue
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FloatingUnreadFrameCacheKey else { return false }
        return descriptor == other.descriptor
    }
}

private final class FloatingUnreadFrameSequence {
    let frames: [CGImage]
    let byteCost: Int

    init(frames: [CGImage], byteCost: Int) {
        self.frames = frames
        self.byteCost = byteCost
    }
}

protocol FloatingUnreadFrameRenderExecuting: Sendable {
    func execute(_ operation: @escaping @Sendable () -> Void)
}

struct FloatingUnreadSerialRenderExecutor: FloatingUnreadFrameRenderExecuting, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.codextokenbar.unread-frame-render",
        qos: .userInitiated
    )

    func execute(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

protocol FloatingUnreadFrameCompletionDispatching: Sendable {
    func dispatch(_ operation: @escaping @MainActor @Sendable () -> Void)
}

struct FloatingUnreadMainCompletionDispatcher: FloatingUnreadFrameCompletionDispatching {
    func dispatch(_ operation: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            operation()
        }
    }
}

struct FloatingUnreadRenderRequestToken: Equatable, Sendable {
    fileprivate let descriptor: FloatingUnreadFrameCacheDescriptor
    fileprivate let generation: UInt64
}

@MainActor
final class FloatingUnreadRenderRequestCoordinator {
    private var generation: UInt64 = 0
    private var descriptor: FloatingUnreadFrameCacheDescriptor?

    func begin(descriptor: FloatingUnreadFrameCacheDescriptor) -> FloatingUnreadRenderRequestToken? {
        guard descriptor != self.descriptor else { return nil }
        generation &+= 1
        self.descriptor = descriptor
        return FloatingUnreadRenderRequestToken(descriptor: descriptor, generation: generation)
    }

    func accepts(_ token: FloatingUnreadRenderRequestToken) -> Bool {
        descriptor == token.descriptor && generation == token.generation
    }

    func invalidate() {
        generation &+= 1
        descriptor = nil
    }
}

final class FloatingUnreadFrameCacheStorage: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable ([CGImage]) -> Void

    private let cache: NSCache<FloatingUnreadFrameCacheKey, FloatingUnreadFrameSequence>
    private let lock = NSLock()
    private let renderExecutor: any FloatingUnreadFrameRenderExecuting
    private let completionDispatcher: any FloatingUnreadFrameCompletionDispatching
    private var inFlight: [FloatingUnreadFrameCacheDescriptor: [Completion]] = [:]

    init(
        renderExecutor: any FloatingUnreadFrameRenderExecuting = FloatingUnreadSerialRenderExecutor(),
        completionDispatcher: any FloatingUnreadFrameCompletionDispatching = FloatingUnreadMainCompletionDispatcher()
    ) {
        let cache = NSCache<FloatingUnreadFrameCacheKey, FloatingUnreadFrameSequence>()
        cache.totalCostLimit = FloatingUnreadFrameBudget.frameCacheLimitBytes
        cache.countLimit = 6
        self.cache = cache
        self.renderExecutor = renderExecutor
        self.completionDispatcher = completionDispatcher
    }

    func requestFrames(
        descriptor: FloatingUnreadFrameCacheDescriptor,
        render: @escaping @Sendable () -> [CGImage],
        completion: @escaping Completion
    ) -> [CGImage]? {
        let key = FloatingUnreadFrameCacheKey(descriptor)
        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached.frames
        }
        if inFlight[descriptor] != nil {
            inFlight[descriptor, default: []].append(completion)
            lock.unlock()
            return nil
        }
        inFlight[descriptor] = [completion]
        lock.unlock()

        renderExecutor.execute { [weak self] in
            self?.finish(descriptor: descriptor, frames: render())
        }
        return nil
    }

    private func finish(descriptor: FloatingUnreadFrameCacheDescriptor, frames: [CGImage]) {
        let key = FloatingUnreadFrameCacheKey(descriptor)
        lock.lock()
        if !frames.isEmpty {
            let byteCost = FloatingUnreadFrameBudget.estimatedBytes(
                pixelWidth: descriptor.pixelWidth,
                pixelHeight: descriptor.pixelHeight,
                frameCount: frames.count
            )
            cache.setObject(
                FloatingUnreadFrameSequence(frames: frames, byteCost: byteCost),
                forKey: key,
                cost: byteCost
            )
        }
        let completions = inFlight.removeValue(forKey: descriptor) ?? []
        lock.unlock()

        guard !completions.isEmpty else { return }
        completionDispatcher.dispatch {
            completions.forEach { $0(frames) }
        }
    }
}

enum FloatingUnreadFrameCache {
    private static let storage = FloatingUnreadFrameCacheStorage()

    static func requestFrames(
        descriptor: FloatingUnreadFrameCacheDescriptor,
        render: @escaping @Sendable () -> [CGImage],
        completion: @escaping FloatingUnreadFrameCacheStorage.Completion
    ) -> [CGImage]? {
        storage.requestFrames(
            descriptor: descriptor,
            render: render,
            completion: completion
        )
    }
}

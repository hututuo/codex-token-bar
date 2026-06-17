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

struct FloatingUnreadFrameCacheDescriptor: Hashable {
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
        color: NSColor,
        cornerRadius: CGFloat,
        scale: CGFloat,
        cycleDuration: CFTimeInterval,
        activeFraction: Double,
        framesPerSecond: Int
    ) {
        let color = FloatingPanelColorTools.deviceRGB(color)
        self.effect = effect
        self.pixelWidth = max(1, Int((size.width * backingScale).rounded(.up)))
        self.pixelHeight = max(1, Int((size.height * backingScale).rounded(.up)))
        self.red = Self.quantizeColor(color.redComponent)
        self.green = Self.quantizeColor(color.greenComponent)
        self.blue = Self.quantizeColor(color.blueComponent)
        self.alpha = Self.quantizeColor(color.alphaComponent)
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

private final class FloatingUnreadFrameCacheStorage: @unchecked Sendable {
    private let cache: NSCache<FloatingUnreadFrameCacheKey, FloatingUnreadFrameSequence>
    private let lock = NSLock()

    init() {
        let cache = NSCache<FloatingUnreadFrameCacheKey, FloatingUnreadFrameSequence>()
        cache.totalCostLimit = FloatingUnreadFrameBudget.frameCacheLimitBytes
        cache.countLimit = 6
        self.cache = cache
    }

    func frames(
        descriptor: FloatingUnreadFrameCacheDescriptor,
        render: () -> [CGImage]
    ) -> [CGImage] {
        let key = FloatingUnreadFrameCacheKey(descriptor)
        lock.lock()
        if let cached = cache.object(forKey: key) {
            lock.unlock()
            return cached.frames
        }
        lock.unlock()

        let frames = render()
        guard !frames.isEmpty else { return frames }
        let byteCost = FloatingUnreadFrameBudget.estimatedBytes(
            pixelWidth: descriptor.pixelWidth,
            pixelHeight: descriptor.pixelHeight,
            frameCount: frames.count
        )
        lock.lock()
        cache.setObject(
            FloatingUnreadFrameSequence(frames: frames, byteCost: byteCost),
            forKey: key,
            cost: byteCost
        )
        lock.unlock()
        return frames
    }
}

enum FloatingUnreadFrameCache {
    private static let storage = FloatingUnreadFrameCacheStorage()

    static func frames(
        descriptor: FloatingUnreadFrameCacheDescriptor,
        render: () -> [CGImage]
    ) -> [CGImage] {
        storage.frames(descriptor: descriptor, render: render)
    }
}

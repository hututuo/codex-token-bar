import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ReportAvatarImage: Equatable, Sendable {
    public let png: Data
    public var sha256: String { ReportHash.sha256Hex(png) }
    public enum Failure: Error { case invalid, tooLarge }
    public static let maxInputBytes = 10 * 1024 * 1024
    public static let maxPNGBytes = 512 * 1024

    public static func prepare(file: URL) throws -> ReportAvatarImage {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        guard let stat = FileStat.fstat(handle.fileDescriptor), stat.isRegularFile,
              stat.size <= maxInputBytes else { throw Failure.tooLarge }
        let data = try handle.read(upToCount: maxInputBytes + 1) ?? Data()
        guard data.count <= maxInputBytes else { throw Failure.tooLarge }
        return try prepare(data: data)
    }

    public static func prepare(data: Data) throws -> ReportAvatarImage {
        guard !data.isEmpty, data.count <= maxInputBytes else { throw Failure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_000_000 else { throw Failure.invalid }
        let thumbnailSize = Int(ceil(Double(max(width, height)) * min(1, 256 / Double(min(width, height)))))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(256, thumbnailSize), kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.invalid }
        let side = min(image.width, image.height)
        guard let cropped = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2,
                                                      width: side, height: side)) else { throw Failure.invalid }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        guard let rendered = context.makeImage() else { throw Failure.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure.invalid }
        CGImageDestinationAddImage(destination, rendered, [:] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= maxPNGBytes else { throw Failure.tooLarge }
        guard let cleaned = metadataFreePNG(output as Data) else { throw Failure.invalid }
        return ReportAvatarImage(png: cleaned)
    }

    private static func metadataFreePNG(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= 8, Array(bytes.prefix(8)) == signature else { return nil }
        var result = Data(signature), offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length <= bytes.count - offset - 12 else { return nil }
            let end = offset + length + 12
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"].contains(type) { result.append(contentsOf: bytes[offset..<end]) }
            offset = end
            if type == "IEND" { return offset == bytes.count ? result : nil }
        }
        return nil
    }

    public static func validatedDownload(_ data: Data, sha256: String?) -> ReportAvatarImage? {
        guard data.count <= maxPNGBytes, sha256.map({ ReportHash.sha256Hex(data) == $0 }) ?? true,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              info[kCGImagePropertyPixelWidth] as? Int == 256, info[kCGImagePropertyPixelHeight] as? Int == 256 else { return nil }
        return ReportAvatarImage(png: data)
    }
}

import CryptoKit
import Darwin
import Foundation

/// Immutable, file-backed lookup. The kernel can discard its clean pages;
/// loading it never reconstructs the vocabulary as malloc-owned collections.
final class MappedTokenizerVocabulary: @unchecked Sendable {
    // Filled from the cloud compiler's independently verified artifact.
    static let expectedSHA256 = "5d1ea2f0112ff673be603e44c513d55a57a47a0b25f0811f07d1027c335f776e"
    private static let headerBytes = 64
    private static let slots = 1 << 19
    private let address: UnsafeRawPointer
    let byteCount: Int
    private let payloadOffset: Int

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= Self.headerBytes, status.st_size <= 8 * 1_048_576 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = Int(status.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor, 0),
              mapped != MAP_FAILED else { throw CocoaError(.fileReadUnknown) }
        var accepted = false
        defer { if !accepted { munmap(mapped, size) } }
        // This view does not own or copy the mapping. Verify the entire artifact
        // before trusting offsets, lengths or ranks read from it.
        let view = Data(bytesNoCopy: mapped, count: size, deallocator: .none)
        guard SHA256.hash(data: view).map({ String(format: "%02x", $0) }).joined() == Self.expectedSHA256,
              view.prefix(8) == Data("CTBO2K01".utf8),
              mapped.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian == UInt32(Self.slots),
              mapped.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian == 199_998,
              mapped.loadUnaligned(fromByteOffset: 16, as: UInt64.self).littleEndian
                == UInt64(Self.headerBytes + Self.slots * 4) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        address = UnsafeRawPointer(mapped)
        byteCount = size
        payloadOffset = Self.headerBytes + Self.slots * 4
        accepted = true
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: address), byteCount) }

    func rank(_ piece: [UInt8], _ start: Int, _ end: Int) -> UInt32? {
        var hash: UInt32 = 2_166_136_261
        for index in start..<end { hash = (hash ^ UInt32(piece[index])) &* 16_777_619 }
        var slot = Int(hash) & (Self.slots - 1)
        while true {
            let offset = Int(address.loadUnaligned(
                fromByteOffset: Self.headerBytes + slot * 4, as: UInt32.self).littleEndian)
            if offset == 0 { return nil }
            let record = payloadOffset + offset - 1
            let length = Int(address.loadUnaligned(fromByteOffset: record + 4, as: UInt32.self).littleEndian)
            if length == end - start {
                var matches = true
                for index in 0..<length where address.load(fromByteOffset: record + 8 + index, as: UInt8.self) != piece[start + index] {
                    matches = false
                    break
                }
                if matches {
                    return address.loadUnaligned(fromByteOffset: record, as: UInt32.self).littleEndian
                }
            }
            slot = (slot + 1) & (Self.slots - 1)
        }
    }
}

import CoreFoundation
import CryptoKit
import CZstd
import Foundation

/// Chromium Simple Cache v5: reads only the official /usage response from disk.
/// No cookies, authentication, browser automation, localhost RPC, or HTTP client.
enum ClaudeDesktopHTTPCache {
    static let maximumEntryBytes = 2 * 1_024 * 1_024
    static let maximumBodyBytes = 65_536
    // Current Claude responses stream with a 2 MiB window even for a small JSON body.
    // Bound decoder memory separately from the 64 KiB output limit.
    static let maximumWindowLog: Int32 = 21
    static let maximumEntries = 20_000
    private static let entryMagic: UInt64 = 0xfcfb6d1ba7725c30
    private static let eofMagic: UInt64 = 0xf4fa6f45970d41d8

    static func read(directory: URL, now: Date) -> ClaudeLocalQuota? {
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return nil }
        var latest: ClaudeLocalQuota?
        var visited = 0
        for case let url as URL in entries {
            visited += 1
            // An incomplete inventory cannot establish which account was observed last.
            guard visited <= maximumEntries else { return nil }
            guard url.lastPathComponent.range(of: "^[0-9a-f]{16}_0$", options: .regularExpression) != nil,
                  let header = readHeader(url), usageKey(header) != nil,
                  let bytes = LocalQuotaCacheFile.read(url, limit: maximumEntryBytes),
                  let reading = decode(bytes, now: now) else { continue }
            if latest == nil || (reading.capturedAt ?? .distantPast) > (latest?.capturedAt ?? .distantPast) {
                latest = reading
            }
        }
        return latest
    }

    private static func readHeader(_ url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 2_048)
    }

    private static func integer(_ bytes: Data, _ offset: Int, _ count: Int) -> UInt64? {
        guard offset >= 0, offset <= bytes.count, count <= bytes.count - offset else { return nil }
        return (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }

    private static func usageKey(_ bytes: Data) -> Data? {
        guard integer(bytes, 0, 8) == entryMagic, integer(bytes, 8, 4) == 5,
              let length = integer(bytes, 12, 4), length > 0, length <= 1_024,
              24 + Int(length) <= bytes.count else { return nil }
        let key = bytes.subdata(in: 24..<24 + Int(length))
        guard let text = String(data: key, encoding: .utf8),
              text.range(of: "\\A(?:[0-9]+/){2}https://claude\\.ai/api/organizations/[0-9a-fA-F-]{36}/usage(?:\\?[^#\\x00-\\x20\\x7f]*)?\\z", options: .regularExpression) != nil else { return nil }
        return key
    }

    static func decode(_ bytes: Data, now: Date) -> ClaudeLocalQuota? {
        guard bytes.count <= maximumEntryBytes, let key = usageKey(bytes) else { return nil }
        let footer = bytes.count - 24
        guard integer(bytes, footer, 8) == eofMagic, let flags = integer(bytes, footer + 8, 4),
              flags == 3, let length = integer(bytes, footer + 16, 8), length <= 65_536 else { return nil }
        let metadataStart = footer - 32 - Int(length)
        let bodyStart = 24 + key.count, bodyEnd = metadataStart - 24
        guard bodyEnd >= bodyStart, metadataStart >= 0,
              bytes.subdata(in: footer - 32..<footer) == Data(SHA256.hash(data: key)),
              integer(bytes, bodyEnd, 8) == eofMagic, integer(bytes, bodyEnd + 8, 4) == 1,
              integer(bytes, bodyEnd + 16, 8) == 0 else { return nil }
        let metadata = bytes.subdata(in: metadataStart..<footer - 32)
        let body = bytes.subdata(in: bodyStart..<bodyEnd)
        guard integer(bytes, footer + 12, 4) == UInt64(LocalQuotaCacheFile.crc32(metadata)),
              integer(bytes, bodyEnd + 12, 4) == UInt64(LocalQuotaCacheFile.crc32(body)),
              let responseStart = metadata.range(of: Data("HTTP/1.1 200\0".utf8)),
              let responseEnd = metadata.range(of: Data([0, 0]), in: responseStart.lowerBound..<metadata.endIndex),
              let rawHeaders = String(data: metadata.subdata(in: responseStart.lowerBound..<responseEnd.upperBound), encoding: .utf8) else { return nil }
        var headers: [String: String] = [:]
        for line in rawHeaders.split(separator: "\0").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            guard ["date", "content-type", "content-encoding"].contains(name), headers[name] == nil else { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let captured = headers["date"].flatMap(date.date(from:)), captured <= now.addingTimeInterval(60) else { return nil }
        var result = ClaudeLocalQuota(state: "invalid", capturedAt: captured, fiveHour: nil, sevenDay: nil)
        result.source = "local-desktop-http-cache"
        let decoded: Data?
        switch headers["content-encoding"]?.lowercased() ?? "identity" {
        case "identity": decoded = body.count <= maximumBodyBytes ? body : nil
        case "zstd": decoded = decompress(body)
        default: decoded = nil // Do not guess a different encoding or fetch an uncached copy.
        }
        guard let decoded, let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return result }
        func window(_ key: String) -> ClaudeLocalQuota.Window? {
            guard let row = root[key] as? [String: Any], let value = row["utilization"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  (0...100).contains(value.doubleValue), let rawReset = row["resets_at"] as? String,
                  let reset = LocalQuotaCacheFile.isoDate(rawReset) else { return nil }
            return .init(usedPercent: value.doubleValue, resetsAt: reset)
        }
        let five = window("five_hour"), seven = window("seven_day")
        // These are sampled values, not a live balance. A passed reset is shown
        // as awaiting an update, never used to erase or infer a new percentage.
        result = ClaudeLocalQuota(state: five == nil && seven == nil ? "missing" : "available", capturedAt: captured,
            fiveHour: five, sevenDay: seven)
        result.source = "local-desktop-http-cache"
        return result
    }

    private static func decompress(_ bytes: Data) -> Data? {
        guard let stream = ZSTD_createDStream() else { return nil }
        defer { ZSTD_freeDStream(stream) }
        guard ZSTD_isError(ZSTD_initDStream(stream)) == 0,
              ZSTD_isError(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, maximumWindowLog)) == 0 else { return nil }
        return bytes.withUnsafeBytes { input in
            var source = ZSTD_inBuffer(src: input.baseAddress, size: input.count, pos: 0)
            var output = [UInt8](repeating: 0, count: maximumBodyBytes + 1)
            var count = 0
            let remaining = output.withUnsafeMutableBytes { buffer in
                var target = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                let remaining = ZSTD_decompressStream(stream, &target, &source)
                count = target.pos
                return remaining
            }
            guard remaining == 0, source.pos == source.size, count <= maximumBodyBytes else { return nil }
            return Data(output.prefix(count))
        }
    }
}

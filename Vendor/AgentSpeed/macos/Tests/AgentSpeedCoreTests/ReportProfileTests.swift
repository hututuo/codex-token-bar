import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentSpeedCore

@Suite("Profile API")
struct ReportProfileTests {
    static let device = "22222222-2222-4222-8222-222222222222"
    static let profile = Data(#"{"sharedUserId":null,"displayName":"Zoe","avatar":null,"devices":[{"deviceId":"22222222-2222-4222-8222-222222222222","platform":"macOS","isCurrent":true,"online":true}]}"#.utf8)

    @Test func rejectsMalformedProfilesAndPairingPaths() throws {
        #expect(ReportProfileSnapshot.parse(Self.profile)?.devices.count == 1)
        var root = try #require(try JSONSerialization.jsonObject(with: Self.profile) as? [String: Any])
        var missingAvatar = root
        missingAvatar.removeValue(forKey: "avatar")
        #expect(ReportProfileSnapshot.parse(try JSONSerialization.data(withJSONObject: missingAvatar)) == nil)
        root["displayName"] = "Zoe\u{202E}"
        #expect(ReportProfileSnapshot.parse(try JSONSerialization.data(withJSONObject: root)) == nil)
        root["displayName"] = "Zoe"; root["sharedUserId"] = "../secret"
        #expect(ReportProfileSnapshot.parse(try JSONSerialization.data(withJSONObject: root)) == nil)
        #expect(ReportProfileOperation.pairing("../../devices").request == nil)
        #expect(ReportProfileOperation.claimPairing("INVALID").request == nil)
        #expect(ReportPairingSnapshot.normalizedCode("abcd-efgh-jklm") == "ABCDEFGHJKLM")
        #expect(ReportPairingSnapshot.normalizedCode("ABCD-EFGH-IOLM") == nil)
    }

    @Test func pairingExpirationIsStrictUTCMilliseconds() throws {
        let now = Date(timeIntervalSince1970: 1_792_815_000)
        let valid = ReportInstant.format(unixMs: Int64(now.addingTimeInterval(300).timeIntervalSince1970 * 1000))
        func pairing(_ stamp: String) -> Data {
            Data(#"{"id":"33333333-3333-4333-8333-333333333333","state":"waiting","expiresAt":"\#(stamp)"}"#.utf8)
        }
        #expect(ReportPairingSnapshot.parse(pairing(valid), now: now) != nil)
        for stamp in [valid.replacingOccurrences(of: "Z", with: "+00:00"), valid.replacingOccurrences(of: ".000Z", with: "Z"),
                      valid.replacingOccurrences(of: ".000Z", with: ".00Z"), valid.replacingOccurrences(of: ".000Z", with: ".0000Z"),
                      "2026-02-30T00:00:00.000Z", valid.replacingOccurrences(of: "T", with: "t")] {
            #expect(ReportPairingSnapshot.parse(pairing(stamp), now: now) == nil)
        }
    }

    @Test func pairingUsesTheCorrectedSignatureClockAndKeepsFutureBound() async throws {
        let localSeconds = Int64(Date().timeIntervalSince1970)
        let service = try ReportServiceURL.parse("http://127.0.0.1:8765").get()
        var document = try #require(ReportDiscovery.assumed(for: service, name: "Test"))
        document.extensions = .init(sharedIdentity: true)
        let signer = SoftwareReportSigner()
        let builder = ReportRequestBuilder(userAgent: "AgentSpeed/1.0.0 (macOS)", deviceId: Self.device, apiKey: nil)
        let id = "33333333-3333-4333-8333-333333333333"
        let fixtures: [(correction: Int64, ttl: Int64, accepted: Bool)] = [(120, 600, true), (-120, 600, true), (120, 661, false)]
        for fixture in fixtures {
            let correctedSeconds = localSeconds + fixture.correction
            let stamp = ReportInstant.format(unixMs: (correctedSeconds + fixture.ttl) * 1000)
            let body = Data(#"{"id":"\#(id)","state":"waiting","expiresAt":"\#(stamp)"}"#.utf8)
            let transport = CaptureTransport(response: ReportHTTPResponse(status: 200, body: body))
            let api = ReportAPI(transport: transport, userAgent: "AgentSpeed/1.0.0 (macOS)")
            let result = await api.profile(.pairing(id), document: document, builder: builder, signer: signer, timestamp: correctedSeconds)
            if fixture.accepted {
                guard case .success(.pairing(let pairing)) = result else { Issue.record("Corrected invitation was rejected"); continue }
                #expect(pairing.id == id && pairing.state == .waiting)
                #expect(Int64(pairing.expiresAt.timeIntervalSince1970) == correctedSeconds + fixture.ttl)
            } else { #expect(result == .failure(.invalid)) }
            let sent = try #require(await transport.requests.first)
            #expect(sent.header(ReportCanonical.timestampHeader) == String(correctedSeconds))
            if fixture.correction == 120 && fixture.ttl == 600 {
                #expect(ReportPairingSnapshot.parse(body, now: Date(timeIntervalSince1970: TimeInterval(localSeconds))) == nil)
            }
        }
    }

    @Test func imageIsCroppedOrientedAndReencodedWithoutSourceMetadata() throws {
        let image = try Self.sourceImage(width: 400, height: 200)
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6,
                                                       kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 34.5],
                                                       kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "private-camera"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let prepared = try ReportAvatarImage.prepare(data: output as Data)
        let source = try #require(CGImageSourceCreateWithData(prepared.png as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 256)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 256)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifLensModel] == nil)
        #expect(exif?.keys.allSatisfy { [kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension].contains($0) } ?? true)
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(ReportAvatarImage.validatedDownload(prepared.png, sha256: prepared.sha256) == prepared)
        #expect(ReportAvatarImage.validatedDownload(prepared.png, sha256: String(repeating: "0", count: 64)) == nil)
        #expect(throws: (any Error).self) { try ReportAvatarImage.prepare(data: Data("<svg/>".utf8)) }
        let animation = NSMutableData()
        let gif = try #require(CGImageDestinationCreateWithData(animation, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(gif, image, nil); CGImageDestinationAddImage(gif, image, nil)
        #expect(CGImageDestinationFinalize(gif))
        #expect(throws: (any Error).self) { try ReportAvatarImage.prepare(data: animation as Data) }
        #expect(throws: (any Error).self) { try ReportAvatarImage.prepare(data: Data(repeating: 0, count: ReportAvatarImage.maxInputBytes + 1)) }
    }

    @Test func capabilityPreventsRequestsAndUploadSignsExactPNG() async throws {
        let transport = CaptureTransport(response: ReportHTTPResponse(status: 200, body: Self.profile))
        let api = ReportAPI(transport: transport, userAgent: "AgentSpeed/1.0.0 (macOS)")
        let service = try ReportServiceURL.parse("http://127.0.0.1:8765").get()
        var document = try #require(ReportDiscovery.assumed(for: service, name: "Test"))
        let signer = SoftwareReportSigner()
        let builder = ReportRequestBuilder(userAgent: "AgentSpeed/1.0.0 (macOS)", deviceId: Self.device, apiKey: nil)
        let absent = await api.profile(.createIdentity, document: document, builder: builder, signer: signer, timestamp: 1_800_000_000)
        #expect(absent == .failure(.unsupported))
        let requests = await transport.requests
        #expect(requests.isEmpty)
        document.extensions = .init(profileAvatar: true, sharedIdentity: true)
        let raw = NSMutableData()
        let png = try #require(CGImageDestinationCreateWithData(raw, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, try Self.sourceImage(width: 300, height: 300), nil)
        #expect(CGImageDestinationFinalize(png))
        let avatar = try ReportAvatarImage.prepare(data: raw as Data)
        let result = await api.profile(.uploadAvatar(avatar), document: document, builder: builder, signer: signer, timestamp: 1_800_000_000)
        #expect(result == .success(.profile(try #require(ReportProfileSnapshot.parse(Self.profile)))))
        let sent = try #require(await transport.requests.first)
        #expect(sent.method == "PUT" && sent.url.path == "/v1/profile/avatar")
        #expect(sent.body == avatar.png && sent.header("Content-Type") == "image/png")
        let canonical = ReportCanonical.string(method: sent.method, authority: ReportURLs.authority(of: sent.url),
                                               path: sent.url.path, timestamp: sent.header(ReportCanonical.timestampHeader) ?? "",
                                               nonce: sent.header(ReportCanonical.nonceHeader) ?? "", deviceId: Self.device, body: avatar.png)
        #expect(signer.publicKey.isValidSignature(try #require(Base64URL.decode(sent.header(ReportCanonical.signatureHeader) ?? "")), for: Data(canonical.utf8)))
        #expect(sent.header(ReportCanonical.deviceHeader) == Self.device)
    }

    private static func sourceImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
}

private actor CaptureTransport: ReportTransport {
    var requests: [ReportRequest] = []
    let response: ReportHTTPResponse
    init(response: ReportHTTPResponse) { self.response = response }
    func get(_ url: URL, etag: String?, userAgent: String, maxBytes: Int, timeout: TimeInterval) async throws(ReportTransportError) -> ReportHTTPResponse { response }
    func send(_ request: ReportRequest, maxBytes: Int, timeout: TimeInterval) async throws(ReportTransportError) -> ReportHTTPResponse {
        requests.append(request); return response
    }
}

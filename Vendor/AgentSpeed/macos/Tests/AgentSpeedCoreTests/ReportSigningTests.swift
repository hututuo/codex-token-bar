import CryptoKit
import Foundation
import Testing
@testable import AgentSpeedCore

/// REPORTING 5 against spec/fixtures/report-vectors.json: keys, canonical strings, signatures and verification.
@Suite struct ReportSigningTests {
    static var vectors: [String: Any] { (try? Fixtures.json("report-vectors.json")) ?? [:] }

    static func key(_ name: String) throws -> (signer: SoftwareReportSigner, entry: [String: Any]) {
        let keys = try #require(vectors["keys"] as? [String: Any])
        let entry = try #require(keys[name] as? [String: Any])
        let hex = try #require(entry["d"] as? String)
        let d = try #require(Data(hex: hex))
        return (SoftwareReportSigner(key: try P256.Signing.PrivateKey(rawRepresentation: d)), entry)
    }

    static func request(_ name: String) throws -> [String: Any] {
        let requests = try #require(vectors["requests"] as? [String: Any])
        return try #require(requests[name] as? [String: Any])
    }

    @Test func keysEncodeAsJWKAndThumbprint() throws {
        for name in ["device", "other", "rotated"] {
            let (signer, entry) = try Self.key(name)
            let jwk = try #require(entry["jwk"] as? [String: String])
            #expect(signer.publicKey.jwk == .object(["kty": .string("EC"), "crv": .string("P-256"),
                                                    "x": .string(jwk["x"]!), "y": .string(jwk["y"]!)]), "\(name)")
            #expect(signer.publicKey.thumbprint == entry["thumbprint"] as? String, "\(name)")
            let spkiText = try #require(entry["spki"] as? String)
            let spki = try #require(Base64URL.decode(spkiText))
            #expect(spki == signer.key.publicKey.derRepresentation, "\(name) SPKI")
        }
    }

    @Test func canonicalStringsAndBodyHashes() throws {
        let requests = try #require(Self.vectors["requests"] as? [String: [String: Any]])
        #expect(requests.count == 6)
        for (name, request) in requests {
            let headers = try #require(request["headers"] as? [String: String])
            let body = Data((request["body"] as? String ?? "").utf8)
            let canonical = ReportCanonical.string(
                method: request["method"] as? String ?? "", authority: request["authority"] as? String ?? "",
                path: request["path"] as? String ?? "", timestamp: headers["X-AgentSpeed-Timestamp"]!,
                nonce: headers["X-AgentSpeed-Nonce"]!, deviceId: headers["X-AgentSpeed-Device"]!, body: body)
            #expect(canonical == request["canonical"] as? String, "\(name)")
            #expect(ReportHash.sha256Hex(body) == request["bodySha256"] as? String, "\(name)")
            let url = try #require(URL(string: request["url"] as? String ?? ""))
            #expect(ReportURLs.authority(of: url) == request["authority"] as? String, "\(name) authority")
            #expect(ReportURLs.requestPath(of: url) == request["path"] as? String, "\(name) path")
        }
        #expect(ReportHash.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// Every case of `verify`: valid, invalid (including `n − s`, `r = 0`, `s = n`, double hashing) and malformed.
    @Test func verificationCases() throws {
        let cases = try #require(Self.vectors["verify"] as? [[String: Any]])
        #expect(cases.count == 24)
        var highS = 0
        for item in cases {
            let name = item["name"] as? String ?? "?"
            var request = try Self.request(item["request"] as? String ?? "")
            if request["highS"] as? Bool == true { highS += 1 }
            let change = item["change"] as? [String: Any] ?? [:]
            var headers = try #require(request["headers"] as? [String: String])
            for (key, value) in change {
                if key == "headers", let changed = value as? [String: String] {
                    headers.merge(changed) { $1 }
                } else {
                    request[key] = value
                }
            }
            let header = item["header"] as? String ?? ReportCanonical.signatureHeader
            let (signer, _) = try Self.key(item["key"] as? String ?? "")
            let result: String
            if ReportCanonical.malformedHeader(in: headers) != nil || !ReportCanonical.isSignature(headers[header] ?? "") {
                result = "malformed"
            } else {
                let canonical = ReportCanonical.string(
                    method: request["method"] as! String, authority: request["authority"] as! String,
                    path: request["path"] as! String, timestamp: headers["X-AgentSpeed-Timestamp"]!,
                    nonce: headers["X-AgentSpeed-Nonce"]!, deviceId: headers["X-AgentSpeed-Device"]!,
                    body: Data((request["body"] as! String).utf8))
                let signature = try #require(Base64URL.decode(headers[header]!))
                result = signer.publicKey.isValidSignature(signature, for: Data(canonical.utf8)) ? "valid" : "invalid"
            }
            #expect(result == item["expect"] as? String, "\(name)")
        }
        #expect(highS > 0, "the vectors include a high-S signature")
    }

    @Test func publicKeyValidation() throws {
        let cases = try #require(Self.vectors["publicKeys"] as? [[String: Any]])
        for item in cases {
            let data = try JSONSerialization.data(withJSONObject: item["jwk"] ?? [:])
            let parsed = ReportPublicKey.parse(jwk: try JSONParser.parse(data))
            #expect((parsed == nil ? "invalid" : "valid") == item["expect"] as? String, "\(item["name"] ?? "")")
        }
    }

    @Test func rfc6979KnownAnswersVerify() throws {
        let rfc = try #require(Self.vectors["rfc6979"] as? [String: Any])
        let raw = try #require(Data(hex: (rfc["x"] as! String) + (rfc["y"] as! String)))
        let key = try #require(ReportPublicKey(raw: raw))
        for message in try #require(rfc["messages"] as? [[String: String]]) {
            let signature = try #require(Data(hex: message["r"]! + message["s"]!))
            #expect(key.isValidSignature(signature, for: Data(message["message"]!.utf8)))
            #expect(!key.isValidSignature(signature, for: Data((message["message"]! + "!").utf8)))
        }
    }

    /// Our builder signs what a verifier rebuilds; CryptoKit signs the message, not a digest, so both `s` forms of its
    /// own signatures verify and a double-hashed signature does not.
    @Test func builderSignsTheCanonicalString() throws {
        let (signer, _) = try Self.key("device")
        let (rotated, _) = try Self.key("rotated")
        let vector = try Self.request("rotate")
        let builder = ReportRequestBuilder(userAgent: "AgentSpeed/1.3.0 (macOS)",
                                           deviceId: "6f1c2a9e-3b4d-4e5f-8a7b-9c0d1e2f3a4b", apiKey: nil)
        let url = try #require(URL(string: vector["url"] as! String))
        let headers = vector["headers"] as! [String: String]
        let body = Data((vector["body"] as! String).utf8)
        let request = try builder.make(method: "PUT", url: url, body: body, signer: signer, timestamp: 1_792_656_931,
                                       nonce: headers["X-AgentSpeed-Nonce"]!, newKey: rotated)
        let canonical = Data((vector["canonical"] as! String).utf8)
        let signature = try #require(Base64URL.decode(request.header(ReportCanonical.signatureHeader) ?? ""))
        let newSignature = try #require(Base64URL.decode(request.header(ReportCanonical.newKeySignatureHeader) ?? ""))
        #expect(signer.publicKey.isValidSignature(signature, for: canonical))
        #expect(rotated.publicKey.isValidSignature(newSignature, for: canonical))
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.header("Authorization") == nil)
        #expect(ReportCanonical.malformedHeader(in: Dictionary(uniqueKeysWithValues: request.headers.map { ($0.name, $0.value) })) == nil)
        let digest = Data(SHA256.hash(data: canonical))
        let doubled = try signer.signature(for: digest)
        #expect(!signer.publicKey.isValidSignature(doubled, for: canonical))

        let keyed = ReportRequestBuilder(userAgent: "AgentSpeed/1.3.0 (macOS)", deviceId: builder.deviceId, apiKey: "secret-12345")
        let delete = try keyed.make(method: "DELETE", url: url, body: Data(), signer: signer, timestamp: 1_792_656_931)
        #expect(delete.header("Content-Type") == nil)
        #expect(delete.header("Authorization") == "Bearer secret-12345")
        #expect(delete.header(ReportCanonical.nonceHeader)?.utf8.count == 22)
    }

    /// Every request of the `server` sequences is well-formed and signed by one of the test keys, and every expected
    /// answer maps to the client reaction of REPORTING 8.3.
    @Test func serverSequences() throws {
        let cases = try #require(Self.vectors["server"] as? [[String: Any]])
        #expect(cases.count == 4)
        let keys = try ["device", "other", "rotated"].map { try Self.key($0).signer.publicKey }
        var steps = 0
        for item in cases {
            let config = try #require(item["config"] as? [String: Any])
            let authority = try #require(config["authority"] as? String)
            for step in try #require(item["steps"] as? [[String: Any]]) {
                steps += 1
                let request = try #require(step["request"] as? [String: Any])
                let headers = try #require(request["headers"] as? [String: String])
                let body = Data((request["body"] as? String ?? "").utf8)
                #expect(ReportCanonical.malformedHeader(in: headers) == nil)
                let canonical = Data(ReportCanonical.string(
                    method: request["method"] as? String ?? "", authority: authority, path: request["path"] as? String ?? "",
                    timestamp: headers["X-AgentSpeed-Timestamp"]!, nonce: headers["X-AgentSpeed-Nonce"]!,
                    deviceId: headers["X-AgentSpeed-Device"]!, body: body).utf8)
                let signature = try #require(Base64URL.decode(headers["X-AgentSpeed-Signature"] ?? ""))
                #expect(keys.contains { $0.isValidSignature(signature, for: canonical) }, "\(request["path"] ?? "")")

                let expect = try #require(step["expect"] as? [String: Any])
                let status = try #require(expect["status"] as? Int)
                var reply = ReportReply(status: status, result: expect["result"] as? String, code: expect["code"] as? String)
                reply.errorUsername = expect["username"] as? String
                reply.reason = expect["reason"] as? String
                let (outcome, reaction) = ReportOutcome.classify(.success(reply), hasPendingKey: false)
                switch reply.code {
                case nil: #expect(outcome == .delivered(intervalSeconds: nil))
                case "rate_limited": #expect(outcome == .rateLimited(seconds: 60))
                case "nonce_replayed": #expect(outcome == .again)
                case "username_mismatch": #expect(reaction == .rename(registered: "zoe-mbp"))
                case "unknown_device": #expect(reaction == .reRegister)
                case "signature_invalid": #expect(reaction == .recheckRegistration)
                case "timestamp_out_of_window": #expect(reaction == .correctClock(serverTime: nil))
                case "seq_conflict": #expect(reaction == .newRun)
                case "version_unsupported": #expect(reaction == .refreshDiscovery(upgrade: true))
                case "payload_too_large": #expect(reaction == .refreshDiscovery(upgrade: false))
                case "api_key_required", "api_key_invalid": #expect(reaction == .needsUser(.apiKey))
                case "device_conflict": #expect(reaction == .needsUser(.keyMismatch))
                case "username_taken": #expect(reaction == .needsUser(.usernameTaken))
                case "report_stale": #expect(reaction == ReportReaction.none && outcome == .rejected)
                default: #expect(outcome == .rejected, "\(reply.code ?? "")")
                }
            }
        }
        #expect(steps > 40)
    }

    @Test func base64URLIsStrict() {
        #expect(Base64URL.encode(Data([0xFB, 0xFF])) == "-_8")
        #expect(Base64URL.decode("-_8") == Data([0xFB, 0xFF]))
        #expect(Base64URL.decode("-_8=") == nil)
        #expect(Base64URL.decode("-_9") == nil)
        #expect(Base64URL.decode("+/8") == nil)
        #expect(Base64URL.decode("A") == nil)
        #expect(Base64URL.decode("") == Data())
    }

    @Test func instantsHaveThreeFractionDigits() {
        #expect(ReportInstant.format(unixMs: 1_792_656_930_500) == "2026-10-22T08:15:30.500Z")
        #expect(ReportInstant.format(unixMs: 1_792_656_931_000) == "2026-10-22T08:15:31.000Z")
        #expect(ReportInstant.format(unixMs: 0) == "1970-01-01T00:00:00.000Z")
    }
}

extension Data {
    init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var out = Data(capacity: bytes.count / 2)
        var index = 0
        while index < bytes.count {
            guard let high = Self.nibble(bytes[index]), let low = Self.nibble(bytes[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        self = out
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

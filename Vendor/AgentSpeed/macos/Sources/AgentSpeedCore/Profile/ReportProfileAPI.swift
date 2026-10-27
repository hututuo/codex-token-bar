import Foundation

public enum ReportProfileOperation: Sendable {
    case profile, avatar, uploadAvatar(ReportAvatarImage), removeAvatar
    case createIdentity, rename(String), unlinkIdentity
    case createPairing, claimPairing(String), pairing(String), approvePairing(String), cancelPairing(String)

    var capability: Capability {
        switch self {
        case .profile: .either
        case .avatar, .uploadAvatar, .removeAvatar: .avatar
        default: .identity
        }
    }
    enum Capability { case either, avatar, identity }
    var request: (method: String, path: String, body: Data)? {
        let empty = Data(), object = Data("{}".utf8)
        switch self {
        case .profile: return ("GET", "/v1/profile", empty)
        case .avatar: return ("GET", "/v1/profile/avatar", empty)
        case .uploadAvatar(let image): return ("PUT", "/v1/profile/avatar", image.png)
        case .removeAvatar: return ("DELETE", "/v1/profile/avatar", empty)
        case .createIdentity: return ("POST", "/v1/profile/identity", object)
        case .rename(let raw):
            let name = ReportUsername.normalized(raw)
            guard ReportUsername.validate(name, rules: .init(minLength: 1)) == nil else { return nil }
            return ("PATCH", "/v1/profile", ReportJSON.object(["displayName": .string(name)]).compactData)
        case .unlinkIdentity: return ("DELETE", "/v1/profile/identity", empty)
        case .createPairing: return ("POST", "/v1/profile/pairings", object)
        case .claimPairing(let raw):
            guard let code = ReportPairingSnapshot.normalizedCode(raw) else { return nil }
            return ("POST", "/v1/profile/pairings/claim", ReportJSON.object(["code": .string(code)]).compactData)
        case .pairing(let id), .approvePairing(let id), .cancelPairing(let id):
            guard ReportCanonical.isDeviceId(id) else { return nil }
            switch self {
            case .pairing: return ("GET", "/v1/profile/pairings/" + id, empty)
            case .approvePairing: return ("POST", "/v1/profile/pairings/" + id + "/approve", object)
            default: return ("DELETE", "/v1/profile/pairings/" + id, empty)
            }
        }
    }
}

public enum ReportProfileResult: Equatable, Sendable {
    case profile(ReportProfileSnapshot), pairing(ReportPairingSnapshot), avatar(ReportAvatarImage), cancelled, avatarMissing
}
public enum ReportProfileError: Error, Equatable, Sendable {
    case unsupported, invalid, signing, transport(ReportTransportError), rejected(Int, code: String?, retryAfter: Int?)
}

extension ReportAPI {
    public func profile(_ operation: ReportProfileOperation, document: ReportDiscovery, builder: ReportRequestBuilder,
                        signer: any ReportSigner, timestamp: Int64, avatarHash: String? = nil) async
        -> Result<ReportProfileResult, ReportProfileError> {
        let caps = document.extensions ?? .none
        let supported = switch operation.capability {
        case .either: caps.profileAvatar || caps.sharedIdentity
        case .avatar: caps.profileAvatar
        case .identity: caps.sharedIdentity
        }
        guard supported else { return .failure(.unsupported) }
        guard let input = operation.request else { return .failure(.invalid) }
        var request: ReportRequest
        do {
            request = try builder.make(method: input.method, url: document.api.appending(endpoint: input.path), body: input.body,
                                       signer: signer, timestamp: timestamp)
        } catch { return .failure(.signing) }
        if case .uploadAvatar = operation {
            request.headers.removeAll { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }
            request.headers.append(.init(name: "Content-Type", value: "image/png"))
        }
        let download: Bool
        if case .avatar = operation { download = true } else { download = false }
        if download {
            request.headers.removeAll { $0.name.caseInsensitiveCompare("Accept") == .orderedSame }
            request.headers.append(.init(name: "Accept", value: "image/png"))
        }
        let response: ReportHTTPResponse
        do {
            response = try await transport.send(request, maxBytes: download ? ReportAvatarImage.maxPNGBytes : ReportProfileSnapshot.maxBytes,
                                                timeout: Self.apiTimeout)
        } catch { return .failure(.transport(error)) }
        if download, response.status == 404 { return .success(.avatarMissing) }
        guard (200..<300).contains(response.status) else {
            let reply = ReportReply.parse(status: response.status, headers: response.headers, body: response.body)
            return .failure(.rejected(response.status, code: reply.code, retryAfter: reply.retryAfterSeconds))
        }
        switch operation {
        case .cancelPairing:
            return response.status == 204 ? .success(.cancelled) : .failure(.invalid)
        case .avatar:
            let mime = response.headers.first { $0.key.caseInsensitiveCompare("content-type") == .orderedSame }?.value
            guard mime?.lowercased() == "image/png", let image = ReportAvatarImage.validatedDownload(response.body, sha256: avatarHash) else {
                return .failure(.invalid)
            }
            return .success(.avatar(image))
        case .createPairing, .claimPairing, .pairing, .approvePairing:
            let creates: Bool
            if case .createPairing = operation { creates = true } else { creates = false }
            let correctedNow = Date(timeIntervalSince1970: TimeInterval(timestamp))
            guard let pairing = ReportPairingSnapshot.parse(response.body, allowsCode: creates, now: correctedNow) else { return .failure(.invalid) }
            return .success(.pairing(pairing))
        default:
            guard let profile = ReportProfileSnapshot.parse(response.body, rules: document.usernameRules) else { return .failure(.invalid) }
            return .success(.profile(profile))
        }
    }
}

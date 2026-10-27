import Foundation

/// Which URLs update traffic may touch, including every redirect hop (UPDATES section 1).
public struct UpdateURLPolicy: Sendable, Equatable {
    public static let allowedHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// HTTPS on the GitHub hosts above only.
    public static let standard = UpdateURLPolicy(allowsAnyHost: false)
    /// Local testing with `AGENT_SPEED_UPDATE_FEED`: any HTTP(S) host, nothing else.
    public static let testing = UpdateURLPolicy(allowsAnyHost: true)

    public let allowsAnyHost: Bool

    public init(allowsAnyHost: Bool) {
        self.allowsAnyHost = allowsAnyHost
    }

    public func permits(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if allowsAnyHost { return scheme == "https" || scheme == "http" }
        guard scheme == "https", url.user(percentEncoded: false) == nil, url.password(percentEncoded: false) == nil else {
            return false
        }
        if let port = url.port, port != 443 { return false }
        return Self.allowedHosts.contains(host)
    }
}

import Foundation

/// The dashboard invitation (DESIGN 11, Dashboard invitation) and one-click consent (REPORTING 3.3): when the card is
/// shown, and whether a fetched document may be confirmed without the consent sheet.
public enum ReportInvite {
    /// The stored answer (`report.invite`); absent until the user answers.
    public enum Answer: String, Codable, Equatable, Sendable {
        case accepted
        case declined
    }

    /// What the visibility rule looks at.
    public struct Context: Equatable, Sendable {
        public var answer: Answer?
        public var reportingEnabled: Bool
        public var networkEnabled: Bool
        /// The selected service is the built-in preset (not a custom URL).
        public var presetSelected: Bool
        /// An identity is registered for any service.
        public var hasRegisteredIdentity: Bool

        public init(answer: Answer?, reportingEnabled: Bool, networkEnabled: Bool, presetSelected: Bool,
                    hasRegisteredIdentity: Bool) {
            self.answer = answer
            self.reportingEnabled = reportingEnabled
            self.networkEnabled = networkEnabled
            self.presetSelected = presetSelected
            self.hasRegisteredIdentity = hasRegisteredIdentity
        }
    }

    /// The card is offered while unanswered, off, online, on the preset and with nothing registered anywhere.
    public static func isOffered(_ context: Context) -> Bool {
        context.answer == nil && !context.reportingEnabled && context.networkEnabled && context.presetSelected
            && !context.hasRegisteredIdentity
    }

    /// Why a document cannot be confirmed by the invitation alone (REPORTING 3.3).
    public enum Gap: Equatable, Sendable {
        /// The API lives on a host the invitation did not name.
        case apiHost
        /// The service requires an API key.
        case apiKey
        /// The username breaks the service's rules.
        case username(ReportUsernameProblem)
    }

    /// Nil when the invitation covered `document`: its API is on the service URL's host or a subdomain of it (or
    /// under the domain the built-in preset covers), it needs no API key and `username` fits its rules.
    public static func gap(_ document: ReportDiscovery, service: ReportServiceURL, username: String,
                           presetDomain: String? = nil) -> Gap? {
        let host = document.api.host
        let covered = covers(apiHost: host, serviceHost: service.host)
            || presetDomain.map { covers(apiHost: host, serviceHost: $0) && covers(apiHost: service.host, serviceHost: $0) } ?? false
        if !covered { return .apiHost }
        if document.apiKeyMode == .required { return .apiKey }
        if let problem = ReportUsername.validate(username, rules: document.usernameRules) { return .username(problem) }
        return nil
    }

    /// The same host, or a subdomain of it (`api.example.com` under `example.com`); hosts are lower-case ASCII.
    public static func covers(apiHost: String, serviceHost: String) -> Bool {
        let api = apiHost.lowercased()
        let service = serviceHost.lowercased()
        return api == service || (!service.isEmpty && api.hasSuffix("." + service) && !isIPLiteral(service))
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        host.hasPrefix("[") || host.allSatisfy { $0.isNumber || $0 == "." }
    }
}

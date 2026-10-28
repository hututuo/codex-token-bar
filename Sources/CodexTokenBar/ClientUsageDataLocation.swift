import Foundation

enum ClientUsageDataLocation {
    static func databaseURL(applicationSupport: URL, bundleIdentifier: String?) -> URL {
        let base = applicationSupport.appendingPathComponent("CodexTokenBar", isDirectory: true)
        // A renamed preview app has its own defaults and must also have its own
        // usage/speed ledger. A simulated scan must never enter the user ledger.
        if let id = bundleIdentifier,
           id.hasPrefix("local.codex.token-bar."), id.contains("preview"),
           id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }) {
            return base.appendingPathComponent("Previews", isDirectory: true)
                .appendingPathComponent(id, isDirectory: true).appendingPathComponent("multi-client-usage.sqlite")
        }
        return base.appendingPathComponent("multi-client-usage.sqlite")
    }
}

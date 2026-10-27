import os

/// Pricing and day-binding events (METRICS 9.7); never personal data.
enum PricingLog {
    static let logger = Logger(subsystem: "io.github.zoefix.agentspeed", category: "pricing")
}

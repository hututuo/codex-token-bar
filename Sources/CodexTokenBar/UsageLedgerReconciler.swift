import Foundation

/// Pure, per-source reconciliation. It never deletes prior observations and
/// never treats a missing original location as a revocation of consumption.
enum UsageLedgerReconciler {
    struct Components: Hashable, Sendable {
        let input: Int64
        let cached: Int64
        let output: Int64
        let reasoning: Int64
        var valid: Bool {
            input >= 0 && output >= 0 && cached >= 0 && cached <= input
                && reasoning >= 0 && reasoning <= output
                && !input.addingReportingOverflow(output).overflow
        }
    }

    struct Observation: Equatable, Sendable {
        /// Ledger ID for history; staging-local ID for the new observation.
        let id: String
        let source: String
        let timestampMillis: Int64
        let components: Components
        /// Only a proven request identity or source/counter-epoch-scoped
        /// complete snapshot fingerprint belongs here. Offsets do not.
        let identity: String?
        let timestampTrusted: Bool
        /// Set only by an append proof or independently proved unseen usage.
        /// File rewrite/absence by itself cannot supply this proof.
        let confirmedNew: Bool
    }

    struct Match: Equatable, Sendable {
        let historicalID: String
        let observationID: String
    }

    struct Result: Equatable, Sendable {
        let retained: [Observation]
        let inserted: [Observation]
        let matches: [Match]
        let unresolved: [Observation]
    }

    enum Failure: Error { case mixedSources, invalidComponents, duplicateID, invalidIdentity, conflictingHistoricalIdentity }
    static func reconcile(history: [Observation], incoming: [Observation]) throws -> Result {
        guard Set((history + incoming).map(\.source)).count <= 1 else { throw Failure.mixedSources }
        guard (history + incoming).allSatisfy({ $0.components.valid }) else { throw Failure.invalidComponents }
        guard Set(history.map(\.id)).count == history.count,
              Set(incoming.map(\.id)).count == incoming.count else { throw Failure.duplicateID }
        guard (history + incoming).allSatisfy({ !$0.id.isEmpty && !$0.source.isEmpty && $0.identity != "" }) else {
            throw Failure.invalidIdentity
        }
        // Incoming IDs belong to a new observation namespace. A reused ledger
        // ID must not silently bind a different fact to an existing event.
        guard Set(history.map(\.id)).isDisjoint(with: Set(incoming.map(\.id))) else {
            throw Failure.duplicateID
        }
        var identities: [String: Observation] = [:]
        for record in history {
            if let identity = record.identity {
                if identities[identity] != nil { throw Failure.conflictingHistoricalIdentity }
                identities[identity] = record
            }
        }
        var inserted: [Observation] = []
        var matches: [Match] = []
        var unresolved: [Observation] = []
        for record in incoming {
            if let identity = record.identity, let old = identities[identity] {
                if old.components == record.components {
                    // Repeated observations of a proven identity are aliases,
                    // not extra requests. Keep the old timestamp and values.
                    matches.append(Match(historicalID: old.id, observationID: record.id))
                } else {
                    unresolved.append(record)
                }
                continue
            }
            // Equal components and timestamps are not request identity. Even
            // millisecond timestamps can contain multiple real calls. A caller
            // may supply an identity only after proving a one-to-one sequence
            // association or a request/counter-epoch identity.
            if record.confirmedNew {
                inserted.append(record)
                if let identity = record.identity { identities[identity] = record }
            } else {
                // Never infer a new billable event from a rewritten timestamp,
                // byte offset, ordinal, or the absence of a matching old row.
                unresolved.append(record)
            }
        }
        return Result(retained: history, inserted: inserted, matches: matches, unresolved: unresolved)
    }
}

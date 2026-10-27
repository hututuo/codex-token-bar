import Foundation

/// A set of sources, one bit per `SourceKind` at its position in `SourceKind.allCases` (which is append-only).
public struct SourceSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ kind: SourceKind) {
        self.init(rawValue: 1 << UInt32(kind.ordinal))
    }

    public init<S: Sequence>(_ kinds: S) where S.Element == SourceKind {
        self.init(rawValue: kinds.reduce(0) { $0 | SourceSet($1).rawValue })
    }

    /// Every known source.
    public static let everything = SourceSet(SourceKind.allCases)

    public func contains(_ kind: SourceKind) -> Bool {
        rawValue & SourceSet(kind).rawValue != 0
    }

    /// The members in `SourceKind.allCases` order.
    public var kinds: [SourceKind] {
        SourceKind.allCases.filter { contains($0) }
    }

    public var isEmpty: Bool { rawValue == 0 }
}

extension SourceKind {
    /// Position in `allCases`.
    var ordinal: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

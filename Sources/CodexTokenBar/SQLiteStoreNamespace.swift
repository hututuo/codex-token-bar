import Foundation

/// Identifier-aware adapter for one logical SQLite store inside the shared A
/// database. It deliberately does not rewrite values, comments, or bind slots.
struct SQLiteStoreNamespace: Equatable, Sendable {
    let prefix: String
    var objectNames: Set<String>
    var temporaryObjectNames: Set<String> = []

    struct Token: Equatable {
        enum Kind: Equatable { case identifier, string, trivia, punctuation }
        var kind: Kind
        var raw: String
        var value: String
    }

    enum BindingError: Error, Equatable {
        case malformedSQL
        case unsupportedSQL
        case crossDatabaseAccess
        case unknownReservedObject
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func physical(_ logical: String) -> String {
        if logical.lowercased().hasPrefix("sqlite_autoindex_") {
            let suffix = String(logical.dropFirst("sqlite_autoindex_".count))
            if let (table, ordinal) = Self.autoindexParts(suffix),
               objectNames.contains(table.lowercased()) {
                return "sqlite_autoindex_\(prefix)\(table)_\(ordinal)"
            }
        }
        return prefix + logical
    }

    /// Convert only known source objects. Arbitrary column names which happen
    /// to begin with this store's prefix are not logical table names.
    func logicalName(forPhysical physicalName: String) -> String? {
        if physicalName.lowercased().hasPrefix(prefix.lowercased()) {
            let suffix = String(physicalName.dropFirst(prefix.count))
            guard objectNames.contains(suffix.lowercased()) else { return nil }
            return suffix
        }
        let marker = "sqlite_autoindex_\(prefix)"
        guard physicalName.lowercased().hasPrefix(marker.lowercased()) else { return nil }
        let suffix = String(physicalName.dropFirst(marker.count))
        guard let (table, ordinal) = Self.autoindexParts(suffix),
              objectNames.contains(table.lowercased()) else { return nil }
        return "sqlite_autoindex_\(table)_\(ordinal)"
    }

    /// Bind logical object identifiers to this store's private physical names.
    /// All schema qualifiers and reserved objects are checked before rewriting.
    mutating func bind(_ sql: String) throws -> String {
        var tokens = try Self.tokens(sql)
        let significant = tokens.indices.filter { tokens[$0].kind != .trivia }
        guard significant.first != nil else { return sql }
        try Self.rejectForbiddenStatements(tokens, significant: significant)
        let cteNames = try Self.collectCTENames(tokens, significant: significant)
        guard cteNames.isDisjoint(with: objectNames) else { throw BindingError.unsupportedSQL }

        // Register DDL names before rewriting the same statement (including
        // indexes and triggers which reference their target table).
        for (position, index) in significant.enumerated() {
            guard Self.keyword(tokens[index], is: ["TABLE", "INDEX", "VIEW", "TRIGGER"]),
                  let createIndex = significant.firstIndex(where: { Self.keyword(tokens[$0], is: ["CREATE"]) }),
                  position > createIndex else { continue }
            var next = position + 1
            while next < significant.count,
                  Self.keyword(tokens[significant[next]], is: ["IF", "NOT", "EXISTS"]) { next += 1 }
            guard next < significant.count, tokens[significant[next]].kind == .identifier else { continue }
            let nameIndex = significant[next]
            guard !Self.isSchemaToken(tokens[nameIndex]) else { throw BindingError.crossDatabaseAccess }
            let lowerName = tokens[nameIndex].value.lowercased()
            let isTemporary = tokens[index].value.uppercased() == "TABLE"
                && significant[(createIndex + 1)..<position].contains(where: {
                    Self.keyword(tokens[$0], is: ["TEMP", "TEMPORARY"])
                })
            if isTemporary { temporaryObjectNames.insert(lowerName) }
            objectNames.insert(lowerName)
        }
        if let alterIndex = significant.firstIndex(where: { Self.keyword(tokens[$0], is: ["ALTER"]) }),
           let renameIndex = significant.firstIndex(where: { Self.keyword(tokens[$0], is: ["RENAME"]) }),
           renameIndex > alterIndex,
           renameIndex + 2 < significant.count,
           Self.keyword(tokens[significant[renameIndex + 1]], is: ["TO"]) {
            objectNames.insert(tokens[significant[renameIndex + 2]].value.lowercased())
        }
        // Old schema installers intentionally DROP IF EXISTS obsolete objects
        // before creating the current revision. An absent target still maps
        // exclusively into this namespace; it must never fall back to main.
        if let first = significant.first, Self.keyword(tokens[first], is: ["DROP"]),
           significant.contains(where: { Self.keyword(tokens[$0], is: ["IF"]) }),
           significant.contains(where: { Self.keyword(tokens[$0], is: ["EXISTS"]) }),
           let kind = significant.firstIndex(where: { Self.keyword(tokens[$0], is: ["TABLE", "INDEX", "VIEW", "TRIGGER"]) }) {
            var position = kind + 1
            while position < significant.count, Self.keyword(tokens[significant[position]], is: ["IF", "EXISTS"]) { position += 1 }
            var isTemporary = false
            if position + 2 < significant.count,
               ["main", "temp"].contains(tokens[significant[position]].value.lowercased()),
               tokens[significant[position + 1]].value == "." {
                isTemporary = tokens[significant[position]].value.lowercased() == "temp"
                position += 2
            }
            if position < significant.count, tokens[significant[position]].kind == .identifier {
                let name = tokens[significant[position]].value.lowercased()
                guard !name.hasPrefix("tb_"), !name.hasPrefix("sqlite_") else { throw BindingError.crossDatabaseAccess }
                objectNames.insert(name)
                if isTemporary { temporaryObjectNames.insert(name) }
            }
        }
        try Self.validateDDLTarget(tokens, significant: significant, objectNames: objectNames, temporaryObjectNames: temporaryObjectNames)
        try Self.validateObjectReferences(tokens, significant: significant, objectNames: objectNames, temporaryObjectNames: temporaryObjectNames, cteNames: cteNames)

        for position in significant.indices {
            let index = significant[position]
            guard tokens[index].kind == .identifier else { continue }
            let value = tokens[index].value
            let lower = value.lowercased()

            if ["sqlite_master", "sqlite_schema"].contains(lower) {
                guard !Self.isQualified(tokens, significant: significant, at: position) else {
                    throw BindingError.crossDatabaseAccess
                }
                tokens[index].raw = Self.quote("tb_logical_catalog")
                continue
            }
            if ["sqlite_temp_master", "sqlite_temp_schema"].contains(lower) {
                throw BindingError.crossDatabaseAccess
            }
            if lower == "sqlite_sequence" {
                guard !Self.isQualified(tokens, significant: significant, at: position) else {
                    throw BindingError.crossDatabaseAccess
                }
                tokens[index].raw = Self.quote("tb_logical_sequence")
                continue
            }
            if lower.hasPrefix("sqlite_") {
                if let logical = Self.logicalAutoindexName(value, objectNames: objectNames) {
                    tokens[index].raw = Self.quote(physical(logical))
                    continue
                }
                throw BindingError.unknownReservedObject
            }
            if objectNames.contains(lower), !cteNames.contains(lower) {
                tokens[index].raw = Self.quote(physical(value))
            }
        }
        return tokens.map(\.raw).joined()
    }

    /// Translate physical identifiers in sqlite_master SQL back only when the
    /// complete name belongs to this namespace.
    func unbind(_ sql: String) throws -> String {
        try Self.tokens(sql).map { token in
            guard token.kind == .identifier,
                  let logical = logicalName(forPhysical: token.value) else { return token.raw }
            return Self.quote(logical)
        }.joined()
    }

    /// Canonical SQL spelling used for schema proofs. Identifier quote style,
    /// keyword case, comments, and whitespace do not affect the digest; literal
    /// values and punctuation remain exact.
    static func canonicalSQL(_ sql: String) throws -> String {
        try tokens(sql).filter { $0.kind != .trivia }.map { token in
            switch token.kind {
            case .identifier:
                let value = token.value.lowercased()
                return "I\(value.utf8.count):\(value);"
            case .string:
                return "S\(token.value.utf8.count):\(token.value);"
            case .punctuation:
                return "P\(token.raw.utf8.count):\(token.raw);"
            case .trivia:
                return ""
            }
        }.joined()
    }

    static func tokens(_ sql: String) throws -> [Token] {
        let chars = Array(sql)
        var result: [Token] = [], cursor = 0
        while cursor < chars.count {
            let start = cursor, char = chars[cursor]
            if char.isWhitespace {
                cursor += 1
                while cursor < chars.count && chars[cursor].isWhitespace { cursor += 1 }
                result.append(.init(kind: .trivia, raw: String(chars[start..<cursor]), value: "")); continue
            }
            if char == "-", cursor + 1 < chars.count, chars[cursor + 1] == "-" {
                cursor += 2
                while cursor < chars.count && chars[cursor] != "\n" { cursor += 1 }
                result.append(.init(kind: .trivia, raw: String(chars[start..<cursor]), value: "")); continue
            }
            if char == "/", cursor + 1 < chars.count, chars[cursor + 1] == "*" {
                cursor += 2
                while cursor + 1 < chars.count && !(chars[cursor] == "*" && chars[cursor + 1] == "/") { cursor += 1 }
                guard cursor + 1 < chars.count else { throw BindingError.malformedSQL }
                cursor += 2
                result.append(.init(kind: .trivia, raw: String(chars[start..<cursor]), value: "")); continue
            }
            if ["'", "\"", "`", "["].contains(char) {
                let end: Character = char == "[" ? "]" : char
                var value = "", closed = false
                cursor += 1
                while cursor < chars.count {
                    if chars[cursor] == end {
                        cursor += 1
                        if cursor < chars.count && chars[cursor] == end && char != "[" {
                            value.append(end); cursor += 1
                        } else { closed = true; break }
                    } else { value.append(chars[cursor]); cursor += 1 }
                }
                guard closed else { throw BindingError.malformedSQL }
                result.append(.init(kind: char == "'" ? .string : .identifier, raw: String(chars[start..<cursor]), value: value)); continue
            }
            if char.isLetter || char == "_" {
                cursor += 1
                while cursor < chars.count && (chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" || chars[cursor] == "$") { cursor += 1 }
                let word = String(chars[start..<cursor])
                result.append(.init(kind: .identifier, raw: word, value: word)); continue
            }
            cursor += 1
            result.append(.init(kind: .punctuation, raw: String(char), value: String(char)))
        }
        return result
    }

    private static func rejectForbiddenStatements(_ tokens: [Token], significant: [Int]) throws {
        guard let first = significant.first else { return }
        if keyword(tokens[first], is: ["ATTACH", "DETACH"]) { throw BindingError.crossDatabaseAccess }
        if keyword(tokens[first], is: ["PRAGMA"]) { throw BindingError.unsupportedSQL }
        for index in significant where keyword(tokens[index], is: ["ATTACH", "DETACH"]) {
            throw BindingError.crossDatabaseAccess
        }
    }

    private static func validateObjectReferences(
        _ tokens: [Token], significant: [Int], objectNames: Set<String>, temporaryObjectNames: Set<String>, cteNames: Set<String>
    ) throws {
        guard let first = significant.first else { return }
        let statement = tokens[first].value.uppercased()
        let commaSeparatedFromReferences = fromClauseReferences(tokens, significant: significant)
        let isCreateTrigger = statement == "CREATE"
            && significant.contains(where: { keyword(tokens[$0], is: ["TRIGGER"]) })
        let isCreateIndex = statement == "CREATE"
            && significant.contains(where: { keyword(tokens[$0], is: ["INDEX"]) })
        let triggerBodyStart = isCreateTrigger
            ? significant.firstIndex(where: { keyword(tokens[$0], is: ["BEGIN"]) })
            : nil
        let objectTargetOnPosition: Int? = {
            guard isCreateTrigger || isCreateIndex,
                  let objectKind = significant.firstIndex(where: { keyword(tokens[$0], is: isCreateTrigger ? ["TRIGGER"] : ["INDEX"]) }) else {
                return nil
            }
            let end = triggerBodyStart ?? significant.count
            return significant.indices.first(where: { position in
                position > objectKind && position < end && keyword(tokens[significant[position]], is: ["ON"])
            })
        }()
        for position in significant.indices {
            let index = significant[position]
            let token = tokens[index]
            guard token.kind == .identifier else { continue }
            let word = token.value.lowercased()
            let previousKeyword = position > 0 ? tokens[significant[position - 1]].value.uppercased() : ""
            let previousPreviousKeyword = position > 1 ? tokens[significant[position - 2]].value.uppercased() : ""
            let isTriggerEventClause = isCreateTrigger
                && (triggerBodyStart.map { position < $0 } ?? true)
            let isTableReference =
                ["FROM", "JOIN", "REFERENCES"].contains(previousKeyword)
                || (previousKeyword == "INTO" && statement != "PRAGMA")
                || (previousKeyword == "UPDATE" && previousPreviousKeyword != "DO" && !isTriggerEventClause)
                || (position == 1 && statement == "UPDATE")
                || commaSeparatedFromReferences.contains(position)
                || (objectTargetOnPosition.map { position == $0 + 1 } ?? false)
            guard isTableReference else { continue }
            if ["(", "SELECT"].contains(word.uppercased()) { continue }
            if ["sqlite_master", "sqlite_schema", "sqlite_sequence"].contains(word) {
                guard !isQualified(tokens, significant: significant, at: position) else { throw BindingError.crossDatabaseAccess }
                continue
            }
            if word == "main" {
                guard position + 2 < significant.count,
                      tokens[significant[position + 1]].value == "." else { throw BindingError.crossDatabaseAccess }
                let target = tokens[significant[position + 2]].value.lowercased()
                guard objectNames.contains(target), !temporaryObjectNames.contains(target), !target.hasPrefix("sqlite_") else { throw BindingError.crossDatabaseAccess }
                continue
            }
            if word == "temp" {
                guard position + 2 < significant.count,
                      tokens[significant[position + 1]].value == ".",
                      temporaryObjectNames.contains(tokens[significant[position + 2]].value.lowercased()) else {
                    throw BindingError.crossDatabaseAccess
                }
                continue
            }
            if word.hasPrefix("sqlite_") { throw BindingError.crossDatabaseAccess }
            if objectNames.contains(word) || cteNames.contains(word) { continue }
            // SQLite table-valued JSON helpers do not refer to a database
            // object. Other unknown table references could escape a partition.
            if ["json_each", "json_tree"].contains(word) { continue }
            throw BindingError.crossDatabaseAccess
        }
    }

    /// Collect each table source in FROM/JOIN lists, including comma joins.
    /// A reference after the first comma is still an A-wide escape unless it
    /// belongs to this logical store, so it must be validated explicitly.
    private static func fromClauseReferences(_ tokens: [Token], significant: [Int]) -> Set<Int> {
        let clauseEnd: Set<String> = ["WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "UNION", "EXCEPT", "INTERSECT", "WINDOW", "RETURNING"]
        let joinModifiers: Set<String> = ["LEFT", "RIGHT", "FULL", "INNER", "OUTER", "CROSS", "NATURAL", "LATERAL"]
        var result = Set<Int>()
        var activeDepths = Set<Int>()
        var depth = 0
        var expectSourceAt: Int?

        for position in significant.indices {
            let token = tokens[significant[position]]
            let word = token.value.uppercased()
            if token.value == ")" {
                activeDepths.remove(depth)
                depth = max(0, depth - 1)
            }
            if token.value == "(" {
                if let expected = expectSourceAt, position >= expected { expectSourceAt = nil }
                depth += 1
                continue
            }

            if keyword(token, is: ["FROM"]) {
                activeDepths.insert(depth)
                expectSourceAt = position + 1
                continue
            }
            guard activeDepths.contains(depth) else { continue }
            if clauseEnd.contains(word) {
                activeDepths.remove(depth)
                expectSourceAt = nil
                continue
            }
            if token.value == "," {
                expectSourceAt = position + 1
                continue
            }
            if keyword(token, is: ["JOIN"]) {
                expectSourceAt = position + 1
                continue
            }
            guard let expected = expectSourceAt else { continue }
            if position < expected { continue }
            if joinModifiers.contains(word) { expectSourceAt = position + 1; continue }
            if token.kind == .identifier {
                result.insert(position)
                expectSourceAt = nil
            } else if token.value == "(" {
                // A parenthesized SELECT is scoped recursively by the outer
                // scan; this item itself is not an external table name.
                expectSourceAt = nil
            } else if token.value != "." {
                expectSourceAt = nil
            }
        }
        return result
    }

    private static func validateDDLTarget(
        _ tokens: [Token], significant: [Int], objectNames: Set<String>, temporaryObjectNames: Set<String>
    ) throws {
        guard let first = significant.first else { return }
        let operation = tokens[first].value.uppercased()
        guard operation == "DROP" || operation == "ALTER" else { return }
        guard let kindPosition = significant.indices.dropFirst().first(where: { position in
            keyword(tokens[significant[position]], is: ["TABLE", "INDEX", "VIEW", "TRIGGER"])
        }) else { throw BindingError.unsupportedSQL }
        var targetPosition = kindPosition + 1
        while targetPosition < significant.count,
              keyword(tokens[significant[targetPosition]], is: ["IF", "EXISTS", "NOT"]) { targetPosition += 1 }
        guard targetPosition < significant.count else { throw BindingError.malformedSQL }
        var target = tokens[significant[targetPosition]].value
        if target.lowercased() == "main" {
            guard targetPosition + 2 < significant.count,
                  tokens[significant[targetPosition + 1]].value == "." else { throw BindingError.crossDatabaseAccess }
            targetPosition += 2
            target = tokens[significant[targetPosition]].value
            guard !temporaryObjectNames.contains(target.lowercased()) else { throw BindingError.crossDatabaseAccess }
        } else if target.lowercased() == "temp" {
            guard kindPosition + 1 < significant.count,
                  keyword(tokens[significant[kindPosition]], is: ["TABLE"]),
                  targetPosition + 2 < significant.count,
                  tokens[significant[targetPosition + 1]].value == "." else {
                throw BindingError.crossDatabaseAccess
            }
            targetPosition += 2
            target = tokens[significant[targetPosition]].value
            guard temporaryObjectNames.contains(target.lowercased()) else { throw BindingError.crossDatabaseAccess }
        } else if isSchemaToken(tokens[significant[targetPosition]]) {
            throw BindingError.crossDatabaseAccess
        }
        let lower = target.lowercased()
        guard objectNames.contains(lower)
                || (lower.hasPrefix("sqlite_autoindex_") && logicalAutoindexName(target, objectNames: objectNames) != nil) else {
            throw BindingError.crossDatabaseAccess
        }
    }

    private static func collectCTENames(_ tokens: [Token], significant: [Int]) throws -> Set<String> {
        guard let first = significant.first, keyword(tokens[first], is: ["WITH"]) else { return [] }
        var result = Set<String>()
        var position = 1
        if position < significant.count, keyword(tokens[significant[position]], is: ["RECURSIVE"]) { position += 1 }
        while position < significant.count {
            let nameIndex = significant[position]
            guard tokens[nameIndex].kind == .identifier else { break }
            result.insert(tokens[nameIndex].value.lowercased())
            position += 1
            if position < significant.count, tokens[significant[position]].value == "(" {
                position = try afterBalancedParentheses(tokens, significant, from: position)
            }
            guard position < significant.count, keyword(tokens[significant[position]], is: ["AS"]) else { break }
            position += 1
            guard position < significant.count, tokens[significant[position]].value == "(" else { throw BindingError.malformedSQL }
            position = try afterBalancedParentheses(tokens, significant, from: position)
            guard position < significant.count, tokens[significant[position]].value == "," else { break }
            position += 1
        }
        return result
    }

    private static func afterBalancedParentheses(_ tokens: [Token], _ significant: [Int], from start: Int) throws -> Int {
        var depth = 0
        for position in start..<significant.count {
            let value = tokens[significant[position]].value
            if value == "(" { depth += 1 }
            else if value == ")" {
                depth -= 1
                if depth == 0 { return position + 1 }
            }
        }
        throw BindingError.malformedSQL
    }

    private static func keyword(_ token: Token, is values: Set<String>) -> Bool {
        token.kind == .identifier && token.raw == token.value && values.contains(token.value.uppercased())
    }

    private static func keyword(_ token: Token, is values: [String]) -> Bool {
        keyword(token, is: Set(values))
    }

    private static func isSchemaToken(_ token: Token) -> Bool {
        ["main", "temp"].contains(token.value.lowercased())
    }

    private static func isQualified(_ tokens: [Token], significant: [Int], at position: Int) -> Bool {
        (position > 0 && tokens[significant[position - 1]].value == ".")
            || (position + 1 < significant.count && tokens[significant[position + 1]].value == ".")
    }

    private static func logicalAutoindexName(_ name: String, objectNames: Set<String>) -> String? {
        guard name.lowercased().hasPrefix("sqlite_autoindex_") else { return nil }
        let suffix = String(name.dropFirst("sqlite_autoindex_".count))
        guard let (table, ordinal) = autoindexParts(suffix), objectNames.contains(table.lowercased()) else { return nil }
        return "sqlite_autoindex_\(table)_\(ordinal)"
    }

    private static func autoindexParts(_ suffix: String) -> (String, String)? {
        guard let separator = suffix.lastIndex(of: "_") else { return nil }
        let table = String(suffix[..<separator]), ordinal = String(suffix[suffix.index(after: separator)...])
        guard !table.isEmpty, !ordinal.isEmpty, ordinal.allSatisfy(\.isNumber) else { return nil }
        return (table, ordinal)
    }
}

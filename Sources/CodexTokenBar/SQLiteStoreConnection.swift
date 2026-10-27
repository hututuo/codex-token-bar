import Foundation
import SQLite3

final class SQLiteStoreBinding {
    let store: BusinessSQLiteStore
    var namespace: SQLiteStoreNamespace

    init(store: BusinessSQLiteStore, names: Set<String>) {
        self.store = store
        namespace = .init(prefix: store.prefix, objectNames: names)
    }

    func sql(_ sql: String) throws -> String {
        var statements: [String] = [], pending = ""
        for token in try SQLiteStoreNamespace.tokens(sql) {
            pending += token.raw
            if token.raw == ";", token.kind == .punctuation, sqlite3_complete(pending) != 0 {
                statements.append(try bindStatement(pending))
                pending = ""
            }
        }
        if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            statements.append(try bindStatement(pending))
        }
        return statements.map { statement in
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasSuffix(";") ? trimmed : trimmed + ";"
        }.joined(separator: "\n")
    }

    private func bindStatement(_ sql: String) throws -> String {
        let tokens = try SQLiteStoreNamespace.tokens(sql)
        let parts = tokens.filter { $0.kind != .trivia && !($0.kind == .punctuation && $0.value == ";") }
        guard let first = parts.first else { return sql }
        if Self.keyword(first, "PRAGMA") { return try bindPragma(parts) }

        // A module must never run physical-database maintenance. VACUUM INTO
        // is intercepted by the driver and exports this partition separately.
        if Self.keyword(first, "VACUUM") {
            guard !parts.contains(where: { Self.keyword($0, "INTO") }) else {
                throw SQLiteStoreNamespace.BindingError.crossDatabaseAccess
            }
            return "PRAGMA optimize"
        }
        return try namespace.bind(sql)
    }

    private func bindPragma(_ parts: [SQLiteStoreNamespace.Token]) throws -> String {
        guard parts.count >= 2, parts[1].kind == .identifier else {
            throw SQLiteStoreNamespace.BindingError.unsupportedSQL
        }
        guard parts.count == 2 || parts[2].value != "." else {
            throw SQLiteStoreNamespace.BindingError.crossDatabaseAccess
        }
        let name = parts[1].value.lowercased()

        if name == "user_version" {
            if parts.count == 2 { return "SELECT user_version FROM main.tb_stores WHERE store_id='\(store.id)'" }
            let number = parts.count > 3 ? parts.dropFirst(3).map(\.raw).joined() : ""
            guard parts.count >= 4, parts[2].value == "=", !number.isEmpty,
                  number.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(number), value >= 0, value <= Int(Int32.max) else {
                throw SQLiteStoreNamespace.BindingError.unsupportedSQL
            }
            return "UPDATE main.tb_stores SET user_version=\(value),revision=revision+1 WHERE store_id='\(store.id)'"
        }

        let objectMetadata = ["table_info", "table_xinfo", "index_list", "index_info", "index_xinfo", "foreign_key_list"]
        if objectMetadata.contains(name) || ((name == "quick_check" || name == "integrity_check") && parts.count > 2) {
            guard parts.count == 5, parts[2].value == "(", parts[3].kind == .identifier || parts[3].kind == .string,
                  parts[4].value == ")" else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            let logical = parts[3].value
            let lower = logical.lowercased()
            guard namespace.objectNames.contains(lower)
                    || (lower.hasPrefix("sqlite_autoindex_") && namespace.physical(logical).hasPrefix("sqlite_autoindex_")) else {
                throw SQLiteStoreNamespace.BindingError.crossDatabaseAccess
            }
            return "PRAGMA \(name)(\(SQLiteStoreNamespace.quote(namespace.physical(logical))))"
        }

        if name == "foreign_key_check" {
            let argument: String?
            if parts.count == 2 { argument = nil }
            else if parts.count == 5, parts[2].value == "(",
                    (parts[3].kind == .identifier || parts[3].kind == .string), parts[4].value == ")" {
                let logical = parts[3].value
                guard namespace.objectNames.contains(logical.lowercased()) else {
                    throw SQLiteStoreNamespace.BindingError.crossDatabaseAccess
                }
                argument = "('\(namespace.physical(logical).replacingOccurrences(of: "'", with: "''"))')"
            } else {
                throw SQLiteStoreNamespace.BindingError.unsupportedSQL
            }
            let prefix = store.prefix.replacingOccurrences(of: "'", with: "''")
            let length = store.prefix.count
            let argumentSQL = argument ?? ""
            let from = "pragma_foreign_key_check\(argumentSQL)"
            return "SELECT substr(\"table\",\(length + 1)) AS \"table\",rowid,CASE WHEN substr(parent,1,\(length))='\(prefix)' THEN substr(parent,\(length + 1)) ELSE parent END AS parent,fkid FROM \(from) WHERE substr(\"table\",1,\(length))='\(prefix)'"
        }

        if name == "quick_check" || name == "integrity_check" {
            guard parts.count == 2 else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            let table = name == "quick_check" ? "pragma_quick_check" : "pragma_integrity_check"
            return "SELECT CASE WHEN EXISTS(SELECT 1 FROM \(table) WHERE \(name)<>'ok') THEN 'corrupt' ELSE 'ok' END"
        }

        if name == "journal_mode" {
            if parts.count == 2 { return "PRAGMA main.journal_mode" }
            let value = try Self.assignmentValue(parts)
            guard ["DELETE", "TRUNCATE", "PERSIST", "MEMORY", "WAL", "OFF"].contains(value.uppercased()) else {
                throw SQLiteStoreNamespace.BindingError.unsupportedSQL
            }
            // A journal-mode write would affect every module. Report the
            // container's current mode and keep it unchanged.
            return "PRAGMA main.journal_mode"
        }

        if name == "wal_checkpoint" {
            if parts.count != 2 {
                guard parts.count == 5, parts[2].value == "(", parts[3].kind == .identifier,
                      ["PASSIVE", "FULL", "RESTART", "TRUNCATE"].contains(parts[3].value.uppercased()), parts[4].value == ")" else {
                    throw SQLiteStoreNamespace.BindingError.unsupportedSQL
                }
            }
            // Do not checkpoint the physical A WAL on behalf of one module.
            return "SELECT 0 AS busy,0 AS log,0 AS checkpointed"
        }

        if name == "temp_store" {
            if parts.count == 2 { return "PRAGMA temp_store" }
            let value = try Self.assignmentValue(parts)
            guard ["FILE", "MEMORY", "DEFAULT", "0", "1", "2"].contains(value.uppercased()) else {
                throw SQLiteStoreNamespace.BindingError.unsupportedSQL
            }
            // Driver establishes FILE before installing TEMP catalog views.
            // Reapplying this pragma would delete those connection-local views.
            return "SELECT 1"
        }

        if name == "optimize" {
            guard parts.count == 2 else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            return "SELECT 1"
        }

        if ["page_count", "freelist_count", "page_size"].contains(name) {
            guard parts.count == 2 else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            return "PRAGMA main.\(name)"
        }

        // These settings affect only this connection. In particular, a caller
        // cannot turn off query_only after a store has been sealed.
        let connectionSettings: Set<String> = [
            "foreign_keys", "defer_foreign_keys", "busy_timeout", "synchronous",
            "temp_store", "cache_size", "mmap_size"
        ]
        if connectionSettings.contains(name) {
            if parts.count == 2 { return "PRAGMA \(name)" }
            let value = try Self.assignmentValue(parts)
            let upper = value.uppercased()
            switch name {
            case "foreign_keys", "defer_foreign_keys":
                guard ["ON", "OFF", "TRUE", "FALSE", "1", "0"].contains(upper) else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            case "synchronous":
                guard ["OFF", "NORMAL", "FULL", "EXTRA", "0", "1", "2", "3"].contains(upper) else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            case "temp_store":
                guard ["DEFAULT", "FILE", "MEMORY", "0", "1", "2"].contains(upper) else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            case "busy_timeout":
                guard let value = Int(value), (0...Int(Int32.max)).contains(value) else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            case "cache_size":
                guard Int(value) != nil else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            case "mmap_size":
                guard let value = Int64(value), value >= 0 else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
            default: throw SQLiteStoreNamespace.BindingError.unsupportedSQL
            }
            return "PRAGMA \(name)=\(value)"
        }

        if name == "query_only" {
            if parts.count != 2 {
                let value = try Self.assignmentValue(parts)
                guard Self.isOn(value) else { throw SQLiteStoreNamespace.BindingError.unsupportedSQL }
                return "PRAGMA query_only=ON"
            }
            return "PRAGMA query_only"
        }
        throw SQLiteStoreNamespace.BindingError.crossDatabaseAccess
    }

    private static func assignmentValue(_ parts: [SQLiteStoreNamespace.Token]) throws -> String {
        guard parts.count >= 4, parts[2].value == "=" else {
            throw SQLiteStoreNamespace.BindingError.unsupportedSQL
        }
        let valueTokens = Array(parts.dropFirst(3))
        guard !valueTokens.isEmpty,
              valueTokens.allSatisfy({ $0.kind == .identifier || $0.kind == .punctuation }),
              !valueTokens.contains(where: { [";", "(", ")", ".", ",", "?", "'", "\""].contains($0.raw) }) else {
            throw SQLiteStoreNamespace.BindingError.unsupportedSQL
        }
        return valueTokens.map(\.raw).joined()
    }

    private static func isOn(_ value: String) -> Bool {
        ["ON", "TRUE", "1"].contains(value.uppercased())
    }

    private static func keyword(_ token: SQLiteStoreNamespace.Token, _ value: String) -> Bool {
        token.kind == .identifier && token.raw == token.value && token.value.uppercased() == value
    }
}

extension SQLiteDatabaseConnection {
    func installBusinessStore(_ store: BusinessSQLiteStore) throws {
        let state = try readRows("SELECT state FROM main.tb_stores WHERE store_id=?", bindings: [.text(store.id)]) { $0.text(0) }.first ?? nil
        guard state == "ready" || state == "sealed" || state == "staging" else { throw BusinessStoreError.invalidStore }

        let objects = try readRows(
            "SELECT name FROM main.sqlite_master WHERE substr(name,1,?)=?",
            bindings: [.int(store.prefix.count), .text(store.prefix)]
        ) { $0.text(0) ?? "" }
        let binding = SQLiteStoreBinding(
            store: store,
            names: Set(objects.map { String($0.dropFirst(store.prefix.count)).lowercased() })
        )
        let context = Unmanaged.passRetained(binding).toOpaque()
        let status = sqlite3_create_function_v2(
            rawDatabase,
            "tb_unqualified_sql",
            1,
            SQLITE_UTF8 | SQLITE_DETERMINISTIC,
            context,
            { ctx, count, args in
                guard let ctx, count == 1, let value = args?[0], sqlite3_value_type(value) != SQLITE_NULL,
                      let ptr = sqlite3_value_text(value), let raw = sqlite3_user_data(ctx) else {
                    sqlite3_result_null(ctx); return
                }
                let binding = Unmanaged<SQLiteStoreBinding>.fromOpaque(raw).takeUnretainedValue()
                let input = String(decoding: UnsafeBufferPointer(start: ptr, count: Int(sqlite3_value_bytes(value))), as: UTF8.self)
                do {
                    let output = try binding.namespace.unbind(input)
                    output.withCString { sqlite3_result_text(ctx, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                } catch { sqlite3_result_error(ctx, "Invalid stored schema SQL", -1) }
            }, nil, nil,
            { raw in if let raw { Unmanaged<SQLiteStoreBinding>.fromOpaque(raw).release() } }
        )
        guard status == SQLITE_OK else { throw BusinessStoreError.invalidStore }
        try execute("DROP VIEW IF EXISTS temp.tb_logical_catalog")
        try execute("DROP VIEW IF EXISTS temp.tb_logical_sequence")
        try execute("""
        CREATE TEMP VIEW tb_logical_catalog AS
        SELECT type,
          CASE WHEN substr(name,1,\(store.prefix.count))='\(store.prefix)' THEN substr(name,\(store.prefix.count + 1))
               ELSE 'sqlite_autoindex_' || substr(name,(\("sqlite_autoindex_".count + store.prefix.count + 1))) END AS name,
          CASE WHEN substr(tbl_name,1,\(store.prefix.count))='\(store.prefix)' THEN substr(tbl_name,\(store.prefix.count + 1)) ELSE tbl_name END AS tbl_name,
          rootpage,tb_unqualified_sql(sql) AS sql
        FROM main.sqlite_master
        WHERE substr(name,1,\(store.prefix.count))='\(store.prefix)'
           OR substr(tbl_name,1,\(store.prefix.count))='\(store.prefix)'
        """)
        try execute("""
        CREATE TEMP VIEW tb_logical_sequence AS
        SELECT substr(name,\(store.prefix.count + 1)) AS name, seq
        FROM main.sqlite_sequence
        WHERE substr(name,1,\(store.prefix.count))='\(store.prefix)'
        """)
        businessBinding = binding
        if state == "sealed" { try execute("PRAGMA query_only=ON") }
    }
}

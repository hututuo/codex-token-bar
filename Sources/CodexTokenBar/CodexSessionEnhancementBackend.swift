// SPDX-License-Identifier: AGPL-3.0-only
// Behavior adapted from CodexPlusPlus v1.2.41 (BigPizzaV3), then rewritten
// for Codex Token Bar's Swift-native bridge. See OPEN_SOURCE_NOTICES.md.

import Foundation

struct CodexMarkdownExportPayload: Equatable, Sendable {
    let filename: String
    let markdown: String
    let message: String
}

struct CodexWorkspaceMovePayload: Equatable, Sendable {
    let message: String
    let previousCwd: String
    let targetCwd: String
}

protocol CodexSessionEnhancementExecuting: Sendable {
    func exportMarkdown(threadID: String, fallbackTitle: String) async throws -> CodexMarkdownExportPayload
    func moveThreadWorkspace(threadID: String, targetCwd: String) async throws -> CodexWorkspaceMovePayload
}

final class FoundationCodexSessionEnhancementExecutor: CodexSessionEnhancementExecuting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexTokenBar.SessionEnhancements")
    private let dataSourceResolver: @Sendable () -> CodexDataSource?

    init(
        dataSourceResolver: @escaping @Sendable () -> CodexDataSource? = {
            CodexDataSourceResolver().resolve()
        }
    ) {
        self.dataSourceResolver = dataSourceResolver
    }

    func exportMarkdown(
        threadID: String,
        fallbackTitle: String
    ) async throws -> CodexMarkdownExportPayload {
        try CodexThreadID.validate(threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [dataSourceResolver] in
                continuation.resume(with: Result {
                    guard let dataSource = dataSourceResolver() else {
                        throw CodexSessionEnhancementBackendError.dataSourceUnavailable
                    }
                    return try Self.exportMarkdown(
                        threadID: threadID,
                        fallbackTitle: fallbackTitle,
                        dataSource: dataSource,
                        fileManager: .default
                    )
                })
            }
        }
    }

    func moveThreadWorkspace(
        threadID: String,
        targetCwd: String
    ) async throws -> CodexWorkspaceMovePayload {
        try CodexThreadID.validate(threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [dataSourceResolver] in
                continuation.resume(with: Result {
                    guard let dataSource = dataSourceResolver() else {
                        throw CodexSessionEnhancementBackendError.dataSourceUnavailable
                    }
                    return try Self.moveThreadWorkspace(
                        threadID: threadID,
                        targetCwd: targetCwd,
                        dataSource: dataSource,
                        fileManager: .default
                    )
                })
            }
        }
    }

    private static func exportMarkdown(
        threadID: String,
        fallbackTitle: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> CodexMarkdownExportPayload {
        let record = try threadRecord(threadID: threadID, dataSource: dataSource)
        let title = displayTitle(record.title.isEmpty ? fallbackTitle : record.title)
        let rolloutURL = try trustedRolloutURL(
            record.rolloutPath,
            dataSource: dataSource,
            fileManager: fileManager
        )
        let messages = try loadMessages(from: rolloutURL)
        guard !messages.isEmpty else {
            throw CodexSessionEnhancementBackendError.noExportableMessages
        }
        let filename = buildFilename(title: title, threadID: threadID)
        return CodexMarkdownExportPayload(
            filename: filename,
            markdown: renderMarkdown(title: title, messages: messages),
            message: "已生成 Markdown：\(filename)"
        )
    }

    private static func moveThreadWorkspace(
        threadID: String,
        targetCwd: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> CodexWorkspaceMovePayload {
        let target = URL(fileURLWithPath: (targetCwd as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CodexSessionEnhancementBackendError.invalidTargetDirectory(target.path)
        }

        let record = try threadRecord(threadID: threadID, dataSource: dataSource)
        let rolloutURL: URL?
        if record.rolloutPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rolloutURL = nil
        } else {
            rolloutURL = try trustedRolloutURL(
                record.rolloutPath,
                dataSource: dataSource,
                fileManager: fileManager
            )
        }
        let originalRolloutData = rolloutURL.flatMap { try? Data(contentsOf: $0) }
        let nextRolloutData: Data?
        if let rolloutURL {
            nextRolloutData = try Self.updatedRolloutData(
                at: rolloutURL,
                threadID: threadID,
                targetCwd: target.path
            )
        } else {
            nextRolloutData = nil
        }

        if let rolloutURL, let nextRolloutData {
            try nextRolloutData.write(to: rolloutURL, options: Data.WritingOptions.atomic)
        }

        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: false,
            busyTimeoutMilliseconds: 5_000
        )
        do {
            let changed = try database.executeChangedRows(
                "UPDATE threads SET cwd = ?1 WHERE id = ?2",
                bindings: [.text(target.path), .text(threadID)]
            )
            guard changed == 1 else {
                throw CodexSessionEnhancementBackendError.threadNotFound(threadID)
            }
        } catch {
            if let rolloutURL, let originalRolloutData {
                try? originalRolloutData.write(to: rolloutURL, options: .atomic)
            }
            throw error
        }

        return CodexWorkspaceMovePayload(
            message: "已移动对话",
            previousCwd: record.cwd,
            targetCwd: target.path
        )
    }

    private struct ThreadRecord {
        let title: String
        let cwd: String
        let rolloutPath: String
    }

    private struct ExportMessage {
        let speaker: String
        let timestamp: String?
        let body: String
    }

    private static func threadRecord(
        threadID: String,
        dataSource: CodexDataSource
    ) throws -> ThreadRecord {
        guard FileManager.default.fileExists(atPath: dataSource.stateDatabase.path) else {
            throw CodexSessionEnhancementBackendError.databaseUnavailable
        }
        let database = SQLiteDatabaseDriver(
            url: dataSource.stateDatabase,
            readOnly: true,
            busyTimeoutMilliseconds: 5_000
        )
        let columns = Set(try database.readRows("PRAGMA table_info(threads)") { statement in
            statement.text(1) ?? ""
        })
        guard columns.contains("id"),
              columns.contains("title"),
              columns.contains("cwd"),
              columns.contains("rollout_path") else {
            throw CodexSessionEnhancementBackendError.unsupportedSchema
        }
        let rows = try database.readRows(
            "SELECT title, cwd, rollout_path FROM threads WHERE id = ?1 LIMIT 1",
            bindings: [.text(threadID)]
        ) { statement in
            ThreadRecord(
                title: statement.text(0) ?? "",
                cwd: statement.text(1) ?? "",
                rolloutPath: statement.text(2) ?? ""
            )
        }
        guard let record = rows.first else {
            throw CodexSessionEnhancementBackendError.threadNotFound(threadID)
        }
        return record
    }

    private static func trustedRolloutURL(
        _ rawPath: String,
        dataSource: CodexDataSource,
        fileManager: FileManager
    ) throws -> URL {
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexSessionEnhancementBackendError.rolloutPathMissing
        }
        let expanded = (rawPath as NSString).expandingTildeInPath
        let candidate = (expanded as NSString).isAbsolutePath
            ? URL(fileURLWithPath: expanded)
            : dataSource.codexHome.appendingPathComponent(expanded)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let home = dataSource.codexHome.standardizedFileURL.resolvingSymlinksInPath()
        let homePrefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        guard resolved.path.hasPrefix(homePrefix),
              fileManager.fileExists(atPath: resolved.path) else {
            throw CodexSessionEnhancementBackendError.untrustedRolloutPath(resolved.path)
        }
        return resolved
    }

    private static func loadMessages(from url: URL) throws -> [ExportMessage] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "response_item",
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String,
                  role == "user" || role == "assistant",
                  let content = payload["content"] as? [[String: Any]] else {
                return nil
            }
            let body = content.compactMap(serializeContentBlock).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return ExportMessage(
                speaker: role == "user" ? "User" : "Assistant",
                timestamp: formattedTimestamp(event["timestamp"] as? String),
                body: body
            )
        }
    }

    private static func serializeContentBlock(_ block: [String: Any]) -> String? {
        switch block["type"] as? String {
        case "input_text", "output_text":
            let text = (block["text"] as? String ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .newlines)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        case "input_image":
            let imageURL = (block["image_url"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !imageURL.isEmpty, !imageURL.hasPrefix("data:") else {
                return "> Image attachment"
            }
            return "> Image attachment\n[Image link](<\(imageURL)>)"
        default:
            return nil
        }
    }

    private static func formattedTimestamp(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return nil }
        return date.formatted(
            Date.FormatStyle()
                .year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
    }

    private static func displayTitle(_ value: String) -> String {
        let value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? "Untitled session" : value
    }

    private static func buildFilename(title: String, threadID: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { invalid.contains($0) ? " " : String($0) }.joined()
        var safeTitle = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        safeTitle = String(safeTitle.prefix(80))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if safeTitle.isEmpty { safeTitle = "Untitled session" }
        return "\(safeTitle)-\(threadID).md"
    }

    private static func renderMarkdown(
        title: String,
        messages: [ExportMessage]
    ) -> String {
        var lines = ["# \(title)", ""]
        for message in messages {
            lines.append("### \(message.speaker)")
            if let timestamp = message.timestamp {
                lines.append("_\(timestamp)_")
            }
            lines.append("")
            lines.append(message.body)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func updatedRolloutData(
        at url: URL,
        threadID: String,
        targetCwd: String
    ) throws -> Data {
        let text = try String(contentsOf: url, encoding: .utf8)
        let endsWithNewline = text.hasSuffix("\n")
        var changed = false
        let lines = try text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard !line.isEmpty,
                  let data = String(line).data(using: .utf8),
                  var event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "session_meta",
                  var payload = event["payload"] as? [String: Any],
                  payload["id"] as? String == threadID else {
                return String(line)
            }
            guard payload["cwd"] as? String != targetCwd else { return String(line) }
            payload["cwd"] = targetCwd
            event["payload"] = payload
            changed = true
            let encoded = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return String(decoding: encoded, as: UTF8.self)
        }
        guard changed else { return Data(text.utf8) }
        var output = lines.joined(separator: "\n")
        if endsWithNewline, !output.hasSuffix("\n") { output.append("\n") }
        return Data(output.utf8)
    }
}

enum CodexSessionEnhancementBackendError: LocalizedError {
    case dataSourceUnavailable
    case databaseUnavailable
    case invalidTargetDirectory(String)
    case noExportableMessages
    case rolloutPathMissing
    case threadNotFound(String)
    case unsupportedSchema
    case untrustedRolloutPath(String)

    var errorDescription: String? {
        switch self {
        case .dataSourceUnavailable:
            return "没有可用的 Codex 数据目录"
        case .databaseUnavailable:
            return "Codex 本地数据库不可用"
        case let .invalidTargetDirectory(path):
            return "目标项目目录不可用：\(path)"
        case .noExportableMessages:
            return "未找到可导出的用户或助手消息"
        case .rolloutPathMissing:
            return "会话缺少 rollout 文件路径"
        case let .threadNotFound(threadID):
            return "本地数据库中未找到会话：\(threadID)"
        case .unsupportedSchema:
            return "当前 Codex 本地存储结构不受支持"
        case let .untrustedRolloutPath(path):
            return "rollout 文件不存在或不在当前 Codex Home 内：\(path)"
        }
    }
}

import Foundation

enum AutoResumeApprovalEvaluation: Equatable, Sendable {
    case approve(decision: String, requestedTurnID: String?)
    case reject(decision: String, reason: String)
}

enum AutoResumeAutoApprovalPolicy {
    private enum MethodKind {
        case command
        case fileChange
        case legacyCommand
        case legacyFileChange

        var approvalDecision: String {
            switch self {
            case .command, .fileChange:
                return "accept"
            case .legacyCommand, .legacyFileChange:
                return "approved"
            }
        }

        var rejectionDecision: String {
            switch self {
            case .command, .fileChange:
                return "decline"
            case .legacyCommand, .legacyFileChange:
                return "denied"
            }
        }
    }

    static func isApprovalMethod(_ method: String) -> Bool {
        methodKind(method) != nil
    }

    static func evaluate(
        method: String,
        params: [String: Any],
        targetThreadID: String,
        boundTurnID: String?,
        turnStartPending: Bool
    ) -> AutoResumeApprovalEvaluation {
        guard let kind = methodKind(method) else {
            return .reject(decision: "decline", reason: "不是受支持的批准请求")
        }

        let requestedThreadID: String?
        switch kind {
        case .command, .fileChange:
            requestedThreadID = nonemptyString(params["threadId"])
        case .legacyCommand, .legacyFileChange:
            requestedThreadID = nonemptyString(params["conversationId"])
        }
        guard requestedThreadID == targetThreadID else {
            return .reject(decision: kind.rejectionDecision, reason: "批准请求不属于当前会话")
        }
        let requestIdentity: String?
        switch kind {
        case .command, .fileChange:
            requestIdentity = nonemptyString(params["itemId"])
        case .legacyCommand, .legacyFileChange:
            requestIdentity = nonemptyString(params["callId"])
        }
        guard requestIdentity != nil else {
            return .reject(decision: kind.rejectionDecision, reason: "批准请求缺少结构化请求 ID")
        }

        var requestedTurnID: String?
        switch kind {
        case .command, .fileChange:
            requestedTurnID = nonemptyString(params["turnId"])
            guard let requestedTurnID else {
                return .reject(decision: kind.rejectionDecision, reason: "批准请求缺少 turnId")
            }
            if let boundTurnID {
                guard requestedTurnID == boundTurnID else {
                    return .reject(decision: kind.rejectionDecision, reason: "批准请求不属于当前 turn")
                }
            } else if !turnStartPending {
                return .reject(decision: kind.rejectionDecision, reason: "当前尚未启动可批准的 turn")
            }
            if let available = params["availableDecisions"] as? [Any],
               !available.contains(where: acceptsSingleRequestDecision) {
                return .reject(decision: kind.rejectionDecision, reason: "Codex 未提供单次 accept 决策")
            }
        case .legacyCommand, .legacyFileChange:
            guard turnStartPending || boundTurnID != nil else {
                return .reject(decision: kind.rejectionDecision, reason: "当前尚未启动可批准的 turn")
            }
        }

        switch kind {
        case .command:
            if params["additionalPermissions"] != nil,
               !(params["additionalPermissions"] is NSNull) {
                return .reject(
                    decision: kind.rejectionDecision,
                    reason: "请求包含额外权限扩张，必须人工确认"
                )
            }
            if ["proposedExecpolicyAmendment", "proposedNetworkPolicyAmendments"].contains(
                where: { params[$0] != nil && !(params[$0] is NSNull) }
            ) {
                return .reject(
                    decision: kind.rejectionDecision,
                    reason: "请求包含持续策略扩张，必须人工确认"
                )
            }
            let commands = commandTexts(from: params)
            let hasNetworkContext = (params["networkApprovalContext"] as? [String: Any])?.isEmpty == false
            guard !commands.isEmpty || hasNetworkContext else {
                return .reject(decision: kind.rejectionDecision, reason: "无法解析待批准命令")
            }
            if let reason = commands.lazy.compactMap(destructiveReason(in:)).first {
                return .reject(decision: kind.rejectionDecision, reason: reason)
            }
        case .legacyCommand:
            let commands = commandTexts(from: params)
            guard !commands.isEmpty else {
                return .reject(decision: kind.rejectionDecision, reason: "无法解析待批准命令")
            }
            if let reason = commands.lazy.compactMap(destructiveReason(in:)).first {
                return .reject(decision: kind.rejectionDecision, reason: reason)
            }
        case .fileChange:
            if params["grantRoot"] != nil, !(params["grantRoot"] is NSNull) {
                return .reject(
                    decision: kind.rejectionDecision,
                    reason: "文件变更请求扩大持续写入根目录，必须人工确认"
                )
            }
        case .legacyFileChange:
            if params["grantRoot"] != nil, !(params["grantRoot"] is NSNull) {
                return .reject(
                    decision: kind.rejectionDecision,
                    reason: "文件变更请求扩大持续写入根目录，必须人工确认"
                )
            }
            guard let changes = params["fileChanges"] as? [String: Any], !changes.isEmpty else {
                return .reject(decision: kind.rejectionDecision, reason: "无法解析待批准文件变更")
            }
        }

        return .approve(
            decision: kind.approvalDecision,
            requestedTurnID: requestedTurnID
        )
    }

    static func destructiveReason(in command: String) -> String? {
        let lower = command.lowercased()
        let tokens = commandTokens(lower)
        guard !tokens.isEmpty else { return "命令为空或无法解析" }

        if let rmIndex = tokens.firstIndex(where: { executableName($0) == "rm" }) {
            let tail = tokens.suffix(from: rmIndex + 1)
            let recursive = tail.contains(where: { shortFlag($0, contains: "r") || $0 == "--recursive" })
            let force = tail.contains(where: { shortFlag($0, contains: "f") || $0 == "--force" })
            let dangerousRoot = tail.contains(where: isDangerousFilesystemRoot)
            if recursive && force {
                return "已拦截 rm 的递归强制删除"
            }
            if recursive && dangerousRoot {
                return "已拦截对文件系统根目录的递归删除"
            }
        }

        if let removeItemIndex = tokens.firstIndex(where: {
            ["remove-item", "removeitem"].contains(executableName($0))
        }) {
            let tail = tokens.suffix(from: removeItemIndex + 1)
            let recursive = tail.contains("-recurse")
            let force = tail.contains("-force")
            if recursive && force {
                return "已拦截 PowerShell 的递归强制删除"
            }
        }

        if let removeDirectoryIndex = tokens.firstIndex(where: {
            ["rd", "rmdir"].contains(executableName($0))
        }) {
            let tail = tokens.suffix(from: removeDirectoryIndex + 1)
            if tail.contains(where: { $0 == "/s" || $0.contains("/s") }) {
                return "已拦截 Windows 目录递归删除"
            }
        }

        if let deleteIndex = tokens.firstIndex(where: {
            ["del", "erase"].contains(executableName($0))
        }) {
            let tail = tokens.suffix(from: deleteIndex + 1)
            if tail.contains(where: { $0 == "/s" || $0.contains("/s") }) {
                return "已拦截 Windows 文件递归删除"
            }
        }

        if lower.contains("diskutil erasedisk")
            || lower.contains("diskutil partitiondisk")
            || lower.contains("diskutil zerodisk")
            || tokens.contains(where: { executableName($0).hasPrefix("mkfs") })
            || tokens.contains(where: {
                ["fdisk", "parted", "diskpart"].contains(executableName($0))
            })
            || lower.contains("clear-disk")
            || lower.contains("initialize-disk")
            || lower.contains("remove-partition")
            || lower.contains("format-volume")
        {
            return "已拦截磁盘格式化或分区命令"
        }

        if tokens.contains(where: { executableName($0) == "dd" }),
           lower.replacingOccurrences(of: " ", with: "").contains("of=/dev/")
            || lower.contains("physicaldrive") {
            return "已拦截向原始设备写入的 dd 命令"
        }

        if let formatIndex = tokens.firstIndex(where: { executableName($0) == "format" }),
           tokens.suffix(from: formatIndex + 1).contains(where: isDangerousFilesystemRoot) {
            return "已拦截 Windows 磁盘格式化命令"
        }

        if tokens.contains(where: { executableName($0) == "shred" }),
           tokens.contains(where: { $0.hasPrefix("/dev/") }) {
            return "已拦截原始设备擦除命令"
        }

        if let gitIndex = tokens.firstIndex(where: { executableName($0) == "git" }) {
            let tail = Array(tokens.suffix(from: gitIndex + 1))
            if tail.first == "reset", tail.contains("--hard") {
                return "已拦截 git reset --hard"
            }
            if tail.first == "clean" {
                let forced = tail.contains(where: { shortFlag($0, contains: "f") || $0 == "--force" })
                let broad = tail.contains(where: {
                    shortFlag($0, contains: "d")
                        || shortFlag($0, contains: "x")
                        || $0 == "--directories"
                })
                if forced && broad {
                    return "已拦截破坏性 git clean"
                }
            }
            if tail.first == "push",
               tail.contains(where: { $0 == "--force" || $0 == "-f" }) {
                return "已拦截 git 强制推送"
            }
        }

        if lower.contains("drop database")
            || lower.contains("drop schema")
            || lower.contains("truncate table")
            || lower.contains("flushall")
            || lower.contains("dropdatabase()")
        {
            return "已拦截不可逆数据库清空命令"
        }

        if tokens.contains(where: { executableName($0) == "find" }), tokens.contains("-delete") {
            return "已拦截 find 的批量删除"
        }

        return nil
    }

    private static func methodKind(_ method: String) -> MethodKind? {
        switch method.lowercased() {
        case "item/commandexecution/requestapproval":
            return .command
        case "item/filechange/requestapproval":
            return .fileChange
        case "execcommandapproval", "exec_command_approval":
            return .legacyCommand
        case "applypatchapproval", "apply_patch_approval":
            return .legacyFileChange
        default:
            return nil
        }
    }

    private static func commandTexts(from params: [String: Any]) -> [String] {
        var values: [String] = []
        if let command = nonemptyString(params["command"]) {
            values.append(command)
        } else if let command = params["command"] as? [String] {
            let joined = command.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { values.append(joined) }
        }
        if let actions = params["commandActions"] as? [[String: Any]] {
            values.append(contentsOf: actions.compactMap { action in
                if let command = nonemptyString(action["command"]) {
                    return command
                }
                if let command = action["command"] as? [String] {
                    let joined = command.joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return joined.isEmpty ? nil : joined
                }
                return nil
            })
        }
        if let parsed = params["parsedCmd"] as? [[String: Any]] {
            values.append(contentsOf: parsed.compactMap { nonemptyString($0["cmd"]) })
        }
        return values
    }

    private static func acceptsSingleRequestDecision(_ value: Any) -> Bool {
        if let text = nonemptyString(value) {
            return text.lowercased() == "accept"
        }
        guard let object = value as? [String: Any] else { return false }
        return ["decision", "type", "value"].contains { key in
            nonemptyString(object[key])?.lowercased() == "accept"
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func commandTokens(_ command: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ";|&(){}")
        )
        return command
            .components(separatedBy: separators)
            .map {
                $0.trimmingCharacters(
                    in: CharacterSet(charactersIn: "\"'`")
                )
            }
            .filter { !$0.isEmpty }
    }

    private static func executableName(_ token: String) -> String {
        let value = token
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map(String.init) ?? token
        return value.hasSuffix(".exe") ? String(value.dropLast(4)) : value
    }

    private static func shortFlag(_ token: String, contains character: Character) -> Bool {
        guard token.hasPrefix("-"), !token.hasPrefix("--") else { return false }
        return token.dropFirst().contains(character)
    }

    private static func isDangerousFilesystemRoot(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if ["/", "~", "$home", "${home}"].contains(normalized) {
            return true
        }
        if normalized.count == 3 {
            let characters = Array(normalized)
            return characters[1] == ":" && (characters[2] == "\\" || characters[2] == "/")
        }
        return false
    }
}

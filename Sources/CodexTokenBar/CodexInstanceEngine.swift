import AppKit
import CryptoKit
import Darwin
import Foundation

struct CodexInstancePaths: Sendable {
    let registry: URL
    let managedRoot: URL
    let syncRoot: URL

    static func system(fileManager: FileManager = .default) throws -> Self {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw codexInstanceError("无法定位系统应用支持目录")
        }
        let root = support.appendingPathComponent("CodexTokenBar", isDirectory: true)
        return Self(
            registry: root.appendingPathComponent("codex-instances.json"),
            managedRoot: root.appendingPathComponent("instances/codex", isDirectory: true),
            syncRoot: root.appendingPathComponent("instance-sync", isDirectory: true)
        )
    }
}

private struct CodexInstanceRegistryDocument: Codable {
    var schemaVersion: Int
    var updatedAt: Int64
    var instances: [CodexInstance]
    var conflicts: [CodexInstanceConflict]
}

private struct CodexInstanceSyncTransaction: Codable {
    var schemaVersion: Int
    var transactionId: String
    var createdAt: Int64
    var state: String
    var instanceIds: [String]
    var operations: [CodexInstanceSyncOperation]
    var conflicts: [CodexInstanceConflict]
}

final class CodexInstanceFileLock {
    private var descriptor: Int32

    init(url: URL, label: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw codexInstanceError("打开\(label)锁失败：\(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let detail = String(cString: strerror(errno))
            close(descriptor)
            throw codexInstanceError("\(label)正在由另一个 Token Bar 进程执行：\(detail)")
        }
    }

    // 使用点必须 defer { release() }：仅靠 `_ = lock` 时优化器有权在函数
    // 中途就 deinit（LOCK_UN + close），Release 构建下跨进程互斥失效。
    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

final class CodexInstanceEngine: @unchecked Sendable {
    private let paths: CodexInstancePaths
    private let defaultCodexHome: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let visibilityRebuilder: (@Sendable (URL) throws -> Void)?
    private let globalCodexRunningProbe: @Sendable () throws -> Bool
    private let openFileHoldersProbe: @Sendable ([URL]) throws -> [String]
    private let schemaVersion = 1

    init(
        paths: CodexInstancePaths? = nil,
        defaultCodexHome: URL? = nil,
        visibilityRebuilder: (@Sendable (URL) throws -> Void)? = nil,
        globalCodexRunningProbe: (@Sendable () throws -> Bool)? = nil,
        openFileHoldersProbe: (@Sendable ([URL]) throws -> [String])? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.paths = try paths ?? .system(fileManager: fileManager)
        self.defaultCodexHome = (defaultCodexHome
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        self.visibilityRebuilder = visibilityRebuilder
        self.globalCodexRunningProbe = globalCodexRunningProbe ?? {
            NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == CodexApplicationLocator.bundleIdentifier && !$0.isTerminated
            }
        }
        self.openFileHoldersProbe = openFileHoldersProbe ?? { candidates in
            try CodexInstanceEngine.defaultOpenFileHolders(candidates)
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func listInstances() throws -> CodexInstanceRegistrySnapshot {
        let lock = try registryLock()
        defer { lock.release() }
        let document = try loadRegistry()
        return CodexInstanceRegistrySnapshot(
            schemaVersion: document.schemaVersion,
            updatedAt: document.updatedAt,
            instances: [defaultInstance()] + document.instances,
            conflicts: document.conflicts,
            registryPath: paths.registry.path
        )
    }

    func createInstance(_ request: CodexInstanceCreateRequest) throws -> CodexInstanceActionResult {
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        try validate(name: request.name, arguments: request.arguments)
        let workingDirectory = try canonicalOptionalDirectory(request.workingDirectory, label: "工作目录")
        var document = try loadRegistry()
        let id = UUID().uuidString.lowercased()
        let root = paths.managedRoot.appendingPathComponent(id, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let electron = root.appendingPathComponent("electron-data", isDirectory: true)
        do {
            try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: electron, withIntermediateDirectories: true)
            if request.mode == .copyConfiguration {
                let source = request.sourceHome.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : URL(fileURLWithPath: $0, isDirectory: true)
                } ?? defaultCodexHome
                try copyConfiguration(from: source, to: home, copyAuth: request.copyAuth)
            }
            let now = nowMilliseconds()
            let instance = CodexInstance(
                id: id,
                name: request.name.trimmingCharacters(in: .whitespacesAndNewlines),
                codexHome: try canonicalDirectory(home, label: "实例 Codex Home").path,
                electronDataDirectory: try canonicalDirectory(electron, label: "实例桌面数据目录").path,
                workingDirectory: workingDirectory?.path,
                arguments: request.arguments,
                managed: true,
                isDefault: false,
                autoSyncEnabled: request.autoSyncEnabled,
                createdAt: now,
                updatedAt: now,
                controlledProcess: nil
            )
            try ensureUniqueHome(instance.codexHome, in: document, excludingID: nil)
            document.instances.append(instance)
            do {
                try saveRegistry(&document)
            } catch {
                try? fileManager.removeItem(at: root)
                throw error
            }
            return CodexInstanceActionResult(
                instance: instance,
                message: "Codex 实例已创建；它拥有独立的会话目录和桌面数据目录。"
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    func importInstance(_ request: CodexInstanceImportRequest) throws -> CodexInstanceActionResult {
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        try validate(name: request.name, arguments: request.arguments)
        let home = try canonicalDirectory(
            URL(fileURLWithPath: request.codexHome, isDirectory: true),
            label: "Codex Home"
        )
        try ensureDisjointFromManagedRoot(home)
        let workingDirectory = try canonicalOptionalDirectory(request.workingDirectory, label: "工作目录")
        var document = try loadRegistry()
        try ensureUniqueHome(home.path, in: document, excludingID: nil)
        let id = UUID().uuidString.lowercased()
        let root = paths.managedRoot.appendingPathComponent(id, isDirectory: true)
        let electron = root.appendingPathComponent("electron-data", isDirectory: true)
        try fileManager.createDirectory(at: electron, withIntermediateDirectories: true)
        let now = nowMilliseconds()
        let instance = CodexInstance(
            id: id,
            name: request.name.trimmingCharacters(in: .whitespacesAndNewlines),
            codexHome: home.path,
            electronDataDirectory: try canonicalDirectory(electron, label: "实例桌面数据目录").path,
            workingDirectory: workingDirectory?.path,
            arguments: request.arguments,
            managed: false,
            isDefault: false,
            autoSyncEnabled: request.autoSyncEnabled,
            createdAt: now,
            updatedAt: now,
            controlledProcess: nil
        )
        document.instances.append(instance)
        do {
            try saveRegistry(&document)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
        return CodexInstanceActionResult(
            instance: instance,
            message: "已有 Codex Home 已登记；取消登记时不会删除原目录。"
        )
    }

    func updateInstance(_ request: CodexInstanceUpdateRequest) throws -> CodexInstanceActionResult {
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        try ensureNoUnfinishedTransactions(instanceIDs: [request.id])
        try validate(name: request.name, arguments: request.arguments)
        let workingDirectory = try canonicalOptionalDirectory(request.workingDirectory, label: "工作目录")
        var document = try loadRegistry()
        guard let index = document.instances.firstIndex(where: { $0.id == request.id }) else {
            throw codexInstanceError("没有找到要修改的 Codex 实例")
        }
        try ensureStopped(document.instances[index])
        document.instances[index].name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        document.instances[index].workingDirectory = workingDirectory?.path
        document.instances[index].arguments = request.arguments
        document.instances[index].autoSyncEnabled = request.autoSyncEnabled
        document.instances[index].updatedAt = nowMilliseconds()
        let updated = document.instances[index]
        try saveRegistry(&document)
        return CodexInstanceActionResult(instance: updated, message: "实例设置已保存。")
    }

    func deleteInstance(id: String) throws -> CodexInstanceActionResult {
        guard id != "default" else { throw codexInstanceError("默认实例不能删除") }
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        try ensureNoUnfinishedTransactions(instanceIDs: [id])
        var document = try loadRegistry()
        guard let index = document.instances.firstIndex(where: { $0.id == id }) else {
            throw codexInstanceError("没有找到要删除的 Codex 实例")
        }
        let instance = document.instances[index]
        try ensureStopped(instance)
        let root = try validatedOwnedRoot(for: instance)
        let staged = paths.managedRoot.appendingPathComponent(
            ".\(instance.id)-delete-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.moveItem(at: root, to: staged)
        let quarantine: (original: URL, staged: URL)? = (root, staged)
        document.instances.remove(at: index)
        document.conflicts.removeAll { $0.instanceIds.contains(id) }
        do {
            try saveRegistry(&document)
        } catch {
            if let quarantine { try? fileManager.moveItem(at: quarantine.staged, to: quarantine.original) }
            throw error
        }
        let cleanupWarning: String?
        if let quarantine {
            do {
                try fileManager.removeItem(at: quarantine.staged)
                cleanupWarning = nil
            } catch {
                cleanupWarning = "（登记已移除，但清理 Token Bar 所有目录失败：\(error.localizedDescription)）"
            }
        } else {
            cleanupWarning = nil
        }
        return CodexInstanceActionResult(
            instance: nil,
            message: instance.managed
                ? "托管实例及其独立目录已删除。\(cleanupWarning ?? "")"
                : "外部实例已取消登记；原 Codex Home 保持不变。\(cleanupWarning ?? "")"
        )
    }

    func runtimeStatus(id: String) throws -> CodexInstanceRuntimeStatus {
        let lock = try registryLock()
        defer { lock.release() }
        let document = try loadRegistry()
        guard let instance = ([defaultInstance()] + document.instances).first(where: { $0.id == id }) else {
            throw codexInstanceError("没有找到 Codex 实例")
        }
        return try runtimeStatus(for: instance)
    }

    @MainActor
    func launchInstance(id: String) async throws -> CodexInstanceActionResult {
        guard id != "default" else {
            throw codexInstanceError("默认实例由系统入口启动，实例管理器不会重复启动它")
        }
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        try ensureNoUnfinishedTransactions(instanceIDs: [id])
        var document = try loadRegistry()
        if document.instances.first(where: { $0.id == id })?.autoSyncEnabled == true {
            _ = try runAutoSyncIfReady(document: &document)
        }
        guard let index = document.instances.firstIndex(where: { $0.id == id }) else {
            throw codexInstanceError("没有找到 Codex 实例")
        }
        let status = try runtimeStatus(for: document.instances[index])
        if status.running {
            return CodexInstanceActionResult(instance: document.instances[index], message: "实例已在运行。")
        }
        let applicationURL = try codexApplicationURL()
        let executableURL = try codexApplicationExecutableURL(applicationURL)
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: document.instances[index].electronDataDirectory, isDirectory: true),
            withIntermediateDirectories: true
        )
        let marker = "--user-data-dir=\(document.instances[index].electronDataDirectory)"
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [marker] + document.instances[index].arguments
        var environment = [
            "CODEX_HOME": document.instances[index].codexHome,
            "CODEX_ELECTRON_USER_DATA_PATH": document.instances[index].electronDataDirectory
        ]
        if let working = document.instances[index].workingDirectory {
            environment["PWD"] = working
            environment["CODEX_WORKING_DIRECTORY"] = working
        }
        configuration.environment = environment
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        let application = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSRunningApplication, Error>) in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: error ?? codexInstanceError("Codex 实例启动失败"))
                }
            }
        }
        let pid = UInt32(application.processIdentifier)
        let identity: String
        do {
            identity = try waitForVerifiedLaunch(
                application: application,
                pid: pid,
                expectedExecutable: executableURL,
                marker: marker
            )
        } catch {
            let cleanupError = terminateJustLaunchedApplication(application)
            if let cleanupError {
                throw codexInstanceError(
                    "启动后的进程身份无法核对：\(error.localizedDescription)；终止未登记实例也失败：\(cleanupError.localizedDescription)"
                )
            }
            throw codexInstanceError(
                "启动后的进程身份无法核对，已终止未登记实例：\(error.localizedDescription)"
            )
        }
        let now = nowMilliseconds()
        document.instances[index].controlledProcess = CodexControlledProcess(
            pid: pid,
            executablePath: executableURL.resolvingSymlinksInPath().path,
            userDataMarker: marker,
            startedAt: now,
            processStartIdentity: identity
        )
        document.instances[index].updatedAt = now
        let launched = document.instances[index]
        do {
            try saveRegistry(&document)
        } catch {
            let cleanupError = terminateJustLaunchedApplication(application)
            if let cleanupError {
                throw codexInstanceError(
                    "Codex 实例已启动，但控制信息未能保存：\(error.localizedDescription)；终止未登记实例也失败：\(cleanupError.localizedDescription)"
                )
            }
            throw codexInstanceError(
                "Codex 实例已启动，但控制信息未能保存；已终止未登记实例：\(error.localizedDescription)"
            )
        }
        return CodexInstanceActionResult(instance: launched, message: "Codex 实例已用独立环境启动。")
    }

    @MainActor
    func focusInstance(id: String) throws -> CodexInstanceActionResult {
        let lock = try registryLock()
        defer { lock.release() }
        let document = try loadRegistry()
        guard let instance = document.instances.first(where: { $0.id == id }),
              let process = try verifiedControlledProcess(instance),
              let application = NSRunningApplication(processIdentifier: pid_t(process.pid))
        else {
            throw codexInstanceError("该实例没有由 Token Bar 启动的可验证进程")
        }
        guard application.activate(options: []) else {
            throw codexInstanceError("切换到该 Codex 实例失败")
        }
        return CodexInstanceActionResult(instance: instance, message: "已切换到该 Codex 实例。")
    }

    @MainActor
    func stopInstance(id: String) throws -> CodexInstanceActionResult {
        guard id != "default" else {
            throw codexInstanceError("实例管理器不会停止默认 Codex，避免中断当前任务")
        }
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        var document = try loadRegistry()
        guard let index = document.instances.firstIndex(where: { $0.id == id }),
              let process = try verifiedControlledProcess(document.instances[index]),
              let application = NSRunningApplication(processIdentifier: pid_t(process.pid))
        else {
            throw codexInstanceError("没有找到由 Token Bar 启动且身份匹配的实例进程")
        }
        guard application.terminate() else { throw codexInstanceError("Codex 实例拒绝退出") }
        try waitForProcessExit(pid: process.pid, identity: process.processStartIdentity)
        document.instances[index].controlledProcess = nil
        document.instances[index].updatedAt = nowMilliseconds()
        let stopped = document.instances[index]
        try saveRegistry(&document)
        let automaticMessage: String?
        if stopped.autoSyncEnabled {
            do {
                automaticMessage = try runAutoSyncIfReady(document: &document)?.message
            } catch {
                automaticMessage = "自动同步已暂停：\(error.localizedDescription)"
            }
        } else {
            automaticMessage = nil
        }
        return CodexInstanceActionResult(
            instance: stopped,
            message: automaticMessage.map { "实例已退出。\($0)" } ?? "实例已退出。"
        )
    }

    private func defaultInstance() -> CodexInstance {
        let now = nowMilliseconds()
        return CodexInstance(
            id: "default",
            name: "默认 Codex",
            codexHome: defaultCodexHome.path,
            electronDataDirectory: "",
            workingDirectory: nil,
            arguments: [],
            managed: false,
            isDefault: true,
            autoSyncEnabled: false,
            createdAt: now,
            updatedAt: now,
            controlledProcess: nil
        )
    }

    private func loadRegistry() throws -> CodexInstanceRegistryDocument {
        guard fileManager.fileExists(atPath: paths.registry.path) else {
            return CodexInstanceRegistryDocument(
                schemaVersion: schemaVersion,
                updatedAt: nowMilliseconds(),
                instances: [],
                conflicts: []
            )
        }
        let data = try Data(contentsOf: paths.registry, options: [.mappedIfSafe])
        let document: CodexInstanceRegistryDocument
        do {
            document = try decoder.decode(CodexInstanceRegistryDocument.self, from: data)
        } catch {
            let isolated = paths.registry.deletingPathExtension()
                .appendingPathExtension("corrupt-\(nowMilliseconds())")
            do {
                try fileManager.moveItem(at: paths.registry, to: isolated)
            } catch let moveError {
                throw codexInstanceError("实例注册表损坏且无法隔离：\(error.localizedDescription)；\(moveError.localizedDescription)")
            }
            throw codexInstanceError("实例注册表格式损坏，已原样隔离到 \(isolated.path)；没有静默重建空列表")
        }
        guard document.schemaVersion == schemaVersion else {
            throw codexInstanceError("不支持的实例注册表版本 \(document.schemaVersion)")
        }
        try validate(document)
        return document
    }

    private func saveRegistry(_ document: inout CodexInstanceRegistryDocument) throws {
        document.schemaVersion = schemaVersion
        document.updatedAt = nowMilliseconds()
        try validate(document)
        try atomicWrite(try encoder.encode(document), to: paths.registry)
    }

    private func validate(_ document: CodexInstanceRegistryDocument) throws {
        var ids = Set<String>()
        var homes: [URL] = []
        for instance in document.instances {
            guard instance.id != "default", !instance.isDefault, UUID(uuidString: instance.id) != nil else {
                throw codexInstanceError("持久化实例注册表包含无效实例编号")
            }
            guard ids.insert(instance.id).inserted else {
                throw codexInstanceError("实例编号重复：\(instance.id)")
            }
            let home = URL(fileURLWithPath: instance.codexHome, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard !homes.contains(where: { pathsOverlap($0, home) }) else {
                throw codexInstanceError(
                    "多个实例的 Codex Home 相同或相互嵌套：\(instance.codexHome)"
                )
            }
            homes.append(home)
            try validate(name: instance.name, arguments: instance.arguments)
        }
    }

    private func validate(name: String, arguments: [String]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw codexInstanceError("实例名称不能为空")
        }
        guard !name.contains("\0"), !arguments.contains(where: { $0.contains("\0") }) else {
            throw codexInstanceError("实例名称或启动参数包含无效字符")
        }
        guard !arguments.contains(where: { $0.hasPrefix("--user-data-dir") }) else {
            throw codexInstanceError("无需手动设置 --user-data-dir；Token Bar 会生成独立目录")
        }
    }

    private func ensureUniqueHome(
        _ path: String,
        in document: CodexInstanceRegistryDocument,
        excludingID: String?
    ) throws {
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
        if pathsOverlap(candidate, defaultCodexHome) {
            throw codexInstanceError(
                "该 Codex Home 与只读默认实例相同或相互嵌套，无法登记"
            )
        }
        guard !document.instances.contains(where: {
            $0.id != excludingID
                && pathsOverlap(
                    URL(fileURLWithPath: $0.codexHome, isDirectory: true),
                    candidate
                )
        }) else {
            throw codexInstanceError("该 Codex Home 与另一个实例相同或相互嵌套")
        }
    }

    private func ensureDisjointFromManagedRoot(_ home: URL) throws {
        if pathsOverlap(paths.managedRoot, home) {
            throw codexInstanceError(
                "外部 Codex Home 不能位于 Token Bar 实例目录内，也不能包含该目录"
            )
        }
    }

    private func pathsOverlap(_ left: URL, _ right: URL) -> Bool {
        let left = comparablePath(left)
        let right = comparablePath(right)
        return pathContains(left, right) || pathContains(right, left)
    }

    private func pathContains(_ parent: String, _ candidate: String) -> Bool {
        parent == candidate || candidate.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private func validatedOwnedRoot(for instance: CodexInstance) throws -> URL {
        guard UUID(uuidString: instance.id) != nil else {
            throw codexInstanceError("实例编号无效，拒绝删除目录")
        }
        let managed = try canonicalDirectory(paths.managedRoot, label: "托管实例根目录")
        let root = try canonicalDirectory(
            paths.managedRoot.appendingPathComponent(instance.id, isDirectory: true),
            label: "托管实例目录"
        )
        guard root.deletingLastPathComponent() == managed else {
            throw codexInstanceError("托管实例目录不在受控根目录的直接子级，拒绝删除")
        }
        let expectedElectron = try canonicalDirectory(
            root.appendingPathComponent("electron-data", isDirectory: true),
            label: "实例桌面数据目录"
        )
        let actualElectron = try canonicalDirectory(
            URL(fileURLWithPath: instance.electronDataDirectory, isDirectory: true),
            label: "注册表桌面数据目录"
        )
        guard expectedElectron == actualElectron else {
            throw codexInstanceError("注册表桌面数据路径与 Token Bar 所有目录不一致，拒绝删除")
        }
        if instance.managed {
            let expected = try canonicalDirectory(
                root.appendingPathComponent("home", isDirectory: true),
                label: "托管 Codex Home"
            )
            let actual = try canonicalDirectory(
                URL(fileURLWithPath: instance.codexHome, isDirectory: true),
                label: "实例 Codex Home"
            )
            guard expected == actual else {
                throw codexInstanceError("注册表路径与托管目录不一致，拒绝删除")
            }
        }
        return root
    }

    private func canonicalOptionalDirectory(_ value: String?, label: String) throws -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try canonicalDirectory(URL(fileURLWithPath: value, isDirectory: true), label: label)
    }

    private func canonicalDirectory(_ url: URL, label: String) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw codexInstanceError("\(label)不存在或不是目录：\(resolved.path)")
        }
        return resolved
    }

    private func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func copyConfiguration(from source: URL, to destination: URL, copyAuth: Bool) throws {
        let source = try canonicalDirectory(source, label: "源 Codex Home")
        for name in ["config.toml", "AGENTS.md"] {
            let file = source.appendingPathComponent(name)
            if fileManager.fileExists(atPath: file.path) {
                try copyRegularFile(from: file, to: destination.appendingPathComponent(name))
            }
        }
        if copyAuth {
            let auth = source.appendingPathComponent("auth.json")
            if fileManager.fileExists(atPath: auth.path) {
                try copyRegularFile(from: auth, to: destination.appendingPathComponent("auth.json"))
            }
        }
        for name in ["rules", "skills"] {
            let directory = source.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: directory.path) {
                try copyDirectoryWithoutLinks(from: directory, to: destination.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    private func copyDirectoryWithoutLinks(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw codexInstanceError("拒绝复制非普通配置目录：\(source.path)")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw codexInstanceError("配置目录包含符号链接，已拒绝复制：\(item.path)")
            }
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try copyDirectoryWithoutLinks(from: item, to: target)
            } else if values.isRegularFile == true {
                try copyRegularFile(from: item, to: target)
            } else {
                throw codexInstanceError("配置目录包含特殊文件，已拒绝复制：\(item.path)")
            }
        }
    }

    private func copyRegularFile(from source: URL, to destination: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw codexInstanceError("拒绝复制非普通配置文件：\(source.path)")
        }
        let expected = try hashFile(source)
        try copyAtomicallyVerified(from: source, to: destination, expectedHash: expected)
    }

    private func runtimeStatus(for instance: CodexInstance) throws -> CodexInstanceRuntimeStatus {
        if instance.isDefault {
            let running = try globalCodexRunningProbe()
            return CodexInstanceRuntimeStatus(
                id: instance.id,
                running: running,
                controlled: false,
                pid: nil,
                message: running ? "默认 Codex 正在运行；实例同步将保持锁定。" : "默认 Codex 未运行。"
            )
        }
        if let process = try verifiedControlledProcess(instance) {
            return CodexInstanceRuntimeStatus(
                id: instance.id,
                running: true,
                controlled: true,
                pid: process.pid,
                message: "由 Token Bar 启动，进程身份与独立数据目录均已核对。"
            )
        }
        if let pid = try processUsingMarker("--user-data-dir=\(instance.electronDataDirectory)") {
            return CodexInstanceRuntimeStatus(
                id: instance.id,
                running: true,
                controlled: false,
                pid: pid,
                message: "发现使用该实例数据目录的进程，但它不是本次受控启动，不能由 Token Bar 停止。"
            )
        }
        if !instance.managed {
            let hasUnattributedCodex = try globalCodexRunningProbe()
            if hasUnattributedCodex {
                return CodexInstanceRuntimeStatus(
                    id: instance.id,
                    running: true,
                    controlled: false,
                    pid: nil,
                    message: "存在无法归属的 Codex 进程；外部实例按运行中处理，避免误同步。"
                )
            }
        }
        return CodexInstanceRuntimeStatus(
            id: instance.id,
            running: false,
            controlled: false,
            pid: nil,
            message: "实例未运行。"
        )
    }

    private func verifiedControlledProcess(_ instance: CodexInstance) throws -> CodexControlledProcess? {
        guard let process = instance.controlledProcess else { return nil }
        guard let identity = try? processIdentity(pid: process.pid),
              identity == process.processStartIdentity,
              let application = NSRunningApplication(processIdentifier: pid_t(process.pid)),
              application.bundleIdentifier == CodexApplicationLocator.bundleIdentifier,
              let executable = application.executableURL?.resolvingSymlinksInPath().path,
              executable == URL(fileURLWithPath: process.executablePath).resolvingSymlinksInPath().path,
              try processCommand(pid: process.pid).contains(process.userDataMarker)
        else {
            return nil
        }
        return process
    }

    private func ensureStopped(_ instance: CodexInstance) throws {
        let status = try runtimeStatus(for: instance)
        guard !status.running else {
            throw codexInstanceError("\(instance.name) 正在运行；停止后才能修改、删除或同步")
        }
    }

    private func codexApplicationURL() throws -> URL {
        guard let application = CodexApplicationLocator.registeredApplications()
            .first(where: { $0.bundleIdentifier == CodexApplicationLocator.bundleIdentifier })?.url else {
            throw codexInstanceError("没有找到 Codex 桌面应用")
        }
        return application
    }

    private func codexApplicationExecutableURL(_ application: URL) throws -> URL {
        guard let executable = Bundle(url: application)?.executableURL else {
            throw codexInstanceError("Codex 应用缺少可执行文件")
        }
        return executable
    }

    private func processIdentity(pid: UInt32) throws -> String {
        try processOutput(arguments: ["-p", String(pid), "-o", "lstart="])
    }

    private func processCommand(pid: UInt32) throws -> String {
        try processOutput(arguments: ["-p", String(pid), "-o", "command="])
    }

    private func processOutput(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let value = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !value.isEmpty else {
            throw codexInstanceError("进程已结束或无法读取")
        }
        return value
    }

    @MainActor
    private func terminateJustLaunchedApplication(
        _ application: NSRunningApplication
    ) -> Error? {
        guard !application.isTerminated else { return nil }
        if !application.terminate() {
            guard application.forceTerminate() else {
                return codexInstanceError("Codex 实例拒绝退出")
            }
        }
        for _ in 0..<50 {
            if application.isTerminated { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if application.forceTerminate() {
            for _ in 0..<20 {
                if application.isTerminated { return nil }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return codexInstanceError("等待未登记 Codex 实例退出超时")
    }

    private func processUsingMarker(_ marker: String) throws -> UInt32? {
        let output = try processOutput(arguments: ["-axo", "pid=,command="])
        for line in output.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            if parts.count == 2,
               codexProcessCommandContainsArgument(String(parts[1]), marker),
               let pid = UInt32(parts[0]) {
                return pid
            }
        }
        return nil
    }

    private func waitForVerifiedLaunch(
        application: NSRunningApplication,
        pid: UInt32,
        expectedExecutable: URL,
        marker: String
    ) throws -> String {
        var lastError: Error?
        let expectedPath = expectedExecutable.resolvingSymlinksInPath().path
        for _ in 0..<40 {
            do {
                guard application.bundleIdentifier == CodexApplicationLocator.bundleIdentifier else {
                    throw codexInstanceError("启动结果不是已登记的 Codex 应用")
                }
                guard let executable = application.executableURL?
                    .resolvingSymlinksInPath().path,
                    executable == expectedPath
                else {
                    throw codexInstanceError("启动结果的可执行文件与 Codex 应用不一致")
                }
                let identity = try processIdentity(pid: pid)
                guard codexProcessCommandContainsArgument(
                    try processCommand(pid: pid),
                    marker
                ) else {
                    throw codexInstanceError("启动结果缺少独立数据目录标记")
                }
                return identity
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw lastError ?? codexInstanceError("Codex 进程启动后无法核对身份")
    }

    private func waitForProcessExit(pid: UInt32, identity: String) throws {
        for _ in 0..<100 {
            guard let current = try? processIdentity(pid: pid), current == identity else { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw codexInstanceError("等待 Codex 实例退出超时；注册表未清除控制信息")
    }

    private func registryLock() throws -> CodexInstanceFileLock {
        try CodexInstanceFileLock(
            url: paths.registry.deletingPathExtension().appendingPathExtension("lock"),
            label: "实例注册表",
            fileManager: fileManager
        )
    }

    private func syncLock() throws -> CodexInstanceFileLock {
        try CodexInstanceFileLock(
            url: paths.syncRoot.appendingPathComponent("instance-sync.lock"),
            label: "实例同步",
            fileManager: fileManager
        )
    }

    fileprivate func atomicWrite(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).codex-token-bar-\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw codexInstanceError("创建原子写临时文件失败：\(String(cString: strerror(errno)))")
        }
        var descriptorOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else {
                        throw codexInstanceError("写入原子临时文件失败：\(String(cString: strerror(errno)))")
                    }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else {
                throw codexInstanceError("同步原子临时文件失败：\(String(cString: strerror(errno)))")
            }
            close(descriptor)
            descriptorOpen = false
            guard rename(temporary.path, destination.path) == 0 else {
                throw codexInstanceError("替换目标文件失败：\(String(cString: strerror(errno)))")
            }
            do {
                try syncDirectory(destination.deletingLastPathComponent())
            } catch {
                NSLog(
                    "Codex Token Bar: %@ 已提交，但父目录持久化确认失败；保留已提交状态：%@",
                    destination.path,
                    error.localizedDescription
                )
            }
        } catch {
            if descriptorOpen { close(descriptor) }
            unlink(temporary.path)
            throw error
        }
    }

    fileprivate func copyAtomicallyVerified(
        from source: URL,
        to destination: URL,
        expectedHash: String
    ) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).codex-token-bar-\(UUID().uuidString.lowercased()).tmp"
        )
        let sourceHandle = try FileHandle(forReadingFrom: source)
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw codexInstanceError("创建复制临时文件失败：\(temporary.path)")
        }
        let destinationHandle = try FileHandle(forWritingTo: temporary)
        var hasher = SHA256()
        do {
            while let chunk = try sourceHandle.read(upToCount: 128 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
                try destinationHandle.write(contentsOf: chunk)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expectedHash else {
                throw codexInstanceError("源文件在复制期间发生变化，已取消提交")
            }
            try destinationHandle.synchronize()
            try sourceHandle.close()
            try destinationHandle.close()
            guard rename(temporary.path, destination.path) == 0 else {
                throw codexInstanceError("替换复制目标失败：\(String(cString: strerror(errno)))")
            }
            do {
                try syncDirectory(destination.deletingLastPathComponent())
            } catch {
                NSLog(
                    "Codex Token Bar: %@ 已提交，但父目录持久化确认失败；保留已提交状态：%@",
                    destination.path,
                    error.localizedDescription
                )
            }
        } catch {
            try? sourceHandle.close()
            try? destinationHandle.close()
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    fileprivate func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    fileprivate func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw codexInstanceError("打开目录进行同步失败：\(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw codexInstanceError("同步目录失败：\(String(cString: strerror(errno)))")
        }
    }

    fileprivate func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    func previewSync(instanceIDs: [String]) throws -> CodexInstanceSyncPreview {
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        try ensureNoUnfinishedTransactions(instanceIDs: instanceIDs)
        let document = try loadRegistry()
        let instances = try selectInstances(
            from: [defaultInstance()] + document.instances,
            ids: instanceIDs
        )
        try ensureAllStopped(instances)
        return try buildSyncPreview(instances)
    }

    func syncInstances(instanceIDs: [String]) throws -> CodexInstanceSyncResult {
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        try ensureNoUnfinishedTransactions(instanceIDs: instanceIDs)
        var document = try loadRegistry()
        let instances = try selectInstances(
            from: [defaultInstance()] + document.instances,
            ids: instanceIDs
        )
        try ensureAllStopped(instances)
        return try syncLocked(instances: instances, document: &document)
    }

    func listSyncTransactions() throws -> [CodexInstanceSyncTransactionSummary] {
        let root = paths.syncRoot.appendingPathComponent("transactions", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> CodexInstanceSyncTransactionSummary? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            guard fileManager.fileExists(
                atPath: url.appendingPathComponent("manifest.json").path
            ) else { return nil }
            let transaction = try readTransaction(root: url)
            return CodexInstanceSyncTransactionSummary(
                transactionId: transaction.transactionId,
                createdAt: transaction.createdAt,
                state: transaction.state,
                instanceIds: transaction.instanceIds,
                operations: transaction.operations.count,
                conflicts: transaction.conflicts.count
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func rollbackSync(transactionID: String) throws -> CodexInstanceSyncResult {
        guard UUID(uuidString: transactionID) != nil else {
            throw codexInstanceError("实例同步事务编号无效")
        }
        let syncLock = try self.syncLock()
        defer { syncLock.release() }
        let registryLock = try self.registryLock()
        defer { registryLock.release() }
        let root = transactionRoot(id: transactionID)
        var transaction = try readTransaction(root: root)
        guard ["committed", "prepared", "failedNeedsRecovery"].contains(transaction.state) else {
            throw codexInstanceError("事务状态 \(transaction.state) 不能回滚")
        }
        try ensureLatestRecoverableTransaction(transaction)
        let document = try loadRegistry()
        let instances = try selectInstances(
            from: [defaultInstance()] + document.instances,
            ids: transaction.instanceIds
        )
        try ensureAllStopped(instances)
        try rollbackFiles(transaction: &transaction, instances: instances)
        transaction.state = "rolledBack"
        try writeTransaction(transaction, root: root)
        let visibilityWarnings = rebuildVisibilityForStoppedInstances(instances)
        let visibilitySuffix = visibilityWarnings.isEmpty
            ? "并已重建官方会话索引。"
            : "但官方会话索引未全部重建：\(visibilityWarnings.joined(separator: "；"))"
        return CodexInstanceSyncResult(
            transactionId: transaction.transactionId,
            operationsApplied: transaction.operations.count,
            conflicts: transaction.conflicts,
            message: "实例同步事务已回滚；只恢复了仍与本事务写入值一致的文件，\(visibilitySuffix)"
        )
    }

    private struct RolloutFile {
        var instanceID: String
        var threadID: String
        var url: URL
        var relativePath: String
        var length: UInt64
        var hash: String
    }

    private func runAutoSyncIfReady(
        document: inout CodexInstanceRegistryDocument
    ) throws -> CodexInstanceSyncResult? {
        let ids = codexAutomaticSyncInstanceIDs(document.instances)
        guard ids.count >= 2 else { return nil }
        try ensureNoUnfinishedTransactions(instanceIDs: ids)
        let instances = try selectInstances(
            from: [defaultInstance()] + document.instances,
            ids: ids
        )
        guard try instances.allSatisfy({ try !runtimeStatus(for: $0).running }) else {
            return nil
        }
        return try syncLocked(instances: instances, document: &document)
    }

    private func syncLocked(
        instances: [CodexInstance],
        document: inout CodexInstanceRegistryDocument
    ) throws -> CodexInstanceSyncResult {
        let preview = try buildSyncPreview(instances)
        guard !preview.operations.isEmpty || !preview.conflicts.isEmpty else {
            return CodexInstanceSyncResult(
                transactionId: nil,
                operationsApplied: 0,
                conflicts: [],
                message: "所选实例的会话历史已经一致。"
            )
        }
        try ensureCandidateFilesNotOpenElsewhere(preview.operations)
        let transactionID = UUID().uuidString.lowercased()
        let root = transactionRoot(id: transactionID)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var transaction = CodexInstanceSyncTransaction(
            schemaVersion: schemaVersion,
            transactionId: transactionID,
            createdAt: nowMilliseconds(),
            state: "prepared",
            instanceIds: preview.instanceIds,
            operations: preview.operations.enumerated().map { index, operation in
                var operation = operation
                if operation.destinationHash != nil {
                    operation.backupPath = root
                        .appendingPathComponent("backups/\(String(format: "%08d", index)).jsonl")
                        .path
                }
                return operation
            },
            conflicts: preview.conflicts
        )
        try writeTransaction(transaction, root: root)
        do {
            try applyTransaction(&transaction, root: root, instances: instances)
        } catch let applyError {
            var rollbackError: Error?
            do {
                try rollbackFiles(transaction: &transaction, instances: instances)
            } catch {
                rollbackError = error
            }
            transaction.state = rollbackError == nil
                ? "rolledBackAfterFailure"
                : "failedNeedsRecovery"
            var message = rollbackError.map {
                "\(applyError.localizedDescription)；自动回滚也失败：\($0.localizedDescription)"
            } ?? "\(applyError.localizedDescription)；已自动回滚本次实例同步"
            do {
                try writeTransaction(transaction, root: root)
            } catch {
                message += "；事务状态未能持久化（回滚已幂等，可重试收敛）：\(error.localizedDescription)"
            }
            throw codexInstanceError(message)
        }
        transaction.state = "committed"
        try writeTransaction(transaction, root: root)
        mergeConflicts(into: &document.conflicts, incoming: transaction.conflicts)
        var warnings: [String] = []
        do {
            try saveRegistry(&document)
        } catch {
            warnings.append(
                "分歧摘要注册表未能保存，但会话事务已经提交：\(error.localizedDescription)"
            )
        }

        warnings.append(contentsOf: rebuildVisibilityForStoppedInstances(instances))
        let message: String
        if warnings.isEmpty {
            message = "实例同步完成：写入 \(transaction.operations.count) 项，保留 \(transaction.conflicts.count) 个分歧，并已重建官方会话索引。"
        } else {
            message = "实例同步完成：写入 \(transaction.operations.count) 项，保留 \(transaction.conflicts.count) 个分歧；后处理未全部完成：\(warnings.joined(separator: "；"))"
        }
        return CodexInstanceSyncResult(
            transactionId: transactionID,
            operationsApplied: transaction.operations.count,
            conflicts: transaction.conflicts,
            message: message
        )
    }

    private func rebuildVisibilityForStoppedInstances(
        _ instances: [CodexInstance]
    ) -> [String] {
        var warnings: [String] = []
        for instance in instances {
            do {
                let home = URL(fileURLWithPath: instance.codexHome, isDirectory: true)
                if let visibilityRebuilder {
                    try visibilityRebuilder(home)
                } else {
                    let source = CodexDataSource(codexHome: home, origin: .userSelected)
                    let codexPath = try CodexBinaryLocator.findExecutable()
                    _ = try CodexAppServerClient().rebuildConversationVisibilityMetadata(
                        codexPath: codexPath,
                        dataSource: source,
                        beforePage: { try self.ensureAllStopped(instances) }
                    )
                }
            } catch {
                warnings.append("\(instance.name)：\(error.localizedDescription)")
            }
        }
        return warnings
    }

    private func selectInstances(
        from all: [CodexInstance],
        ids: [String]
    ) throws -> [CodexInstance] {
        let unique = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard unique.count >= 2 else {
            throw codexInstanceError("实例同步至少需要选择两个不同实例")
        }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return try unique.map { id in
            guard let instance = byID[id] else {
                throw codexInstanceError("没有找到 Codex 实例 \(id)")
            }
            return instance
        }
    }

    // 运行检测（受控进程 / marker / 桌面 App）覆盖不到 codex CLI 这类无 marker 的
    // 进程；若同步 rename 时 CLI 仍持旧 inode 追加，事件会静默丢失。改写前对全部
    // 候选文件检查打开句柄，检测到或无法检测都 fail closed。
    private func ensureCandidateFilesNotOpenElsewhere(
        _ operations: [CodexInstanceSyncOperation]
    ) throws {
        var seen = Set<String>()
        var candidates: [URL] = []
        for operation in operations {
            var paths = [operation.sourcePath]
            if operation.destinationHash != nil {
                paths.append(operation.destinationPath)
            }
            for path in paths where seen.insert(path).inserted {
                candidates.append(URL(fileURLWithPath: path))
            }
        }
        let held = try openFileHoldersProbe(candidates)
        guard !held.isEmpty else { return }
        let shown = held.prefix(3).joined(separator: "；")
        let suffix = held.count > 3 ? "；等共 \(held.count) 个文件" : ""
        throw codexInstanceError(
            "实例同步已取消：检测到其他进程正打开候选会话文件（codex CLI 等非桌面进程不在运行检测范围内，请先退出后重试）：\(shown)\(suffix)"
        )
    }

    private static func defaultOpenFileHolders(_ candidates: [URL]) throws -> [String] {
        var held: [String] = []
        for url in candidates {
            let pids = try processesHoldingFileOpen(atPath: url.path)
            if !pids.isEmpty {
                let list = pids.map(String.init).joined(separator: "、")
                held.append("\(url.path)（进程 \(list)）")
            }
        }
        return held
    }

    static func processesHoldingFileOpen(atPath path: String) throws -> [Int32] {
        let allPids: UInt32 = 1 // PROC_ALL_PIDS
        // 排除 O_EVTONLY 打开（FSEvents/kqueue 监视器），只留真正的读写句柄。
        let excludeEventOnly: UInt32 = 2 // PROC_LISTPIDSPATH_EXCLUDE_EVTONLY
        var capacity = 1024
        while true {
            var buffer = [Int32](repeating: 0, count: capacity)
            let bytes = buffer.withUnsafeMutableBytes { raw in
                path.withCString { cPath in
                    proc_listpidspath(
                        allPids,
                        0,
                        cPath,
                        excludeEventOnly,
                        raw.baseAddress,
                        Int32(raw.count)
                    )
                }
            }
            if bytes < 0 {
                if errno == ENOENT { return [] }
                throw codexInstanceError(
                    "检查文件打开句柄失败：\(path)：\(String(cString: strerror(errno)))"
                )
            }
            let count = Int(bytes) / MemoryLayout<Int32>.size
            if count == capacity {
                capacity *= 2
                continue
            }
            let own = getpid()
            return buffer.prefix(count).filter { $0 > 0 && $0 != own }
        }
    }

    private func ensureAllStopped(_ instances: [CodexInstance]) throws {
        for instance in instances { try ensureStopped(instance) }
    }

    private func buildSyncPreview(
        _ instances: [CodexInstance]
    ) throws -> CodexInstanceSyncPreview {
        var byThread: [String: [String: [RolloutFile]]] = [:]
        for instance in instances {
            for rollout in try collectRollouts(instance) {
                byThread[rollout.threadID, default: [:]][rollout.instanceID, default: []]
                    .append(rollout)
            }
        }
        var operations: [CodexInstanceSyncOperation] = []
        var conflicts: [CodexInstanceConflict] = []
        var unchanged = 0
        for threadID in byThread.keys.sorted() {
            guard let versionsByInstance = byThread[threadID] else { continue }
            if versionsByInstance.values.contains(where: { $0.count != 1 }) {
                conflicts.append(conflict(
                    threadID: threadID,
                    versions: versionsByInstance.values.flatMap { $0 },
                    reason: "同一实例内存在多个同编号会话文件，未自动选择"
                ))
                continue
            }
            let versions = versionsByInstance.values.compactMap(\.first)
            let archiveStates = Set(versions.compactMap { rolloutIsArchived($0.relativePath) })
            if archiveStates.count != 1 {
                conflicts.append(conflict(
                    threadID: threadID,
                    versions: versions,
                    reason: "同一会话在不同实例的活动/归档状态不一致，未自动移动"
                ))
                continue
            }
            guard var candidate = versions.first else { continue }
            var divergent = false
            for version in versions.dropFirst() {
                if version.hash == candidate.hash { continue }
                if candidate.length <= version.length,
                   try isPrefix(candidate.url, of: version.url) {
                    candidate = version
                } else if version.length <= candidate.length,
                          try isPrefix(version.url, of: candidate.url) {
                    continue
                } else {
                    divergent = true
                    break
                }
            }
            if divergent {
                conflicts.append(conflict(
                    threadID: threadID,
                    versions: versions,
                    reason: "同一会话存在相互分叉的事件流；已保留各版本，不做逐行拼接"
                ))
                continue
            }
            var threadOperations = 0
            for instance in instances {
                let existing = versionsByInstance[instance.id]?.first
                if let existing, existing.hash == candidate.hash { continue }
                if let existing {
                    guard existing.length < candidate.length,
                          try isPrefix(existing.url, of: candidate.url)
                    else {
                        conflicts.append(conflict(
                            threadID: threadID,
                            versions: versions,
                            reason: "会话版本无法证明为严格前缀，未自动覆盖"
                        ))
                        continue
                    }
                    operations.append(CodexInstanceSyncOperation(
                        threadId: threadID,
                        sourceInstanceId: candidate.instanceID,
                        destinationInstanceId: instance.id,
                        sourcePath: candidate.url.path,
                        destinationPath: existing.url.path,
                        kind: "fastForward",
                        sourceHash: candidate.hash,
                        destinationHash: existing.hash,
                        backupPath: nil,
                        installedHash: nil
                    ))
                } else {
                    let destination = URL(fileURLWithPath: instance.codexHome, isDirectory: true)
                        .appendingPathComponent(candidate.relativePath)
                    operations.append(CodexInstanceSyncOperation(
                        threadId: threadID,
                        sourceInstanceId: candidate.instanceID,
                        destinationInstanceId: instance.id,
                        sourcePath: candidate.url.path,
                        destinationPath: destination.path,
                        kind: "missing",
                        sourceHash: candidate.hash,
                        destinationHash: nil,
                        backupPath: nil,
                        installedHash: nil
                    ))
                }
                threadOperations += 1
            }
            if threadOperations == 0 { unchanged += 1 }
        }
        return CodexInstanceSyncPreview(
            instanceIds: instances.map(\.id),
            operations: operations,
            conflicts: conflicts,
            unchangedThreads: unchanged
        )
    }

    private func rolloutIsArchived(_ relativePath: String) -> Bool? {
        switch relativePath.split(separator: "/", maxSplits: 1).first {
        case "sessions":
            false
        case "archived_sessions":
            true
        default:
            nil
        }
    }

    private func collectRollouts(_ instance: CodexInstance) throws -> [RolloutFile] {
        let home = try canonicalDirectory(
            URL(fileURLWithPath: instance.codexHome, isDirectory: true),
            label: "实例 Codex Home"
        )
        var result: [RolloutFile] = []
        for name in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let rootValues = try root.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey
            ])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                throw codexInstanceError(
                    "会话根目录不是 Codex Home 内的真实目录：\(root.path)"
                )
            }
            let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
            let homePrefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
            guard resolvedRoot.path.hasPrefix(homePrefix) else {
                throw codexInstanceError("会话根目录越过 Codex Home：\(resolvedRoot.path)")
            }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
                    ],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }
                  )
            else {
                throw codexInstanceError("无法枚举会话根目录：\(root.path)")
            }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
                ])
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values.isRegularFile == true, file.pathExtension == "jsonl",
                      let threadID = try canonicalThreadID(file)
                else { continue }
                let resolvedFile = file.standardizedFileURL.resolvingSymlinksInPath()
                guard resolvedFile.path.hasPrefix(homePrefix) else {
                    throw codexInstanceError("会话路径越过 Codex Home：\(resolvedFile.path)")
                }
                let relative = String(resolvedFile.path.dropFirst(homePrefix.count))
                result.append(RolloutFile(
                    instanceID: instance.id,
                    threadID: threadID,
                    url: resolvedFile,
                    relativePath: relative,
                    length: UInt64(values.fileSize ?? 0),
                    hash: try hashFile(file)
                ))
            }
            if let enumerationError {
                throw codexInstanceError(
                    "枚举会话根目录失败 \(root.path)：\(enumerationError.localizedDescription)"
                )
            }
        }
        return result
    }

    private func canonicalThreadID(_ file: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024,
              let newline = data.firstIndex(of: 0x0A)
        else {
            throw codexInstanceError("会话首行过大或不完整：\(file.path)")
        }
        let firstLine = data[..<newline]
        guard let json = try JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any]
        else { return nil }
        return (payload["id"] as? String) ?? (payload["thread_id"] as? String)
    }

    private func conflict(
        threadID: String,
        versions: [RolloutFile],
        reason: String
    ) -> CodexInstanceConflict {
        CodexInstanceConflict(
            id: UUID().uuidString.lowercased(),
            threadId: threadID,
            instanceIds: versions.map(\.instanceID),
            relativePaths: versions.map(\.relativePath),
            hashes: versions.map(\.hash),
            detectedAt: nowMilliseconds(),
            reason: reason,
            resolved: false
        )
    }

    private func isPrefix(_ shorter: URL, of longer: URL) throws -> Bool {
        let shortAttributes = try fileManager.attributesOfItem(atPath: shorter.path)
        let longAttributes = try fileManager.attributesOfItem(atPath: longer.path)
        let shortLength = (shortAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        let longLength = (longAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard shortLength <= longLength else { return false }
        let left = try FileHandle(forReadingFrom: shorter)
        let right = try FileHandle(forReadingFrom: longer)
        defer {
            try? left.close()
            try? right.close()
        }
        while let leftChunk = try left.read(upToCount: 64 * 1024), !leftChunk.isEmpty {
            let rightChunk = try right.read(upToCount: leftChunk.count) ?? Data()
            guard rightChunk == leftChunk else { return false }
        }
        return true
    }

    private func applyTransaction(
        _ transaction: inout CodexInstanceSyncTransaction,
        root: URL,
        instances: [CodexInstance]
    ) throws {
        for index in transaction.operations.indices {
            try ensureAllStopped(instances)
            try validateOperation(transaction.operations[index], instances: instances)
            let source = URL(fileURLWithPath: transaction.operations[index].sourcePath)
            let destination = URL(fileURLWithPath: transaction.operations[index].destinationPath)
            guard try hashFile(source) == transaction.operations[index].sourceHash else {
                throw codexInstanceError("会话 \(transaction.operations[index].threadId) 的源文件在预览后发生变化")
            }
            if let destinationHash = transaction.operations[index].destinationHash {
                guard fileManager.fileExists(atPath: destination.path),
                      try hashFile(destination) == destinationHash,
                      let backupPath = transaction.operations[index].backupPath
                else {
                    throw codexInstanceError("会话 \(transaction.operations[index].threadId) 的目标文件在预览后发生变化")
                }
                let backup = URL(fileURLWithPath: backupPath)
                try ensureInside(backup, root: root)
                try copyAtomicallyVerified(
                    from: destination,
                    to: backup,
                    expectedHash: destinationHash
                )
            } else if fileManager.fileExists(atPath: destination.path) {
                throw codexInstanceError(
                    "会话 \(transaction.operations[index].threadId) 的目标路径在预览后被占用：\(destination.path)"
                )
            }
            try copyAtomicallyVerified(
                from: source,
                to: destination,
                expectedHash: transaction.operations[index].sourceHash
            )
            transaction.operations[index].installedHash = transaction.operations[index].sourceHash
            try writeTransaction(transaction, root: root)
        }
    }

    private func rollbackFiles(
        transaction: inout CodexInstanceSyncTransaction,
        instances: [CodexInstance]
    ) throws {
        let root = transactionRoot(id: transaction.transactionId)
        var failures: [String] = []
        for index in transaction.operations.indices.reversed() {
            let operation = transaction.operations[index]
            func restoreBackup(_ backupPath: String, destination: URL) throws {
                guard let originalHash = operation.destinationHash else {
                    throw codexInstanceError("回滚事务缺少原始校验值")
                }
                let backup = URL(fileURLWithPath: backupPath)
                try ensureInside(backup, root: root)
                guard try hashFile(backup) == originalHash else {
                    throw codexInstanceError("回滚备份校验失败：\(backup.path)")
                }
                try copyAtomicallyVerified(
                    from: backup,
                    to: destination,
                    expectedHash: originalHash
                )
            }
            do {
                try validateOperation(operation, instances: instances)
                let destination = URL(fileURLWithPath: operation.destinationPath)
                if !fileManager.fileExists(atPath: destination.path) {
                    if operation.installedHash != nil {
                        if let backupPath = operation.backupPath {
                            // 同步前目标存在：从已校验的备份恢复原内容即为回滚目标。
                            try restoreBackup(backupPath, destination: destination)
                        }
                        // 新增文件的回滚就是删除：目标已不存在即为目标状态（幂等重试）。
                    }
                } else {
                    let currentHash = try hashFile(destination)
                    // 目标已是同步前内容：已回滚（或从未生效），幂等跳过。
                    if operation.destinationHash != currentHash {
                        if let installedHash = operation.installedHash {
                            guard installedHash == operation.sourceHash else {
                                throw codexInstanceError("同步事务记录的安装校验值与源校验值不一致")
                            }
                        }
                        guard currentHash == operation.sourceHash else {
                            throw codexInstanceError("\(destination.path) 已在同步后被修改，拒绝覆盖")
                        }
                        if let backupPath = operation.backupPath {
                            try restoreBackup(backupPath, destination: destination)
                        } else {
                            try fileManager.removeItem(at: destination)
                            try syncDirectory(destination.deletingLastPathComponent())
                        }
                    }
                }
                // 每回滚一条即清 installedHash 并持久化，崩溃后重试可精确跳过。
                if transaction.operations[index].installedHash != nil {
                    transaction.operations[index].installedHash = nil
                    do {
                        try writeTransaction(transaction, root: root)
                    } catch {
                        failures.append("回滚进度未能持久化：\(error.localizedDescription)")
                    }
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty { throw codexInstanceError(failures.joined(separator: "；")) }
    }

    private func validateOperation(
        _ operation: CodexInstanceSyncOperation,
        instances: [CodexInstance]
    ) throws {
        guard let source = instances.first(where: { $0.id == operation.sourceInstanceId }),
              let destination = instances.first(where: { $0.id == operation.destinationInstanceId })
        else {
            throw codexInstanceError("同步事务实例不在选择范围内")
        }
        try ensureInside(
            URL(fileURLWithPath: operation.sourcePath),
            root: URL(fileURLWithPath: source.codexHome, isDirectory: true)
        )
        try ensureInside(
            URL(fileURLWithPath: operation.destinationPath),
            root: URL(fileURLWithPath: destination.codexHome, isDirectory: true)
        )
    }

    private func ensureInside(_ candidate: URL, root: URL) throws {
        let root = try canonicalDirectory(root, label: "受控根目录")
        let resolved: URL
        if fileManager.fileExists(atPath: candidate.path) {
            resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            try fileManager.createDirectory(
                at: candidate.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            resolved = try canonicalDirectory(
                candidate.deletingLastPathComponent(),
                label: "受控父目录"
            ).appendingPathComponent(candidate.lastPathComponent)
        }
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(prefix) else {
            throw codexInstanceError("路径 \(resolved.path) 越过受控根目录 \(root.path)")
        }
    }

    private func transactionRoot(id: String) -> URL {
        paths.syncRoot.appendingPathComponent("transactions/\(id)", isDirectory: true)
    }

    private func writeTransaction(
        _ transaction: CodexInstanceSyncTransaction,
        root: URL
    ) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try atomicWrite(
            try encoder.encode(transaction),
            to: root.appendingPathComponent("manifest.json")
        )
    }

    private func readTransaction(root: URL) throws -> CodexInstanceSyncTransaction {
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let transaction = try decoder.decode(CodexInstanceSyncTransaction.self, from: data)
        guard transaction.schemaVersion == schemaVersion else {
            throw codexInstanceError("不支持的同步事务版本 \(transaction.schemaVersion)")
        }
        return transaction
    }

    private func ensureNoUnfinishedTransactions(instanceIDs: [String]) throws {
        let selected = Set(instanceIDs)
        if let transaction = try allTransactions().first(where: {
            ["prepared", "failedNeedsRecovery"].contains($0.state)
                && !$0.instanceIds.allSatisfy { !selected.contains($0) }
        }) {
            throw codexInstanceError(
                "实例同步事务 \(transaction.transactionId) 尚未完成（\(transaction.state)）；请先在“同步回滚”中恢复"
            )
        }
    }

    private func ensureLatestRecoverableTransaction(
        _ target: CodexInstanceSyncTransaction
    ) throws {
        let selected = Set(target.instanceIds)
        if let later = try allTransactions().first(where: {
            $0.createdAt > target.createdAt
                && ["committed", "prepared", "failedNeedsRecovery"].contains($0.state)
                && !$0.instanceIds.allSatisfy { !selected.contains($0) }
        }) {
            throw codexInstanceError(
                "事务 \(target.transactionId) 之后还有关联事务 \(later.transactionId)；请先从最新事务开始回滚"
            )
        }
    }

    private func allTransactions() throws -> [CodexInstanceSyncTransaction] {
        let root = paths.syncRoot.appendingPathComponent("transactions", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            guard fileManager.fileExists(
                atPath: url.appendingPathComponent("manifest.json").path
            ) else { return nil }
            return try readTransaction(root: url)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    private func mergeConflicts(
        into existing: inout [CodexInstanceConflict],
        incoming: [CodexInstanceConflict]
    ) {
        for conflict in incoming {
            if let index = existing.firstIndex(where: {
                !$0.resolved && sameConflict($0, conflict)
            }) {
                existing[index].instanceIds = conflict.instanceIds
                existing[index].relativePaths = conflict.relativePaths
                existing[index].hashes = conflict.hashes
                existing[index].detectedAt = conflict.detectedAt
                existing[index].reason = conflict.reason
            } else {
                existing.append(conflict)
            }
        }
    }

    private func sameConflict(
        _ left: CodexInstanceConflict,
        _ right: CodexInstanceConflict
    ) -> Bool {
        left.threadId == right.threadId
            && left.instanceIds.sorted() == right.instanceIds.sorted()
            && left.hashes.sorted() == right.hashes.sorted()
    }
}

func codexAutomaticSyncInstanceIDs(_ instances: [CodexInstance]) -> [String] {
    ["default"] + instances.filter(\.autoSyncEnabled).map(\.id)
}

func codexProcessCommandContainsArgument(_ command: String, _ argument: String) -> Bool {
    guard !argument.isEmpty else { return false }
    var searchStart = command.startIndex
    while searchStart < command.endIndex,
          let range = command.range(of: argument, range: searchStart..<command.endIndex) {
        let before = range.lowerBound == command.startIndex
            || codexProcessArgumentBoundary(command[command.index(before: range.lowerBound)])
        let after = range.upperBound == command.endIndex
            || codexProcessArgumentBoundary(command[range.upperBound])
        if before && after { return true }
        searchStart = range.upperBound
    }
    return false
}

private func codexProcessArgumentBoundary(_ character: Character) -> Bool {
    character.isWhitespace || character == "\"" || character == "'"
}

private func codexInstanceError(_ message: String) -> NSError {
    NSError(
        domain: "CodexTokenBar.CodexInstances",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

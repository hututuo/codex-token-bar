import AppKit
import Darwin
import Foundation

enum CodexThreadDeleteBridgePhase: Equatable, Sendable {
    case idle
    case relaunching
    case waitingForDebugPort
    case validating
    case waitingForRows
    case ready
    case failed
}

struct CodexThreadDeleteBridgeStatus: Equatable, Sendable {
    let connected: Bool
    let debugPort: Int?
    let message: String
    let phase: CodexThreadDeleteBridgePhase

    init(
        connected: Bool,
        debugPort: Int?,
        message: String,
        phase: CodexThreadDeleteBridgePhase? = nil
    ) {
        self.connected = connected
        self.debugPort = debugPort
        self.message = message
        self.phase = phase ?? (connected ? .ready : (debugPort == nil ? .idle : .failed))
    }

    static let idle = CodexThreadDeleteBridgeStatus(
        connected: false,
        debugPort: nil,
        message: "等待 Codex 会话增强连接（需以调试模式启动 Codex）",
        phase: .idle
    )

    var requiresCodexRelaunch: Bool {
        !connected && debugPort == nil && !isBusy
    }

    var isBusy: Bool {
        phase == .relaunching || phase == .waitingForDebugPort || phase == .validating
    }

    var connectionActionTitle: String {
        if isBusy { return "正在启用 Codex 会话增强" }
        if phase == .waitingForRows { return "重新检查 Codex 会话增强" }
        return requiresCodexRelaunch
            ? "重启 Codex 并连接会话增强"
            : "重新连接 Codex 会话增强"
    }

    var dashboardActionTitle: String {
        if connected { return "会话增强" }
        if isBusy { return "增强连接中" }
        if phase == .waitingForRows { return "会话增强" }
        return "会话增强"
    }
}

@MainActor
final class CodexThreadDeleteBridgeController: ObservableObject {
    @Published private(set) var status: CodexThreadDeleteBridgeStatus = .idle
    @Published private(set) var enhancementSettings: CodexSessionEnhancementSettings

    private let service: CodexThreadDeleteBridgeService
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var relaunchTask: Task<Void, Never>?

    init(
        service: CodexThreadDeleteBridgeService? = nil,
        defaults: UserDefaults = .standard
    ) {
        let settings = CodexSessionEnhancementSettings.load(defaults: defaults)
        self.enhancementSettings = settings
        self.service = service ?? CodexThreadDeleteBridgeService(enhancementSettings: settings)
        self.defaults = defaults
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self, service] in
            await service.run { status in
                await MainActor.run {
                    self?.status = status
                }
            }
        }
    }

    func reconnect() {
        task?.cancel()
        status = CodexThreadDeleteBridgeStatus(
            connected: false,
            debugPort: status.debugPort,
            message: "正在重新连接 Codex 会话增强",
            phase: .validating
        )
        task = Task { [weak self, service] in
            await service.cancelActiveSession()
            await service.run { status in
                await MainActor.run {
                    self?.status = status
                }
            }
        }
    }

    func performConnectionAction() {
        guard !status.isBusy else { return }
        guard status.requiresCodexRelaunch else {
            reconnect()
            return
        }

        let conflicts = CodexThreadDeleteDesktopLauncher.runningConflictNames()
        if !conflicts.isEmpty {
            let conflictAlert = NSAlert()
            conflictAlert.alertStyle = .critical
            conflictAlert.messageText = "请先退出 \(conflicts.joined(separator: "、"))"
            conflictAlert.informativeText = "这些程序会控制 Codex 的启动方式，可能覆盖 Token Bar 所需的本机调试参数。Token Bar 不会自动关闭它们；退出后再点“启用会话增强”。"
            conflictAlert.addButton(withTitle: "我知道了")
            conflictAlert.runModal()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "重启 Codex 并启用会话增强？"
        alert.informativeText = "Codex 会关闭后立即以仅限本机的调试端口重新打开。当前任务不会被删除，但正在生成的回复会中断，界面也会短暂消失。"
        alert.addButton(withTitle: "重启并启用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        relaunchCodexWithDebugPort()
    }

    private func relaunchCodexWithDebugPort() {
        guard relaunchTask == nil else { return }
        task?.cancel()
        task = nil
        status = CodexThreadDeleteBridgeStatus(
            connected: false,
            debugPort: nil,
            message: "正在重启 Codex 并连接会话增强",
            phase: .relaunching
        )
        relaunchTask = Task { [weak self, service] in
            await service.cancelActiveSession()
            do {
                switch await service.probeDebugPort(9229) {
                case let .target(target):
                    guard !Task.isCancelled, let self else { return }
                    self.relaunchTask = nil
                    self.status = CodexThreadDeleteBridgeStatus(
                        connected: false,
                        debugPort: target.port,
                        message: "调试端口已存在，正在验证会话增强",
                        phase: .validating
                    )
                    self.reconnect()
                    return
                case .occupied:
                    throw CodexThreadDeleteError.debugPortOccupied(9229)
                case .unavailable:
                    break
                }
                let receipt = try await CodexThreadDeleteDesktopLauncher.relaunch()
                guard !Task.isCancelled, let self else { return }
                self.status = CodexThreadDeleteBridgeStatus(
                    connected: false,
                    debugPort: nil,
                    message: "Codex 已重新打开（PID \(receipt.processIdentifier)），正在确认调试端口",
                    phase: .waitingForDebugPort
                )
                let target = try await service.waitForDebugTarget(port: 9229)
                guard !Task.isCancelled else { return }
                self.status = CodexThreadDeleteBridgeStatus(
                    connected: false,
                    debugPort: target.port,
                    message: "调试端口已确认，正在验证会话增强",
                    phase: .validating
                )
                self.relaunchTask = nil
                self.reconnect()
            } catch {
                guard let self else { return }
                self.relaunchTask = nil
                self.status = CodexThreadDeleteBridgeStatus(
                    connected: false,
                    debugPort: nil,
                    message: "连接 Codex 会话增强失败：\(error.localizedDescription)",
                    phase: .failed
                )
                self.startRecoveryProbe()
            }
        }
    }

    private func startRecoveryProbe() {
        task?.cancel()
        task = Task { [weak self, service] in
            await service.run(publishIdle: false, restrictedPorts: [9229]) { status in
                await MainActor.run {
                    self?.status = status
                }
            }
        }
    }

    func setSessionDeleteEnabled(_ enabled: Bool) {
        updateEnhancementSettings { $0.sessionDelete = enabled }
    }

    func setMarkdownExportEnabled(_ enabled: Bool) {
        updateEnhancementSettings { $0.markdownExport = enabled }
    }

    func setPasteFixEnabled(_ enabled: Bool) {
        updateEnhancementSettings { $0.pasteFix = enabled }
    }

    func setProjectMoveEnabled(_ enabled: Bool) {
        updateEnhancementSettings { $0.projectMove = enabled }
    }

    func setThreadIDBadgeEnabled(_ enabled: Bool) {
        updateEnhancementSettings { $0.threadIDBadge = enabled }
    }

    func setConversationViewEnabled(_ enabled: Bool) {
        updateEnhancementSettings { $0.conversationView = enabled }
    }

    func setConversationViewMaxWidth(_ width: Int) {
        updateEnhancementSettings { $0.conversationViewMaxWidth = width }
    }

    func setThreadScrollRestoreEnabled(_ enabled: Bool) {
        updateEnhancementSettings { $0.threadScrollRestore = enabled }
    }

    private func updateEnhancementSettings(
        _ mutate: (inout CodexSessionEnhancementSettings) -> Void
    ) {
        var next = enhancementSettings
        mutate(&next)
        next = next.normalized
        guard next != enhancementSettings else { return }
        enhancementSettings = next
        next.save(defaults: defaults)

        task?.cancel()
        status = CodexThreadDeleteBridgeStatus(
            connected: false,
            debugPort: status.debugPort,
            message: "正在应用会话增强设置",
            phase: .validating
        )
        task = Task { [weak self, service] in
            await service.updateEnhancementSettings(next)
            await service.cancelActiveSession()
            await service.run { status in
                await MainActor.run {
                    self?.status = status
                }
            }
        }
    }
}

struct CodexThreadDeleteRunningApplicationSnapshot: Equatable, Sendable {
    let bundleIdentifier: String
    let localizedName: String
    let processIdentifier: Int32
    let bundlePath: String?
    let terminated: Bool
}

struct CodexThreadDeleteDesktopLaunchReceipt: Equatable, Sendable {
    let processIdentifier: Int32
    let applicationPath: String
}

@MainActor
enum CodexThreadDeleteDesktopLauncher {
    static let bundleIdentifier = "com.openai.codex"
    static let competingBundleIdentifiers: Set<String> = [
        "com.bigpizzav3.codexplusplus",
        "com.bigpizzav3.codexplusplus.manager",
    ]
    static let debugArguments = [
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=9229",
    ]

    static func openCommandArguments(applicationPath: String) -> [String] {
        ["-na", applicationPath, "--args"] + debugArguments
    }

    static func conflictingApplicationNames(
        in snapshots: [CodexThreadDeleteRunningApplicationSnapshot]
    ) -> [String] {
        Array(Set(snapshots.compactMap { snapshot in
            guard !snapshot.terminated,
                  competingBundleIdentifiers.contains(snapshot.bundleIdentifier)
            else { return nil }
            return snapshot.localizedName.isEmpty ? "Codex++" : snapshot.localizedName
        })).sorted()
    }

    static func runningConflictNames() -> [String] {
        conflictingApplicationNames(in: NSWorkspace.shared.runningApplications.map(snapshot))
    }

    static func selectedApplicationPath(
        running snapshots: [CodexThreadDeleteRunningApplicationSnapshot],
        registeredPath: String?
    ) throws -> String {
        let liveOfficialSnapshots = snapshots.filter {
            !$0.terminated && $0.bundleIdentifier == bundleIdentifier
        }
        guard liveOfficialSnapshots.allSatisfy({ $0.bundlePath != nil }) else {
            throw CodexThreadDeleteError.desktopAppIdentityUnavailable
        }
        let runningPaths = Set(snapshots.compactMap { snapshot -> String? in
            guard !snapshot.terminated,
                  snapshot.bundleIdentifier == bundleIdentifier,
                  let bundlePath = snapshot.bundlePath
            else { return nil }
            return URL(fileURLWithPath: bundlePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        })
        guard runningPaths.count <= 1 else {
            throw CodexThreadDeleteError.desktopAppAmbiguous(Array(runningPaths).sorted())
        }
        if let path = runningPaths.first {
            return path
        }
        guard let registeredPath else {
            throw CodexThreadDeleteError.desktopAppMissing
        }
        return URL(fileURLWithPath: registeredPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    static func relaunch() async throws -> CodexThreadDeleteDesktopLaunchReceipt {
        let conflicts = runningConflictNames()
        guard conflicts.isEmpty else {
            throw CodexThreadDeleteError.desktopControllerConflict(conflicts)
        }
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else {
            throw CodexThreadDeleteError.desktopDebugLaunchUnavailableInSandbox
        }
        let runningApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        let registeredURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        )
        let applicationPath = try selectedApplicationPath(
            running: runningApplications.map(snapshot),
            registeredPath: registeredURL?.path
        )
        let applicationURL = URL(fileURLWithPath: applicationPath)
        var terminationStarted = false

        do {
            for application in runningApplications where !application.isTerminated {
                terminationStarted = true
                guard application.terminate() else {
                    throw CodexThreadDeleteError.desktopTerminationRejected
                }
            }

            let deadline = Date().addingTimeInterval(10)
            while runningApplications.contains(where: { !$0.isTerminated }) {
                guard Date() < deadline else {
                    throw CodexThreadDeleteError.desktopTerminationTimeout
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            let lateConflicts = runningConflictNames()
            guard lateConflicts.isEmpty else {
                throw CodexThreadDeleteError.desktopControllerConflict(lateConflicts)
            }
            let unexpectedApplications = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).filter { !$0.isTerminated }
            guard unexpectedApplications.isEmpty else {
                throw CodexThreadDeleteError.desktopCompetingLaunch(
                    unexpectedApplications.map(\.processIdentifier)
                )
            }

            let arguments = openCommandArguments(applicationPath: applicationURL.path)
            let result = try await Task.detached(priority: .userInitiated) {
                try CodexThreadDeleteSubprocess.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: arguments,
                    timeout: 10
                )
            }.value
            guard result.terminationStatus == 0 else {
                throw CodexThreadDeleteError.desktopRelaunchFailed(
                    result.stderr.isEmpty ? result.stdout : result.stderr
                )
            }

            let previousProcessIdentifiers = Set(runningApplications.map(\.processIdentifier))
            let expectedPath = applicationPath
            let launchDeadline = Date().addingTimeInterval(10)
            var stableCandidate: (processIdentifier: Int32, firstSeenAt: Date)?
            while Date() < launchDeadline {
                let candidates = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier
                ).filter {
                    !$0.isTerminated && !previousProcessIdentifiers.contains($0.processIdentifier)
                }
                let matching = candidates.filter { application in
                    guard let bundleURL = application.bundleURL else { return false }
                    return bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == expectedPath
                }
                guard matching.count == candidates.count, matching.count <= 1 else {
                    throw CodexThreadDeleteError.desktopCompetingLaunch(
                        candidates.map(\.processIdentifier)
                    )
                }
                if let launched = matching.first {
                    if stableCandidate?.processIdentifier == launched.processIdentifier,
                       let firstSeenAt = stableCandidate?.firstSeenAt,
                       Date().timeIntervalSince(firstSeenAt) >= 0.25 {
                        return CodexThreadDeleteDesktopLaunchReceipt(
                            processIdentifier: launched.processIdentifier,
                            applicationPath: expectedPath
                        )
                    }
                    stableCandidate = (launched.processIdentifier, Date())
                } else {
                    stableCandidate = nil
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CodexThreadDeleteError.desktopLaunchVerificationTimeout
        } catch {
            guard terminationStarted else { throw error }
            let recovery = await ensureCodexIsRunning(at: applicationURL)
            throw CodexThreadDeleteError.desktopRelaunchTransactionFailed(
                cause: error.localizedDescription,
                recovery: recovery
            )
        }
    }

    private static func ensureCodexIsRunning(at applicationURL: URL) async -> String {
        let expectedPath = applicationURL.standardizedFileURL.resolvingSymlinksInPath().path
        let stabilityDeadline = Date().addingTimeInterval(1)
        while Date() < stabilityDeadline {
            let hasLiveProcess = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).contains(where: { !$0.isTerminated })
            if !hasLiveProcess { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let liveApplications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { !$0.isTerminated }
        if liveApplications.contains(where: { application in
            guard let bundleURL = application.bundleURL else { return false }
            return bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == expectedPath
        }) {
            return "原 Codex 已保持运行"
        }
        if !liveApplications.isEmpty {
            return "检测到其他 Codex 已运行，未再重复打开"
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        let restoredApplication = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                continuation.resume(returning: error == nil ? application : nil)
            }
        }
        guard let restoredApplication,
              !restoredApplication.isTerminated,
              let restoredURL = restoredApplication.bundleURL,
              restoredURL.standardizedFileURL.resolvingSymlinksInPath().path == expectedPath
        else {
            return "普通恢复启动也失败"
        }
        let restoredProcessIdentifier = restoredApplication.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        var stableSince: Date?
        while Date() < deadline {
            let stableApplication = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first(where: { application in
                guard !application.isTerminated,
                      application.processIdentifier == restoredProcessIdentifier,
                      let bundleURL = application.bundleURL
                else { return false }
                return bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == expectedPath
            })
            if stableApplication != nil {
                stableSince = stableSince ?? Date()
                if let stableSince, Date().timeIntervalSince(stableSince) >= 0.25 {
                    return "Codex 已恢复为普通启动"
                }
            } else {
                stableSince = nil
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return "普通恢复启动也失败"
    }

    private static func snapshot(
        _ application: NSRunningApplication
    ) -> CodexThreadDeleteRunningApplicationSnapshot {
        CodexThreadDeleteRunningApplicationSnapshot(
            bundleIdentifier: application.bundleIdentifier ?? "",
            localizedName: application.localizedName ?? "",
            processIdentifier: application.processIdentifier,
            bundlePath: application.bundleURL?.path,
            terminated: application.isTerminated
        )
    }
}

struct CodexThreadDeleteCDPCommandError: Decodable, Equatable, Sendable {
    let code: Int?
    let message: String
}

struct CodexThreadDeleteCDPException: Decodable, Equatable, Sendable {
    struct RemoteException: Decodable, Equatable, Sendable {
        let description: String?
    }

    let text: String
    let exception: RemoteException?

    var detail: String {
        exception?.description ?? text
    }
}

struct CodexThreadDeleteInjectionHealth: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let owner: String
    let bridgeRegistered: Bool
    let bindingMatches: Bool
    let bindingAvailable: Bool
    let deleteEnabled: Bool
    let sessionEnhancementsInstalled: Bool
    let sessionEnhancementError: String?
    let candidateRowCount: Int
    let eligibleRowCount: Int
    let attachedRowCount: Int
    let buttonCount: Int
    let missingButtonCount: Int
    let duplicateButtonCount: Int
    let orphanButtonCount: Int
    let styleInstalled: Bool
    let observerInstalled: Bool
    let scanError: String?
    let readiness: String
}

enum CodexThreadDeleteInjectionVerification: Equatable, Sendable {
    case ready(buttonCount: Int)
    case waitingForRows

    static func verify(
        _ health: CodexThreadDeleteInjectionHealth,
        owner: String = "swift"
    ) throws -> Self {
        guard health.schemaVersion == 2 else {
            throw CodexThreadDeleteError.injectionVerificationFailed("健康协议版本不兼容")
        }
        guard health.owner == owner,
              health.bridgeRegistered,
              health.bindingMatches,
              health.bindingAvailable,
              health.sessionEnhancementsInstalled,
              health.styleInstalled,
              health.observerInstalled
        else {
            throw CodexThreadDeleteError.injectionVerificationFailed("桥接、绑定、样式或页面观察器未完整安装")
        }
        if let scanError = health.scanError, !scanError.isEmpty {
            throw CodexThreadDeleteError.injectionVerificationFailed("扫描侧栏失败：\(scanError)")
        }
        if let enhancementError = health.sessionEnhancementError, !enhancementError.isEmpty {
            throw CodexThreadDeleteError.injectionVerificationFailed("会话增强扫描失败：\(enhancementError)")
        }
        let counts = [
            health.candidateRowCount,
            health.eligibleRowCount,
            health.attachedRowCount,
            health.buttonCount,
            health.missingButtonCount,
            health.duplicateButtonCount,
            health.orphanButtonCount,
        ]
        guard counts.allSatisfy({ $0 >= 0 }),
              health.candidateRowCount >= health.eligibleRowCount
        else {
            throw CodexThreadDeleteError.injectionVerificationFailed("页面返回了无效的按钮计数")
        }
        if health.eligibleRowCount == 0 {
            guard health.candidateRowCount == 0,
                  health.attachedRowCount == 0,
                  health.buttonCount == 0,
                  health.missingButtonCount == 0,
                  health.duplicateButtonCount == 0,
                  health.orphanButtonCount == 0,
                  health.readiness == "waitingForRows"
            else {
                throw CodexThreadDeleteError.injectionVerificationFailed("侧栏候选行缺少可识别的会话 ID，可能是 Codex 页面结构已变化")
            }
            return .waitingForRows
        }
        let expectedButtonCount = health.deleteEnabled ? health.eligibleRowCount : 0
        guard health.candidateRowCount == health.eligibleRowCount,
              health.attachedRowCount == expectedButtonCount,
              health.buttonCount == expectedButtonCount,
              health.missingButtonCount == 0,
              health.duplicateButtonCount == 0,
              health.orphanButtonCount == 0,
              health.readiness == "ready"
        else {
            throw CodexThreadDeleteError.injectionVerificationFailed(
                "检测到 \(health.eligibleRowCount) 条会话，但会话增强控件验收不完整"
            )
        }
        return .ready(buttonCount: health.buttonCount)
    }

    func bridgeStatus(debugPort: Int) -> CodexThreadDeleteBridgeStatus {
        switch self {
        case let .ready(buttonCount):
            return CodexThreadDeleteBridgeStatus(
                connected: true,
                debugPort: debugPort,
                message: buttonCount > 0
                    ? "Codex 会话增强已连接，已验证 \(buttonCount) 个会话按钮"
                    : "Codex 会话增强已连接，页面能力已验证",
                phase: .ready
            )
        case .waitingForRows:
            return CodexThreadDeleteBridgeStatus(
                connected: false,
                debugPort: debugPort,
                message: "CDP 命令和脚本已验证，当前侧栏暂无会话行",
                phase: .waitingForRows
            )
        }
    }
}

struct CodexThreadDeleteCDPRemoteObject: Decodable, Equatable, Sendable {
    let value: CodexThreadDeleteInjectionHealth?
    let booleanValue: Bool?

    private enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try? container.decode(
            CodexThreadDeleteInjectionHealth.self,
            forKey: .value
        )
        booleanValue = try? container.decode(Bool.self, forKey: .value)
    }
}

struct CodexThreadDeleteCDPCommandResult: Decodable, Equatable, Sendable {
    let result: CodexThreadDeleteCDPRemoteObject?
    let identifier: String?
    let exceptionDetails: CodexThreadDeleteCDPException?
}

struct CodexThreadDeleteCDPCommandResponse: Decodable, Equatable, Sendable {
    let id: Int
    let result: CodexThreadDeleteCDPCommandResult?
    let error: CodexThreadDeleteCDPCommandError?

    func validated(method: String) throws -> Self {
        if let error {
            throw CodexThreadDeleteError.cdpCommandFailed(
                method: method,
                code: error.code,
                message: error.message
            )
        }
        if let exception = result?.exceptionDetails {
            throw CodexThreadDeleteError.cdpEvaluationException(exception.detail)
        }
        guard result != nil else {
            throw CodexThreadDeleteError.cdpMalformedResponse(method)
        }
        return self
    }

    func decodedHealth() throws -> CodexThreadDeleteInjectionHealth {
        guard let health = result?.result?.value else {
            throw CodexThreadDeleteError.injectionVerificationFailed("页面没有返回删除按钮健康信息")
        }
        return health
    }

    func scriptIdentifier(method: String) throws -> String {
        guard let identifier = result?.identifier, !identifier.isEmpty else {
            throw CodexThreadDeleteError.cdpMalformedResponse(method)
        }
        return identifier
    }

    func acknowledgedBoolean(method: String) throws {
        guard result?.result?.booleanValue == true else {
            throw CodexThreadDeleteError.injectionVerificationFailed(
                "\(method) 未被页面接收"
            )
        }
    }
}

struct CodexThreadDeleteBindingEvent: Equatable, Sendable {
    let name: String
    let payload: String
    let executionContextID: Int?
}

private struct CodexThreadDeleteCDPMessageHeader: Decodable {
    let id: Int?
    let method: String?
}

private struct CodexThreadDeleteCDPBindingEnvelope: Decodable {
    struct Parameters: Decodable {
        let name: String
        let payload: String
        let executionContextId: Int?
    }

    let method: String
    let params: Parameters
}

private struct CodexThreadDeleteCDPRequest<Parameters: Encodable & Sendable>: Encodable, Sendable {
    let id: Int
    let method: String
    let params: Parameters
}

private struct CodexThreadDeleteCDPEmptyParameters: Encodable, Sendable {}

private struct CodexThreadDeleteCDPBindingParameters: Encodable, Sendable {
    let name: String
}

private struct CodexThreadDeleteCDPSourceParameters: Encodable, Sendable {
    let source: String
}

private struct CodexThreadDeleteCDPScriptIdentifierParameters: Encodable, Sendable {
    let identifier: String
}

private struct CodexThreadDeleteCDPEvaluateParameters: Encodable, Sendable {
    let expression: String
    let returnByValue: Bool
    let contextId: Int?
    let awaitPromise: Bool?

    init(
        expression: String,
        returnByValue: Bool = false,
        contextId: Int? = nil,
        awaitPromise: Bool? = nil
    ) {
        self.expression = expression
        self.returnByValue = returnByValue
        self.contextId = contextId
        self.awaitPromise = awaitPromise
    }
}

protocol CodexThreadDeleteWebSocket: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: CodexThreadDeleteWebSocket {}

actor CodexThreadDeleteCDPTransport {
    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<CodexThreadDeleteCDPCommandResponse, Error>
        let timeoutTask: Task<Void, Never>
        let timeoutClosesTransport: Bool
    }

    private let socket: any CodexThreadDeleteWebSocket
    private let eventStream: AsyncThrowingStream<CodexThreadDeleteBindingEvent, Error>
    private let eventContinuation: AsyncThrowingStream<CodexThreadDeleteBindingEvent, Error>.Continuation
    private var readerTask: Task<Void, Never>?
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextMessageID = 100
    private var closed = false

    init(socket: any CodexThreadDeleteWebSocket) {
        self.socket = socket
        let pair = AsyncThrowingStream<CodexThreadDeleteBindingEvent, Error>.makeStream()
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func start() {
        guard readerTask == nil, !closed else { return }
        socket.resume()
        readerTask = Task { [weak self] in
            await self?.readerLoop()
        }
    }

    func bindingEvents() -> AsyncThrowingStream<CodexThreadDeleteBindingEvent, Error> {
        eventStream
    }

    func request<Parameters: Encodable & Sendable>(
        method: String,
        params: Parameters,
        timeout: Duration = .seconds(5),
        timeoutClosesTransport: Bool = true
    ) async throws -> CodexThreadDeleteCDPCommandResponse {
        guard !closed else { throw CodexThreadDeleteError.cdpConnectionClosed }
        nextMessageID &+= 1
        let requestID = nextMessageID
        let payload = try JSONEncoder().encode(CodexThreadDeleteCDPRequest(
            id: requestID,
            method: method,
            params: params
        ))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        await self?.timeoutRequest(id: requestID)
                    } catch {
                        // The response or caller cancellation won the race.
                    }
                }
                pendingRequests[requestID] = PendingRequest(
                    method: method,
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    timeoutClosesTransport: timeoutClosesTransport
                )
                Task { [weak self] in
                    await self?.sendRegisteredRequest(id: requestID, payload: payload)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(id: requestID)
            }
        }
    }

    func close() {
        finish(with: CancellationError())
    }

    private func readerLoop() async {
        do {
            while !Task.isCancelled, !closed {
                let message = try await socket.receive()
                try route(message)
            }
        } catch {
            finish(with: Task.isCancelled ? CancellationError() : error)
        }
    }

    private func route(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(payload):
            data = payload
        @unknown default:
            return
        }
        let header = try JSONDecoder().decode(CodexThreadDeleteCDPMessageHeader.self, from: data)
        if let id = header.id {
            guard let pending = pendingRequests.removeValue(forKey: id) else { return }
            pending.timeoutTask.cancel()
            do {
                let response = try JSONDecoder()
                    .decode(CodexThreadDeleteCDPCommandResponse.self, from: data)
                    .validated(method: pending.method)
                pending.continuation.resume(returning: response)
            } catch {
                pending.continuation.resume(throwing: error)
            }
            return
        }
        guard header.method == "Runtime.bindingCalled" else { return }
        let envelope = try JSONDecoder().decode(CodexThreadDeleteCDPBindingEnvelope.self, from: data)
        eventContinuation.yield(CodexThreadDeleteBindingEvent(
            name: envelope.params.name,
            payload: envelope.params.payload,
            executionContextID: envelope.params.executionContextId
        ))
    }

    private func sendRegisteredRequest(id: Int, payload: Data) async {
        guard pendingRequests[id] != nil, !closed else { return }
        do {
            try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
        } catch {
            failRequest(id: id, error: error)
        }
    }

    private func timeoutRequest(id: Int) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.continuation.resume(
            throwing: CodexThreadDeleteError.cdpResponseTimeout(pending.method)
        )
        // awaitPromise 型长请求（Markdown 分块等页面写盘）超时只应判该请求
        // 失败：慢盘不是连接故障，拆整条 transport 会殃及同页面全部功能。
        guard pending.timeoutClosesTransport else { return }
        finish(with: CodexThreadDeleteError.cdpResponseTimeout(pending.method))
    }

    private func cancelRequest(id: Int) {
        failRequest(id: id, error: CancellationError())
    }

    private func failRequest(id: Int, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func finish(with error: Error) {
        guard !closed else { return }
        closed = true
        socket.cancel(with: .goingAway, reason: nil)
        readerTask?.cancel()
        readerTask = nil
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for pending in requests {
            pending.timeoutTask.cancel()
            pending.continuation.resume(throwing: error)
        }
        eventContinuation.finish(throwing: error)
    }
}

enum CodexThreadDeleteDebugPortProbe: Equatable, Sendable {
    case unavailable
    case occupied
    case target(CodexThreadDeleteTarget)
}

enum CodexThreadDeleteDebugPortErrorClassifier {
    static func meansNoListener(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .cannotConnectToHost
    }
}

actor CodexThreadDeleteBridgeService {
    private static let owner = "swift"
    private static let bindingName = "codexTokenBarDeleteSwift"

    private let ports: [Int]
    private let executor: any CodexThreadDeleteExecuting
    private let enhancementExecutor: any CodexSessionEnhancementExecuting
    private let session: URLSession
    private var enhancementSettings: CodexSessionEnhancementSettings
    private var activeTransport: CodexThreadDeleteCDPTransport?
    private var bootstrapScriptRegistrations: [URL: String] = [:]
    private var lifecycleGeneration = 0

    init(
        ports: [Int] = [9229, 9222],
        executor: any CodexThreadDeleteExecuting = FoundationCodexThreadDeleteExecutor(),
        enhancementExecutor: any CodexSessionEnhancementExecuting = FoundationCodexSessionEnhancementExecutor(),
        enhancementSettings: CodexSessionEnhancementSettings = .default,
        session: URLSession = .shared
    ) {
        self.ports = ports
        self.executor = executor
        self.enhancementExecutor = enhancementExecutor
        self.enhancementSettings = enhancementSettings.normalized
        self.session = session
    }

    func updateEnhancementSettings(_ settings: CodexSessionEnhancementSettings) {
        enhancementSettings = settings.normalized
    }

    func run(
        publishIdle: Bool = true,
        restrictedPorts: [Int]? = nil,
        statusChanged: @escaping @Sendable (CodexThreadDeleteBridgeStatus) async -> Void
    ) async {
        let generation = lifecycleGeneration
        while !Task.isCancelled, generation == lifecycleGeneration {
            guard let target = await findTarget(ports: restrictedPorts ?? ports) else {
                guard generation == lifecycleGeneration else { return }
                if publishIdle {
                    await statusChanged(.idle)
                }
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            await statusChanged(CodexThreadDeleteBridgeStatus(
                connected: false,
                debugPort: target.port,
                message: "已发现 Codex 调试端口，正在验证会话增强",
                phase: .validating
            ))
            do {
                try await runSession(
                    target: target,
                    generation: generation,
                    statusChanged: statusChanged
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == lifecycleGeneration else { return }
                await statusChanged(CodexThreadDeleteBridgeStatus(
                    connected: false,
                    debugPort: target.port,
                    message: "Codex 会话增强连接中断：\(error.localizedDescription)",
                    phase: .failed
                ))
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func cancelActiveSession() async {
        lifecycleGeneration &+= 1
        if let activeTransport {
            await activeTransport.close()
        }
        activeTransport = nil
    }

    func probeDebugPort(_ port: Int) async -> CodexThreadDeleteDebugPortProbe {
        await probe(port: port)
    }

    func waitForDebugTarget(
        port: Int,
        timeout: TimeInterval = 15
    ) async throws -> CodexThreadDeleteTarget {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            if case let .target(target) = await probe(port: port) {
                return target
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        throw CodexThreadDeleteError.debugPortUnavailable([port])
    }

    private func findTarget(ports: [Int]) async -> CodexThreadDeleteTarget? {
        for port in ports {
            if case let .target(target) = await probe(port: port) {
                return target
            }
        }
        return nil
    }

    private func probe(port: Int) async -> CodexThreadDeleteDebugPortProbe {
        guard !Task.isCancelled,
              let url = URL(string: "http://127.0.0.1:\(port)/json/list")
        else { return .unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled { return .occupied }
            return CodexThreadDeleteDebugPortErrorClassifier.meansNoListener(error)
                ? .unavailable
                : .occupied
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let targets = try? JSONDecoder().decode(
                [CodexThreadDeleteTargetPayload].self,
                from: data
              )
        else {
            return .occupied
        }
        if let target = targets.compactMap({ $0.target(port: port) }).first {
            return .target(target)
        }
        return .occupied
    }

    private func runSession(
        target: CodexThreadDeleteTarget,
        generation: Int,
        statusChanged: @escaping @Sendable (CodexThreadDeleteBridgeStatus) async -> Void
    ) async throws {
        let request = CodexThreadDeleteWebSocketRequest.make(for: target)
        let socket = session.webSocketTask(with: request)
        let transport = CodexThreadDeleteCDPTransport(socket: socket)
        activeTransport = transport
        await transport.start()

        do {
            let verification = try await installBridge(
                on: transport,
                target: target
            )
            guard generation == lifecycleGeneration else { throw CancellationError() }
            await publish(
                verification: verification,
                port: target.port,
                statusChanged: statusChanged
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [self] in
                    do {
                        try await consumeBindingEvents(
                            on: transport,
                            generation: generation
                        )
                    } catch {
                        await transport.close()
                        throw error
                    }
                }
                group.addTask { [self] in
                    do {
                        try await monitorHealth(
                            initial: verification,
                            on: transport,
                            port: target.port,
                            generation: generation,
                            statusChanged: statusChanged
                        )
                    } catch {
                        await transport.close()
                        throw error
                    }
                }
                do {
                    while let _ = try await group.next() {}
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
            throw CodexThreadDeleteError.cdpConnectionClosed
        } catch {
            await transport.close()
            if activeTransport === transport {
                activeTransport = nil
            }
            throw error
        }
    }

    private func consumeBindingEvents(
        on transport: CodexThreadDeleteCDPTransport,
        generation: Int
    ) async throws {
        let events = await transport.bindingEvents()
        // 每个 binding 请求独立子任务处理：GiB 级 Markdown 导出需要数万次
        // 分块往返，串行 await 会让期间的删除/第二个导出排队到页面超时。
        // transfer 状态按 owner+requestId 隔离，transport 请求按 id 关联，
        // 并发天然安全；单个请求的失败也不再拆毁整条会话。
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            for try await event in events {
                guard !Task.isCancelled, generation == lifecycleGeneration else {
                    throw CancellationError()
                }
                group.addTask { [self] in
                    await handleBindingEvent(event, transport: transport)
                }
            }
            throw CodexThreadDeleteError.cdpConnectionClosed
        }
    }

    private func monitorHealth(
        initial: CodexThreadDeleteInjectionVerification,
        on transport: CodexThreadDeleteCDPTransport,
        port: Int,
        generation: Int,
        statusChanged: @escaping @Sendable (CodexThreadDeleteBridgeStatus) async -> Void
    ) async throws {
        var previous = initial
        while !Task.isCancelled, generation == lifecycleGeneration {
            try await Task.sleep(for: .seconds(3))
            let verification = try await evaluateHealth(on: transport)
            guard generation == lifecycleGeneration else { throw CancellationError() }
            if verification != previous {
                await publish(
                    verification: verification,
                    port: port,
                    statusChanged: statusChanged
                )
                previous = verification
            }
        }
        throw CancellationError()
    }

    private func publish(
        verification: CodexThreadDeleteInjectionVerification,
        port: Int,
        statusChanged: @escaping @Sendable (CodexThreadDeleteBridgeStatus) async -> Void
    ) async {
        await statusChanged(verification.bridgeStatus(debugPort: port))
    }

    private func installBridge(
        on transport: CodexThreadDeleteCDPTransport,
        target: CodexThreadDeleteTarget
    ) async throws -> CodexThreadDeleteInjectionVerification {
        let script = try CodexThreadDeleteInjectionScript.render(
            owner: Self.owner,
            bindingName: Self.bindingName,
            settings: enhancementSettings
        )
        _ = try await transport.request(
            method: "Runtime.enable",
            params: CodexThreadDeleteCDPEmptyParameters()
        )
        _ = try await transport.request(
            method: "Runtime.removeBinding",
            params: CodexThreadDeleteCDPBindingParameters(name: Self.bindingName)
        )
        _ = try await transport.request(
            method: "Runtime.addBinding",
            params: CodexThreadDeleteCDPBindingParameters(name: Self.bindingName)
        )
        if let previous = bootstrapScriptRegistrations[target.webSocketURL] {
            _ = try await transport.request(
                method: "Page.removeScriptToEvaluateOnNewDocument",
                params: CodexThreadDeleteCDPScriptIdentifierParameters(
                    identifier: previous
                )
            )
            bootstrapScriptRegistrations.removeValue(
                forKey: target.webSocketURL
            )
        }
        let registration = try await transport.request(
            method: "Page.addScriptToEvaluateOnNewDocument",
            params: CodexThreadDeleteCDPSourceParameters(source: script)
        )
        bootstrapScriptRegistrations[target.webSocketURL] = try registration
            .scriptIdentifier(
                method: "Page.addScriptToEvaluateOnNewDocument"
            )
        _ = try await transport.request(
            method: "Runtime.evaluate",
            params: CodexThreadDeleteCDPEvaluateParameters(
                expression: script,
                returnByValue: true
            )
        )
        _ = try await transport.request(
            method: "Runtime.evaluate",
            params: CodexThreadDeleteCDPEvaluateParameters(
                expression: try CodexThreadDeleteInjectionScript
                    .abortOrphanTransfersExpression(owner: Self.owner),
                returnByValue: true
            )
        )

        var verification = try await evaluateHealth(on: transport)
        for _ in 0..<6 {
            guard case .waitingForRows = verification else { break }
            try await Task.sleep(for: .milliseconds(250))
            verification = try await evaluateHealth(on: transport)
        }
        return verification
    }

    private func evaluateHealth(
        on transport: CodexThreadDeleteCDPTransport
    ) async throws -> CodexThreadDeleteInjectionVerification {
        let expression = try CodexThreadDeleteInjectionScript.healthExpression(
            owner: Self.owner,
            bindingName: Self.bindingName
        )
        let response = try await transport.request(
            method: "Runtime.evaluate",
            params: CodexThreadDeleteCDPEvaluateParameters(
                expression: expression,
                returnByValue: true
            )
        )
        return try CodexThreadDeleteInjectionVerification.verify(
            response.decodedHealth(),
            owner: Self.owner
        )
    }

    private func handleBindingEvent(
        _ event: CodexThreadDeleteBindingEvent,
        transport: CodexThreadDeleteCDPTransport
    ) async {
        guard event.name == Self.bindingName else { return }
        let request: CodexThreadDeleteBindingRequest
        do {
            guard let payloadData = event.payload.data(using: .utf8) else {
                throw CodexThreadDeleteError.invalidBindingPayload
            }
            request = try JSONDecoder().decode(
                CodexThreadDeleteBindingRequest.self,
                from: payloadData
            )
        } catch {
            // 单个畸形请求不值得拆毁整条 CDP 会话（会殃及页面上所有挂起
            // 回调），记录后忽略；对应页面回调由其自身超时收敛。
            NSLog("CodexTokenBar: 会话增强请求格式错误，已忽略：%@", "\(error)")
            return
        }
        guard request.owner == Self.owner else { return }

        let markdownTransfer = request.action == .exportMarkdown
            ? CodexMarkdownCDPTransfer(
                owner: request.owner,
                requestID: request.id,
                executionContextID: event.executionContextID,
                transport: transport
            )
            : nil
        do {
            try await deliverBindingResult(
                await bindingResult(
                    for: request,
                    markdownTransfer: markdownTransfer
                ),
                owner: request.owner,
                requestID: request.id,
                executionContextID: event.executionContextID,
                transport: transport
            )
        } catch {
            // 结果投递失败只影响该请求：socket 层故障会让 reader 循环自行
            // 结束并重连，这里不再主动拆会话。
            NSLog(
                "CodexTokenBar: 会话增强结果投递失败（%@）：%@",
                request.id,
                "\(error)"
            )
        }
    }

    private func deliverBindingResult(
        _ result: CodexThreadDeleteBindingResult,
        owner: String,
        requestID: String,
        executionContextID: Int?,
        transport: CodexThreadDeleteCDPTransport
    ) async throws {
        let expression = try CodexThreadDeleteInjectionScript.resolveExpression(
            owner: owner,
            requestID: requestID,
            result: result
        )
        let response = try await transport.request(
            method: "Runtime.evaluate",
            params: CodexThreadDeleteCDPEvaluateParameters(
                expression: expression,
                returnByValue: true,
                contextId: executionContextID
            )
        )
        // 页面明确返回 false 表示对应回调已不存在（页面刷新、请求已超时或
        // 已被乱序分块判失败）。这是陈旧回执，不是传输故障，拆桥重连反而
        // 殃及同页面其他挂起请求，因此只记录。
        do {
            try response.acknowledgedBoolean(method: "会话增强结果")
        } catch {
            NSLog(
                "CodexTokenBar: 会话增强结果未被页面接收（回执可能已过期）：%@",
                requestID
            )
        }
    }

    private func bindingResult(
        for request: CodexThreadDeleteBindingRequest,
        markdownTransfer: CodexMarkdownCDPTransfer?
    ) async -> CodexThreadDeleteBindingResult {
        do {
            try CodexThreadID.validate(request.threadID)
            switch request.action {
            case .delete:
                // 与 Tauri 端一致：原生侧复查设置，被注入页面无法调用已关闭
                // 的动作（页面按钮门禁只是 UX，不是安全边界）。
                guard enhancementSettings.sessionDelete else {
                    throw CodexThreadDeleteError.commandFailed("会话删除未启用")
                }
                let message = try await executor.delete(threadID: request.threadID)
                return CodexThreadDeleteBindingResult(status: "deleted", message: message)
            case .exportMarkdown:
                guard enhancementSettings.markdownExport else {
                    throw CodexThreadDeleteError.commandFailed("Markdown 导出未启用")
                }
                guard let markdownTransfer else {
                    throw CodexThreadDeleteError.injectionVerificationFailed(
                        "Markdown 流式传输未初始化"
                    )
                }
                let export = try await enhancementExecutor.exportMarkdown(
                    threadID: request.threadID,
                    fallbackTitle: request.title,
                    emit: { chunk in
                        try await markdownTransfer.write(chunk)
                    }
                )
                return CodexThreadDeleteBindingResult(
                    status: "exported",
                    message: export.message,
                    filename: export.filename,
                    markdownTransfer: true,
                    markdownChunkCount: try await markdownTransfer.finishTransfer()
                )
            case .moveThreadWorkspace:
                guard enhancementSettings.projectMove else {
                    throw CodexThreadDeleteError.commandFailed("会话项目移动未启用")
                }
                guard let targetCwd = request.targetCwd?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !targetCwd.isEmpty else {
                    throw CodexSessionEnhancementBackendError.invalidTargetDirectory("")
                }
                let move = try await enhancementExecutor.moveThreadWorkspace(
                    threadID: request.threadID,
                    targetCwd: targetCwd
                )
                return CodexThreadDeleteBindingResult(
                    status: "moved",
                    message: move.message,
                    previousCwd: move.previousCwd,
                    targetCwd: move.targetCwd
                )
            }
        } catch {
            return CodexThreadDeleteBindingResult(
                status: "failed",
                message: error.localizedDescription
            )
        }
    }
}

struct CodexThreadDeleteTarget: Equatable, Sendable {
    let port: Int
    let webSocketURL: URL
}

enum CodexThreadDeleteWebSocketRequest {
    static func make(for target: CodexThreadDeleteTarget) -> URLRequest {
        // Chromium 150 rejects an explicit browser-style Origin unless Codex is
        // launched with --remote-allow-origins. A native loopback CDP client
        // should omit Origin; the target URL itself is already restricted to
        // ws://127.0.0.1 or ws://[::1] by target validation below.
        URLRequest(url: target.webSocketURL)
    }
}

private struct CodexThreadDeleteTargetPayload: Decodable {
    let type: String
    let title: String?
    let url: String?
    let webSocketDebuggerUrl: URL?

    func target(port: Int) -> CodexThreadDeleteTarget? {
        let title = (title ?? "").lowercased()
        let pageURL = (url ?? "").lowercased()
        guard type == "page",
              !pageURL.hasPrefix("devtools://"),
              pageURL.hasPrefix("app://") || title.contains("codex") || title.contains("chatgpt"),
              let webSocketDebuggerUrl,
              CodexThreadDeleteInjectionScript.isLoopback(webSocketDebuggerUrl)
        else { return nil }
        return CodexThreadDeleteTarget(port: port, webSocketURL: webSocketDebuggerUrl)
    }
}

enum CodexSessionEnhancementBindingAction: String, Decodable, Equatable, Sendable {
    case delete
    case exportMarkdown
    case moveThreadWorkspace
}

struct CodexThreadDeleteBindingRequest: Decodable, Equatable, Sendable {
    let id: String
    let owner: String
    let action: CodexSessionEnhancementBindingAction
    let threadID: String
    let title: String
    let targetCwd: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case owner
        case action
        case threadID = "threadId"
        case title
        case targetCwd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        owner = try container.decode(String.self, forKey: .owner)
        action = try container.decodeIfPresent(
            CodexSessionEnhancementBindingAction.self,
            forKey: .action
        ) ?? .delete
        threadID = try container.decode(String.self, forKey: .threadID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        targetCwd = try container.decodeIfPresent(String.self, forKey: .targetCwd)
    }
}

struct CodexThreadDeleteBindingResult: Encodable, Equatable, Sendable {
    let status: String
    let message: String
    let filename: String?
    let markdownTransfer: Bool?
    let markdownChunkCount: Int?
    let previousCwd: String?
    let targetCwd: String?

    init(
        status: String,
        message: String,
        filename: String? = nil,
        markdownTransfer: Bool? = nil,
        markdownChunkCount: Int? = nil,
        previousCwd: String? = nil,
        targetCwd: String? = nil
    ) {
        self.status = status
        self.message = message
        self.filename = filename
        self.markdownTransfer = markdownTransfer
        self.markdownChunkCount = markdownChunkCount
        self.previousCwd = previousCwd
        self.targetCwd = targetCwd
    }

}

private actor CodexMarkdownCDPTransfer {
    /// 页面把分块写入用户选择的文件后才 ACK（awaitPromise 背压），慢盘可能
    /// 远超普通 CDP 回执，因此分块请求使用独立宽超时，且超时只判本次导出
    /// 失败、不拆整条 transport；页面侧每收到一块会刷新自身超时。
    static let chunkAcknowledgementTimeout: Duration = .seconds(60)

    private let owner: String
    private let requestID: String
    private let executionContextID: Int?
    private let transport: CodexThreadDeleteCDPTransport
    private var buffer = ""
    private var bufferedCharacters = 0
    private(set) var count = 0

    init(
        owner: String,
        requestID: String,
        executionContextID: Int?,
        transport: CodexThreadDeleteCDPTransport
    ) {
        self.owner = owner
        self.requestID = requestID
        self.executionContextID = executionContextID
        self.transport = transport
    }

    func write(_ value: String) async throws {
        buffer.append(value)
        bufferedCharacters += value.count
        while bufferedCharacters
            >= CodexThreadDeleteInjectionScript.markdownTransferChunkCharacters {
            try await sendBufferedChunk()
        }
    }

    /// 冲刷缓冲余量并返回最终分块数；必须在构造 resolve 结果前调用，保证
    /// `markdownChunkCount` 与页面实际收到的块数一致。
    func finishTransfer() async throws -> Int {
        while bufferedCharacters > 0 {
            try await sendBufferedChunk()
        }
        return count
    }

    private func sendBufferedChunk() async throws {
        let chunk = String(buffer.prefix(
            CodexThreadDeleteInjectionScript.markdownTransferChunkCharacters
        ))
        buffer.removeFirst(chunk.count)
        bufferedCharacters -= chunk.count
        let sequence = count
        let expression = try CodexThreadDeleteInjectionScript
            .markdownChunkExpression(
                owner: owner,
                requestID: requestID,
                sequence: sequence,
                chunk: chunk
            )
        let response = try await transport.request(
            method: "Runtime.evaluate",
            params: CodexThreadDeleteCDPEvaluateParameters(
                expression: expression,
                returnByValue: true,
                contextId: executionContextID,
                awaitPromise: true
            ),
            timeout: Self.chunkAcknowledgementTimeout,
            timeoutClosesTransport: false
        )
        try response.acknowledgedBoolean(
            method: "Markdown 分块 \(sequence)"
        )
        count += 1
    }
}

enum CodexThreadDeleteInjectionScript {
    static let markdownTransferChunkCharacters = 16 * 1024

    static func render(
        owner: String,
        bindingName: String,
        settings: CodexSessionEnhancementSettings = .default
    ) throws -> String {
        let template = try loadTemplate()
        let enhancementTemplate = try loadEnhancementTemplate()
        let settingsData = try JSONEncoder().encode(settings.normalized)
        let settingsJSON = String(decoding: settingsData, as: UTF8.self)
        let renderedDelete = template
            .replacingOccurrences(of: "__CTB_OWNER_JSON__", with: try jsonString(owner))
            .replacingOccurrences(of: "__CTB_BINDING_JSON__", with: try jsonString(bindingName))
        return "window.__CODEX_TOKEN_BAR_SESSION_ENHANCEMENTS__ = \(settingsJSON);\n"
            + renderedDelete
            + "\n"
            + enhancementTemplate
    }

    static func resolveExpression(
        owner: String,
        requestID: String,
        result: CodexThreadDeleteBindingResult
    ) throws -> String {
        let data = try JSONEncoder().encode(result)
        return "window.__codexTokenBarThreadDeleteResolve(\(try jsonString(owner)), \(try jsonString(requestID)), \(String(decoding: data, as: UTF8.self)))"
    }

    static func markdownChunks(
        _ markdown: String,
        maximumCharacters: Int = markdownTransferChunkCharacters
    ) -> [Substring] {
        precondition(maximumCharacters > 0)
        var chunks: [Substring] = []
        chunks.reserveCapacity(
            max(1, markdown.count / maximumCharacters)
        )
        var start = markdown.startIndex
        while start < markdown.endIndex {
            let end = markdown.index(
                start,
                offsetBy: maximumCharacters,
                limitedBy: markdown.endIndex
            ) ?? markdown.endIndex
            chunks.append(markdown[start..<end])
            start = end
        }
        return chunks
    }

    static func markdownChunkExpression(
        owner: String,
        requestID: String,
        sequence: Int,
        chunk: String
    ) throws -> String {
        "window.__codexTokenBarThreadDeleteMarkdownChunk("
            + "\(try jsonString(owner)), "
            + "\(try jsonString(requestID)), "
            + "\(sequence), "
            + "\(try jsonString(chunk)))"
    }

    static func healthExpression(owner: String, bindingName: String) throws -> String {
        "window.__codexTokenBarThreadDeleteHealth(\(try jsonString(owner)), \(try jsonString(bindingName)))"
    }

    /// 桥重连后中止本 owner 遗留的 Markdown transfer：旧 native 已经消失，
    /// 页面侧的 writer 与回调若不主动收敛，会各自悬挂到超时。
    static func abortOrphanTransfersExpression(owner: String) throws -> String {
        let ownerJSON = try jsonString(owner)
        return """
        (() => {
          const state = window.__codexTokenBarThreadDeleteState;
          if (!state?.markdownTransfers) return true;
          const bridge = state.bridges?.get?.(\(ownerJSON));
          const prefix = \(ownerJSON) + "\\u0000";
          for (const [key, transfer] of [...state.markdownTransfers.entries()]) {
            if (!key.startsWith(prefix)) continue;
            state.markdownTransfers.delete(key);
            try {
              void Promise.resolve(transfer.sink?.abort?.()).catch(() => {});
            } catch {}
            bridge?.callbacks?.get?.(key.slice(prefix.length))
              ?.resolve?.({ status: "failed", message: "会话增强桥已重连，导出中止" });
          }
          return true;
        })()
        """
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme == "ws", let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    private static func loadTemplate() throws -> String {
        if let url = Bundle.main.url(
            forResource: "CodexThreadDeleteInjection",
            withExtension: "js"
        ) {
            return try String(contentsOf: url, encoding: .utf8)
        }
#if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CodexThreadDeleteInjection.js")
        return try String(contentsOf: source, encoding: .utf8)
#else
        throw CodexThreadDeleteError.injectionResourceMissing
#endif
    }

    private static func loadEnhancementTemplate() throws -> String {
        if let url = Bundle.main.url(
            forResource: "CodexSessionEnhancementsInjection",
            withExtension: "js"
        ) {
            return try String(contentsOf: url, encoding: .utf8)
        }
#if DEBUG
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CodexSessionEnhancementsInjection.js")
        return try String(contentsOf: source, encoding: .utf8)
#else
        throw CodexThreadDeleteError.injectionResourceMissing
#endif
    }

    private static func jsonString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return String(decoding: data, as: UTF8.self)
    }
}

enum CodexThreadID {
    static func validate(_ value: String) throws {
        guard UUID(uuidString: value) != nil, value.count == 36 else {
            throw CodexThreadDeleteError.invalidThreadID
        }
    }
}

protocol CodexThreadDeleteExecuting: Sendable {
    func delete(threadID: String) async throws -> String
}

struct CodexThreadDeleteSubprocessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

enum CodexThreadDeleteSubprocessError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .timeout(detail):
            return detail.isEmpty
                ? "子进程执行超时"
                : "子进程执行超时：\(detail)"
        }
    }
}

enum CodexThreadDeleteSubprocess {
    static let pipeTailBytes = 64 * 1024
    static let pipeDrainGraceSeconds: TimeInterval = 0.5

    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> CodexThreadDeleteSubprocessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        let stdout = CodexThreadDeletePipeCollector(
            handle: stdoutPipe.fileHandleForReading,
            maximumBytes: pipeTailBytes
        )
        let stderr = CodexThreadDeletePipeCollector(
            handle: stderrPipe.fileHandleForReading,
            maximumBytes: pipeTailBytes
        )
        let deadline = Date().addingTimeInterval(max(0.01, timeout))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        let output = stdout.finish(
            waitTimeout: pipeDrainGraceSeconds
        )
        let error = stderr.finish(
            waitTimeout: pipeDrainGraceSeconds
        )
        if timedOut {
            let detail = error.isEmpty ? output : error
            throw CodexThreadDeleteSubprocessError.timeout(detail)
        }
        return CodexThreadDeleteSubprocessResult(
            terminationStatus: process.terminationStatus,
            stdout: output,
            stderr: error
        )
    }
}

private final class CodexThreadDeletePipeCollector: @unchecked Sendable {
    private let group = DispatchGroup()
    private let handle: FileHandle
    private let lock = NSLock()
    private let maximumBytes: Int
    private var tail = Data()

    init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = max(0, maximumBytes)
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                do {
                    guard let data = try handle.read(upToCount: 8 * 1024),
                          !data.isEmpty else {
                        break
                    }
                    append(data)
                } catch {
                    break
                }
            }
        }
    }

    func finish(waitTimeout: TimeInterval) -> String {
        if group.wait(timeout: .now() + max(0, waitTimeout)) == .timedOut {
            try? handle.close()
            _ = group.wait(timeout: .now() + 0.1)
        }
        return lock.withLock {
            String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func append(_ data: Data) {
        guard maximumBytes > 0, !data.isEmpty else { return }
        lock.withLock {
            if data.count >= maximumBytes {
                tail = Data(data.suffix(maximumBytes))
                return
            }
            tail.append(data)
            if tail.count > maximumBytes {
                tail.removeFirst(tail.count - maximumBytes)
            }
        }
    }
}

final class FoundationCodexThreadDeleteExecutor: CodexThreadDeleteExecuting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexTokenBar.ThreadDelete")
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    func delete(threadID: String) async throws -> String {
        try CodexThreadID.validate(threadID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [timeout] in
                continuation.resume(with: Result {
                    try Self.run(threadID: threadID, timeout: timeout)
                })
            }
        }
    }

    static func commandArguments(threadID: String) -> [String] {
        ["delete", "--force", threadID]
    }

    private static func run(threadID: String, timeout: TimeInterval) throws -> String {
        try CodexMultiInstanceMutationGate.ensureNoActiveNonDefaultInstance()
        var environment = ProcessInfo.processInfo.environment
        if let dataSource = CodexDataSourceResolver().resolve() {
            environment["CODEX_HOME"] = dataSource.codexHome.path
        }
        let result: CodexThreadDeleteSubprocessResult
        do {
            result = try CodexThreadDeleteSubprocess.run(
                executableURL: URL(
                    fileURLWithPath: try CodexBinaryLocator.findExecutable()
                ),
                arguments: commandArguments(threadID: threadID),
                environment: environment,
                timeout: timeout
            )
        } catch is CodexThreadDeleteSubprocessError {
            throw CodexThreadDeleteError.timeout
        }
        guard result.terminationStatus == 0 else {
            throw CodexThreadDeleteError.commandFailed(
                result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return result.stdout.isEmpty ? "会话已永久删除" : result.stdout
    }
}

enum CodexThreadDeleteError: LocalizedError {
    case cdpCommandFailed(method: String, code: Int?, message: String)
    case cdpConnectionClosed
    case cdpEvaluationException(String)
    case cdpMalformedResponse(String)
    case cdpResponseTimeout(String)
    case commandFailed(String)
    case debugPortOccupied(Int)
    case debugPortUnavailable([Int])
    case desktopAppAmbiguous([String])
    case desktopAppIdentityUnavailable
    case desktopAppMissing
    case desktopCompetingLaunch([Int32])
    case desktopControllerConflict([String])
    case desktopDebugLaunchUnavailableInSandbox
    case desktopLaunchVerificationTimeout
    case desktopRelaunchFailed(String)
    case desktopRelaunchTransactionFailed(cause: String, recovery: String)
    case desktopTerminationRejected
    case desktopTerminationTimeout
    case injectionVerificationFailed(String)
    case injectionResourceMissing
    case invalidBindingPayload
    case invalidThreadID
    case timeout

    var errorDescription: String? {
        switch self {
        case let .cdpCommandFailed(method, code, message):
            let codeText = code.map { "（\($0)）" } ?? ""
            return "CDP 命令 \(method) 被拒绝\(codeText)：\(message)"
        case .cdpConnectionClosed:
            return "Codex 调试连接已关闭"
        case let .cdpEvaluationException(message):
            return "Codex 页面执行注入脚本失败：\(message)"
        case let .cdpMalformedResponse(method):
            return "CDP 命令 \(method) 返回了无效回执"
        case let .cdpResponseTimeout(method):
            return "等待 CDP 命令 \(method) 回执超时"
        case let .commandFailed(message):
            return "Codex 删除失败：\(message)"
        case let .debugPortOccupied(port):
            return "本机端口 \(port) 已被其他调试服务占用，为避免连接错误应用已停止重启"
        case let .debugPortUnavailable(ports):
            return "新 Codex 已启动，但本机调试端口 \(ports.map(String.init).joined(separator: "/")) 未出现，删除按钮尚未启用"
        case let .desktopAppAmbiguous(paths):
            return "检测到多个不同位置的 Codex：\(paths.joined(separator: "、"))，为避免重启错误副本已停止操作"
        case .desktopAppIdentityUnavailable:
            return "无法确认当前 Codex 的应用路径，为避免重启错误副本已停止操作"
        case .desktopAppMissing:
            return "没有找到 Codex 桌面应用"
        case let .desktopCompetingLaunch(processIdentifiers):
            return "检测到其他启动器同时打开 Codex（PID \(processIdentifiers.map(String.init).joined(separator: ", "))），删除按钮尚未启用"
        case let .desktopControllerConflict(names):
            return "\(names.joined(separator: "、")) 正在控制 Codex 启动，请先退出后重试"
        case .desktopDebugLaunchUnavailableInSandbox:
            return "当前沙盒构建无法向 Codex 传入调试参数，侧栏删除不能启用"
        case .desktopLaunchVerificationTimeout:
            return "系统没有返回新的 Codex 进程，删除按钮尚未启用"
        case let .desktopRelaunchFailed(message):
            return message.isEmpty ? "重新打开 Codex 失败" : "重新打开 Codex 失败：\(message)"
        case let .desktopRelaunchTransactionFailed(cause, recovery):
            return "调试启动失败：\(cause)；\(recovery)"
        case .desktopTerminationRejected:
            return "Codex 拒绝退出，请先保存正在编辑的内容后重试"
        case .desktopTerminationTimeout:
            return "等待 Codex 退出超时"
        case let .injectionVerificationFailed(message):
            return "页面按钮验收失败：\(message)"
        case .injectionResourceMissing:
            return "缺少 Codex 删除按钮脚本"
        case .invalidBindingPayload:
            return "Codex 页面发来的删除请求格式不兼容"
        case .invalidThreadID:
            return "会话 ID 不是有效 UUID"
        case .timeout:
            return "Codex 删除命令超时"
        }
    }
}

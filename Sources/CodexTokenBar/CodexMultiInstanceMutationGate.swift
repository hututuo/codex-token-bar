import Foundation

/// CDP 注入按钮发起的删除/移动会话作用于 Token Bar 选定的 Codex Home，而点击
/// 按钮的窗口可能属于实例管理器启动的另一个 Codex Home——克隆/同步后线程
/// UUID 相同，存在删错库/移错库风险。执行前强校验：只要存在无法排除活动
/// 嫌疑的非默认实例即拒绝执行；注册表缺失视为未启用多实例。完整方案（核对
/// CDP 目标进程的真实 CODEX_HOME）挂账。语义与 Rust 端
/// `multi_instance_mutation_block`（core/thread_delete.rs）保持一致。
enum CodexMultiInstanceMutationGate {
    static func ensureNoActiveNonDefaultInstance(
        makeEngine: () throws -> CodexInstanceEngine = { try CodexInstanceEngine() }
    ) throws {
        let engine: CodexInstanceEngine
        let snapshot: CodexInstanceRegistrySnapshot
        do {
            engine = try makeEngine()
            snapshot = try engine.listInstances()
        } catch {
            throw CodexMultiInstanceMutationGateError.registryUnavailable(error.localizedDescription)
        }
        for instance in snapshot.instances where !instance.isDefault {
            let status: CodexInstanceRuntimeStatus
            do {
                status = try engine.runtimeStatus(id: instance.id)
            } catch {
                throw CodexMultiInstanceMutationGateError.instanceActive(
                    name: instance.name,
                    detail: error.localizedDescription
                )
            }
            if status.running {
                throw CodexMultiInstanceMutationGateError.instanceActive(
                    name: instance.name,
                    detail: status.message
                )
            }
        }
    }
}

enum CodexMultiInstanceMutationGateError: LocalizedError {
    case registryUnavailable(String)
    case instanceActive(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .registryUnavailable(detail):
            return "无法确认多实例状态，删除/移动已暂停以避免作用到错误的 Codex 目录：\(detail)"
        case let .instanceActive(name, detail):
            return "Codex 实例「\(name)」可能正在运行，删除/移动已暂停：多实例下同一线程 ID 可能属于不同 Codex 目录，请先停止该实例后重试。\(detail)"
        }
    }
}

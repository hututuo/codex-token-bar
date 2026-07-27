import Darwin
import Foundation

final class CodexCrossProcessFileLock {
    private static let errorDomain = "CodexTokenBar.CrossProcessLock"
    private static let contentionErrorCode = 3

    private var descriptor: Int32

    init(
        url: URL,
        label: String,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        try finishAcquiring(label: label)
    }

    init(
        parentDirectoryDescriptor: Int32,
        fileName: String,
        label: String
    ) throws {
        descriptor = Darwin.openat(
            parentDirectoryDescriptor,
            fileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        try finishAcquiring(label: label)
    }

    private func finishAcquiring(label: String) throws {
        guard descriptor >= 0 else {
            throw Self.error(
                "打开\(label)锁失败：\(String(cString: strerror(errno)))",
                code: 1
            )
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw Self.error("收紧\(label)锁权限失败：\(detail)", code: 2)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            descriptor = -1
            throw Self.error(
                "\(label)正在由另一个 Token Bar 进程执行：\(detail)",
                code: Self.contentionErrorCode
            )
        }
    }

    static func isContention(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == errorDomain
            && error.code == contentionErrorCode
    }

    // 使用点必须 defer { release() }：仅靠 `_ = lock` 时优化器有权在函数
    // 中途就 deinit（LOCK_UN + close），Release 构建下跨进程互斥失效。
    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }

    private static func error(_ message: String, code: Int) -> NSError {
        NSError(
            domain: errorDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

typealias CodexInstanceFileLock = CodexCrossProcessFileLock

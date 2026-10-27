import Darwin
import Foundation

/// One running `/usr/bin/nettop` (METRICS 10.3). stdin is a pipe the app never writes (with `/dev/null` nettop
/// busy-loops); stdout and stderr are a pseudo-terminal (on a pipe nettop buffers until it exits). The child runs in
/// its own session with that terminal as its controlling terminal, so whenever the app dies the kernel closes the
/// master, hangs the terminal up and sends the child SIGHUP. `posix_spawn` cannot give a child a controlling
/// terminal, hence fork and exec with only async-signal-safe calls in between. Confined to one queue.
final class NettopChild {
    static let path = "/usr/bin/nettop"

    enum LaunchError: Error, Equatable {
        case missing
        case failed(Int32)
    }

    let pid: pid_t
    let interval: Int
    /// The pseudo-terminal master (non-blocking): nettop's output.
    let output: Int32
    private let stdinWriter: Int32
    private var terminated = false

    private init(pid: pid_t, interval: Int, output: Int32, stdinWriter: Int32) {
        self.pid = pid
        self.interval = interval
        self.output = output
        self.stdinWriter = stdinWriter
    }

    deinit { terminate() }

    static var isAvailable: Bool { access(path, X_OK) == 0 }

    static func arguments(interval: Int) -> [String] {
        ["nettop", "-P", "-L", "0", "-s", String(interval), "-x", "-n", "-t", "external", "-J", "bytes_in,bytes_out"]
    }

    static func launch(interval: Int) throws -> NettopChild {
        guard isAvailable else { throw LaunchError.missing }
        guard let fork = forkFunction else { throw LaunchError.failed(ENOSYS) }
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { throw LaunchError.failed(errno) }
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            let code = errno
            close(pipeEnds[0])
            close(pipeEnds[1])
            throw LaunchError.failed(code)
        }
        for fd in [pipeEnds[0], pipeEnds[1], master, slave] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        // Everything the child touches is prepared before fork.
        let argv = CStringArray(arguments(interval: interval))
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        let envp = CStringArray(environment.map { "\($0.key)=\($0.value)" })
        let executable = CStringArray([path])
        let inherited = openDescriptors()
        let sweepLimit = min(max(getdtablesize(), 256), 4096)
        let stdinReader = pipeEnds[0]
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        let request = controllingTerminalRequest

        let pid = fork()
        if pid == 0 {
            _ = setsid()
            _ = ioctl(slave, request, 0)
            _ = dup2(stdinReader, 0)
            _ = dup2(slave, 1)
            _ = dup2(slave, 2)
            _ = signal(SIGHUP, SIG_DFL)
            _ = signal(SIGINT, SIG_DFL)
            _ = signal(SIGQUIT, SIG_DFL)
            _ = signal(SIGPIPE, SIG_DFL)
            _ = signal(SIGTERM, SIG_DFL)
            _ = signal(SIGCHLD, SIG_DFL)
            _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
            var fd: Int32 = 3
            while fd < sweepLimit {
                _ = close(fd)
                fd += 1
            }
            var index = 0
            while index < inherited.count {
                if inherited.pointer[index] > 2 { _ = close(inherited.pointer[index]) }
                index += 1
            }
            _ = execve(executable.pointers[0], argv.pointers, envp.pointers)
            _exit(127)
        }
        let code = errno
        close(stdinReader)
        close(slave)
        guard pid > 0 else {
            close(master)
            close(pipeEnds[1])
            throw LaunchError.failed(code)
        }
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        return NettopChild(pid: pid, interval: interval, output: master, stdinWriter: pipeEnds[1])
    }

    /// Kills the child's process group, reaps it and closes both descriptors. Idempotent.
    func terminate() {
        guard !terminated else { return }
        terminated = true
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}
        close(output)
        close(stdinWriter)
    }

    /// `fork` through its C symbol (Swift marks it unavailable).
    private static let forkFunction: (@convention(c) () -> pid_t)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fork") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> pid_t).self)
    }()

    /// `TIOCSCTTY` (`_IO('t', 97)`), which Swift does not import.
    private static let controllingTerminalRequest: UInt = 0x2000_7461

    /// This process's open descriptors, so the child can close them all before exec.
    private static func openDescriptors() -> DescriptorList {
        let pid = getpid()
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        guard needed > 0 else { return DescriptorList([]) }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return DescriptorList([]) }
        return DescriptorList(fds.prefix(Int(bytes) / stride).map(\.proc_fd))
    }
}

/// A NULL-terminated C string array allocated before fork.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() { pointers[index] = strdup(string) }
        pointers[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}

/// Descriptor numbers in plain memory, readable after fork without the Swift runtime.
private final class DescriptorList {
    let pointer: UnsafeMutablePointer<Int32>
    let count: Int

    init(_ descriptors: [Int32]) {
        count = descriptors.count
        pointer = .allocate(capacity: max(descriptors.count, 1))
        for (index, fd) in descriptors.enumerated() { pointer[index] = fd }
    }

    deinit { pointer.deallocate() }
}

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var output: String
    public var timedOut: Bool
    public var cancelled: Bool
    public var duration: TimeInterval
}

/// Runs shell commands inside a POSIX pseudo-terminal so tools that check `isatty`
/// (test runners, compilers with colour output, progress bars) behave as in a real terminal.
/// Output is streamed chunk-by-chunk and the whole process group is killed on timeout.
public final class PTYExecutor: @unchecked Sendable {
    public static let shared = PTYExecutor()
    private let lock = NSLock()
    private var running: [UUID: pid_t] = [:]

    public init() {}

    public static var defaultShell: String {
        for s in ["/bin/zsh", "/bin/bash", "/bin/sh"] where FileManager.default.isExecutableFile(atPath: s) { return s }
        return "/bin/sh"
    }

    /// Cancel every running command (process group SIGTERM, then SIGKILL).
    public func cancelAll() {
        lock.lock(); let pids = Array(running.values); lock.unlock()
        for pid in pids { Self.killGroup(pid) }
    }

    public func run(command: String,
                    cwd: URL,
                    timeout: TimeInterval = 120,
                    environment extraEnv: [String: String] = [:],
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> CommandResult {
        await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            let t = Thread { [self] in
                cont.resume(returning: self.runBlocking(command: command, cwd: cwd, timeout: timeout, extraEnv: extraEnv, onOutput: onOutput))
            }
            t.stackSize = 1 << 20
            t.start()
        }
    }

    static func killGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    private func runBlocking(command: String, cwd: URL, timeout: TimeInterval,
                             extraEnv: [String: String], onOutput: (@Sendable (String) -> Void)?) -> CommandResult {
        let started = Date()
        var master: Int32 = -1, slave: Int32 = -1
        var ws = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else {
            return CommandResult(exitCode: -1, output: "openpty failed: errno \(errno)", timedOut: false, cancelled: false, duration: 0)
        }

        // Environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["AGCODE"] = "1"
        for (k, v) in extraEnv { env[k] = v }
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        // The cwd is applied by the shell to stay portable across posix_spawn implementations.
        let script = "cd \(Self.shellQuote(cwd.path)) && \(command)"
        let shell = Self.defaultShell
        let args = [shell, "-c", script]

        #if canImport(Darwin)
        // On Darwin these are opaque pointers that the *_init calls allocate.
        var fa: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #else
        var fa = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_adddup2(&fa, slave, 0)
        posix_spawn_file_actions_adddup2(&fa, slave, 1)
        posix_spawn_file_actions_adddup2(&fa, slave, 2)
        posix_spawn_file_actions_addclose(&fa, master)
        posix_spawn_file_actions_addclose(&fa, slave)
        posix_spawnattr_init(&attr)
        // New process group so the whole tree can be killed on timeout.
        posix_spawnattr_setpgroup(&attr, 0)
        #if canImport(Darwin)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        #else
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        #endif

        var pid: pid_t = 0
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = envStrings.map { strdup($0) } + [nil]
        let rc = posix_spawn(&pid, shell, &fa, &attr, cArgs, cEnv)
        cArgs.forEach { free($0) }
        cEnv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        close(slave)
        guard rc == 0 else {
            close(master)
            return CommandResult(exitCode: -1, output: "posix_spawn failed: \(rc)", timedOut: false, cancelled: false, duration: 0)
        }

        let id = UUID()
        lock.lock(); running[id] = pid; lock.unlock()
        defer { lock.lock(); running[id] = nil; lock.unlock() }

        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        let deadline = started.addingTimeInterval(timeout)
        var timedOut = false
        var exitStatus: Int32 = 0
        var exited = false

        while true {
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 100)
            if pr > 0 {
                let n = read(master, &buf, buf.count)
                if n > 0 {
                    let chunk = Data(buf[0..<n])
                    collected.append(chunk)
                    onOutput?(String(decoding: chunk, as: UTF8.self))
                    continue
                } else if exited || n <= 0 {
                    // EOF / EIO: all slave handles closed.
                    if !exited { var st: Int32 = 0; waitpid(pid, &st, 0); exitStatus = st; exited = true }
                    break
                }
            }
            if !exited {
                var st: Int32 = 0
                let w = waitpid(pid, &st, WNOHANG)
                if w == pid { exited = true; exitStatus = st }
            }
            if exited && pr <= 0 { break }
            if Date() > deadline && !timedOut {
                timedOut = true
                Self.killGroup(pid)
                onOutput?("\n[agcode] command timed out after \(Int(timeout))s — process group terminated\n")
            }
            if timedOut && Date() > deadline.addingTimeInterval(5) { break }
        }
        close(master)
        if !exited { var st: Int32 = 0; waitpid(pid, &st, 0); exitStatus = st }

        let code: Int32
        if (exitStatus & 0x7f) == 0 { code = (exitStatus >> 8) & 0xff } else { code = 128 + (exitStatus & 0x7f) }
        let text = Self.stripANSI(String(decoding: collected, as: UTF8.self)).replacingOccurrences(of: "\r\n", with: "\n")
        return CommandResult(exitCode: code, output: text, timedOut: timedOut, cancelled: false, duration: Date().timeIntervalSince(started))
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func stripANSI(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\u{1B}(\\[[0-9;?]*[ -/]*[@-~]|\\][^\u{07}]*\u{07}|[()][0-9A-B])", options: []) else { return s }
        let r = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: "")
    }
}

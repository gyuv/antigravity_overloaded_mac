import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var output: String
    public var timedOut: Bool
}

/// Small helper for running non-interactive helper processes (git, rg).
public enum Shell {
    public static func run(_ executable: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 60) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var data = Data()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); data.append(chunk); lock.unlock()
        }
        do { try p.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(exitCode: -1, output: "failed to launch \(executable): \(error)", timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() > deadline { p.terminate(); timedOut = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); data.append(rest); let out = String(decoding: data, as: UTF8.self); lock.unlock()
        return ProcessResult(exitCode: p.terminationStatus, output: out, timedOut: timedOut)
    }

    /// Resolve an executable on PATH (falls back to common locations).
    public static func which(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = env.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for d in dirs {
            let path = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    public static var git: String { which("git") ?? "/usr/bin/git" }
}

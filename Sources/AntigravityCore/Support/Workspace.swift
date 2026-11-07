import Foundation

public enum WorkspaceError: Error, LocalizedError {
    case outsideWorkspace(String)
    case notFound(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let p): return "Path escapes the workspace sandbox: \(p)"
        case .notFound(let p): return "Not found: \(p)"
        case .invalidArgument(let m): return "Invalid argument: \(m)"
        }
    }
}

/// The directory anchor for a session. All file tools are confined to `root`.
public struct Workspace: Sendable {
    public let root: URL
    public let isGitRepo: Bool

    public init(path: String) {
        let start = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let r = Shell.run(Shell.git, ["rev-parse", "--show-toplevel"], cwd: start, timeout: 10)
        if r.exitCode == 0, !r.timedOut {
            let top = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            root = URL(fileURLWithPath: top).standardizedFileURL
            isGitRepo = true
        } else {
            root = start
            isGitRepo = false
        }
    }

    /// Resolve a user/agent supplied path and make sure it stays inside the workspace.
    public func resolve(_ path: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : root.appendingPathComponent(expanded)
        let std = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootStd = root.resolvingSymlinksInPath().path
        let p = std.path
        guard p == rootStd || p.hasPrefix(rootStd.hasSuffix("/") ? rootStd : rootStd + "/") else {
            throw WorkspaceError.outsideWorkspace(path)
        }
        return std
    }

    public func relative(_ url: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().path
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        if p == rootPath { return "." }
        if p.hasPrefix(rootPath + "/") { return String(p.dropFirst(rootPath.count + 1)) }
        return p
    }

    /// Project-specific instructions from ANTIGRAVITY.md / AGENTS.md / CLAUDE.md at the root.
    public func memoryInstructions() -> String? {
        var chunks: [String] = []
        for name in ["ANTIGRAVITY.md", "AGENTS.md", "CLAUDE.md"] {
            let u = root.appendingPathComponent(name)
            if let s = try? String(contentsOf: u, encoding: .utf8), !s.isEmpty {
                chunks.append("# \(name)\n\(s)")
            }
        }
        return chunks.isEmpty ? nil : chunks.joined(separator: "\n\n")
    }

    /// Files tracked or untracked-but-not-ignored. Respects .gitignore when inside a repo.
    public func listFiles(under sub: URL? = nil, limit: Int = 20_000) -> [String] {
        let base = sub ?? root
        if isGitRepo {
            let r = Shell.run(Shell.git, ["ls-files", "--cached", "--others", "--exclude-standard", "--", relative(base)], cwd: root, timeout: 30)
            if r.exitCode == 0 {
                return Array(r.output.split(separator: "\n").map(String.init).prefix(limit))
            }
        }
        var out: [String] = []
        let skip: Set<String> = [".git", "node_modules", ".build", "DerivedData", "build", "dist", ".venv", "__pycache__"]
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        for case let u as URL in e {
            if skip.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { out.append(relative(u)); if out.count >= limit { break } }
        }
        return out.sorted()
    }
}

import Foundation

public enum GlobMatcher {
    /// Convert a glob (supports **, *, ?, {a,b}) into an anchored regex.
    public static func regex(for glob: String) -> String {
        var r = "^"
        var i = glob.startIndex
        var inBrace = false
        while i < glob.endIndex {
            let ch = glob[i]
            switch ch {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    let after = glob.index(after: next)
                    if after < glob.endIndex, glob[after] == "/" { r += "(?:.*/)?"; i = glob.index(after: after); continue }
                    r += ".*"; i = after; continue
                }
                r += "[^/]*"
            case "?": r += "[^/]"
            case "{": r += "(?:"; inBrace = true
            case "}": r += ")"; inBrace = false
            case ",": r += inBrace ? "|" : ","
            case ".", "(", ")", "+", "|", "^", "$", "\\", "[", "]": r += "\\" + String(ch)
            default: r += String(ch)
            }
            i = glob.index(after: i)
        }
        return r + "$"
    }

    public static func filter(_ paths: [String], glob: String) -> [String] {
        let pattern = glob.contains("/") ? glob : "**/" + glob
        guard let re = try? NSRegularExpression(pattern: regex(for: pattern)) else { return [] }
        return paths.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }
}

public struct GlobTool: AgentTool {
    public let name = "glob"
    public let description = "Find files by glob pattern (e.g. '**/*.swift', 'src/**/*.{ts,tsx}'). Respects .gitignore."
    public var parameters: JSONValue {
        schema(["pattern": prop("string", "Glob pattern"), "path": prop("string", "Directory to search (default root)")], required: ["pattern"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .readOnly }
    public func summary(_ a: JSONValue) -> String { "Glob \(a["pattern"]?.stringValue ?? "")" }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let base = try c.workspace.resolve(a["path"]?.stringValue ?? ".")
        let files = c.workspace.listFiles(under: base)
        let prefix = c.workspace.relative(base)
        let rel = prefix == "." ? files : files.map { $0.hasPrefix(prefix + "/") ? String($0.dropFirst(prefix.count + 1)) : $0 }
        let hits = GlobMatcher.filter(rel, glob: try req(a, "pattern")).map { prefix == "." ? $0 : prefix + "/" + $0 }
        if hits.isEmpty { return "No files matched." }
        return hits.prefix(500).joined(separator: "\n") + (hits.count > 500 ? "\n… \(hits.count - 500) more" : "")
    }
}

public struct GrepTool: AgentTool {
    public let name = "grep"
    public let description = "Regex search across file contents (ripgrep when available). Returns path:line:text matches. Respects .gitignore."
    public var parameters: JSONValue {
        schema(["pattern": prop("string", "Regular expression"),
                "path": prop("string", "Directory or file to search (default root)"),
                "glob": prop("string", "Only search files matching this glob, e.g. '*.swift'"),
                "case_insensitive": prop("boolean", "Ignore case"),
                "max_results": prop("integer", "Maximum matches (default 200)")], required: ["pattern"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .readOnly }
    public func summary(_ a: JSONValue) -> String { "Grep /\(a["pattern"]?.stringValue ?? "")/" }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let pattern = try req(a, "pattern")
        let base = try c.workspace.resolve(a["path"]?.stringValue ?? ".")
        let maxResults = a["max_results"]?.intValue ?? 200
        let ci = a["case_insensitive"]?.boolValue ?? false
        if let rg = Shell.which("rg") {
            var args = ["--line-number", "--no-heading", "--color", "never", "--max-columns", "300", "-m", "50"]
            if ci { args.append("-i") }
            if let g = a["glob"]?.stringValue { args += ["--glob", g] }
            args += ["--", pattern, c.workspace.relative(base)]
            let r = Shell.run(rg, args, cwd: c.workspace.root, timeout: 30)
            if r.exitCode == 1 { return "No matches." }
            let lines = r.output.split(separator: "\n", omittingEmptySubsequences: true)
            return lines.prefix(maxResults).joined(separator: "\n") + (lines.count > maxResults ? "\n… \(lines.count - maxResults) more matches" : "")
        }
        // Built-in fallback.
        guard let re = try? NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : []) else {
            throw WorkspaceError.invalidArgument("invalid regex")
        }
        var files = c.workspace.listFiles(under: base)
        if let g = a["glob"]?.stringValue { files = GlobMatcher.filter(files, glob: g) }
        var out: [String] = []
        for f in files {
            let u = c.workspace.root.appendingPathComponent(f)
            guard let data = FileManager.default.contents(atPath: u.path), data.count < 2_000_000, !data.prefix(4000).contains(0) else { continue }
            for (i, line) in String(decoding: data, as: UTF8.self).components(separatedBy: "\n").enumerated()
            where re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                out.append("\(f):\(i + 1):\(line.prefix(300))")
                if out.count >= maxResults { return out.joined(separator: "\n") + "\n… (limit reached)" }
            }
        }
        return out.isEmpty ? "No matches." : out.joined(separator: "\n")
    }
}

/// Lightweight structural outline (types, functions) for fast multi-file context gathering.
public struct OutlineTool: AgentTool {
    public let name = "outline"
    public let description = "Extract a symbol outline (classes, structs, functions, methods) of one or more files without reading their bodies."
    public var parameters: JSONValue {
        schema(["paths": ["type": "array", "items": ["type": "string"], "description": "Files to outline (or a single directory)"]], required: ["paths"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .readOnly }
    public func summary(_ a: JSONValue) -> String { "Outline \(a["paths"]?.arrayValue?.count ?? 0) path(s)" }

    static let patterns: [String: String] = [
        "swift": #"^\s*(?:@\w+\s+)*(?:(?:public|private|fileprivate|internal|open|final|static|override|mutating|nonisolated)\s+)*(class|struct|enum|protocol|extension|actor|func|init|typealias)\b.*"#,
        "py": #"^\s*(class|def|async def)\s+\w+.*"#,
        "js": #"^\s*(export\s+)?(default\s+)?(async\s+)?(function|class|const\s+\w+\s*=\s*(async\s*)?\(|interface|type)\b.*"#,
        "go": #"^(func|type)\s+.*"#,
        "rs": #"^\s*(pub(\(\w+\))?\s+)?(fn|struct|enum|trait|impl|mod|type)\b.*"#,
        "java": #"^\s*(public|private|protected)?\s*(static\s+)?(final\s+)?(class|interface|enum|record|[\w<>\[\]]+\s+\w+\s*\().*"#,
        "c": #"^[A-Za-z_][\w\s\*]*\s+\**\w+\s*\([^;]*$|^\s*(struct|class|enum|namespace)\s+\w+.*"#,
        "rb": #"^\s*(class|module|def)\s+.*"#,
    ]
    static func lang(_ ext: String) -> String? {
        switch ext {
        case "swift": return "swift"
        case "py": return "py"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return "js"
        case "go": return "go"
        case "rs": return "rs"
        case "java", "kt", "kts", "scala", "cs": return "java"
        case "c", "h", "cc", "cpp", "hpp", "m", "mm": return "c"
        case "rb": return "rb"
        default: return nil
        }
    }

    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        var paths = (a["paths"]?.arrayValue ?? []).compactMap(\.stringValue)
        if paths.count == 1, let u = try? c.workspace.resolve(paths[0]),
           (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            paths = Array(c.workspace.listFiles(under: u).filter { Self.lang(($0 as NSString).pathExtension) != nil }.prefix(60))
        }
        var out = ""
        for p in paths.prefix(60) {
            let u = try c.workspace.resolve(p)
            guard let lang = Self.lang(u.pathExtension), let pat = Self.patterns[lang],
                  let re = try? NSRegularExpression(pattern: pat),
                  let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
            out += "## \(c.workspace.relative(u))\n"
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                out += String(format: "%5d  ", i + 1) + line.trimmingCharacters(in: .whitespaces).prefix(200) + "\n"
            }
        }
        return out.isEmpty ? "No outline available." : clip(out)
    }
}

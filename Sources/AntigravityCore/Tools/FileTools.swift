import Foundation

public struct ReadFileTool: AgentTool {
    public let name = "read_file"
    public let description = "Read a text file from the workspace. Returns numbered lines. Use offset/limit (1-based line numbers) for large files."
    public var parameters: JSONValue {
        schema(["path": prop("string", "File path relative to the workspace root"),
                "offset": prop("integer", "First line to read (1-based). Default 1"),
                "limit": prop("integer", "Maximum number of lines. Default 2000")], required: ["path"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .readOnly }
    public func summary(_ a: JSONValue) -> String { "Read \(a["path"]?.stringValue ?? "?")" }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let url = try c.workspace.resolve(try req(a, "path"))
        guard let data = FileManager.default.contents(atPath: url.path) else { throw WorkspaceError.notFound(url.path) }
        if data.prefix(8000).contains(0) { return "(binary file, \(data.count) bytes)" }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let offset = max(1, a["offset"]?.intValue ?? 1)
        let limit = max(1, a["limit"]?.intValue ?? 2000)
        guard offset <= lines.count else { return "(file has \(lines.count) lines; offset \(offset) is past the end)" }
        let end = min(lines.count, offset - 1 + limit)
        var out = ""
        for i in (offset - 1)..<end {
            let l = lines[i].count > 2000 ? String(lines[i].prefix(2000)) + "…" : lines[i]
            out += String(format: "%6d\t", i + 1) + l + "\n"
        }
        if end < lines.count { out += "… (\(lines.count - end) more lines; use offset=\(end + 1))\n" }
        return out
    }
}

public struct WriteFileTool: AgentTool {
    public let name = "write_file"
    public let description = "Create or overwrite a file with the given full content. Prefer patch_file for edits to existing files."
    public var parameters: JSONValue {
        schema(["path": prop("string", "File path relative to the workspace root"),
                "content": prop("string", "Complete new file content")], required: ["path", "content"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .write }
    public func summary(_ a: JSONValue) -> String { "Write \(a["path"]?.stringValue ?? "?")" }
    public func preview(_ a: JSONValue, _ c: ToolContext) throws -> FileDiff? {
        let url = try c.workspace.resolve(try req(a, "path"))
        let old = try? String(contentsOf: url, encoding: .utf8)
        return Differ.diff(path: c.workspace.relative(url), old: old, new: try req(a, "content"))
    }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let url = try c.workspace.resolve(try req(a, "path"))
        let content = try req(a, "content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.utf8.count) bytes to \(c.workspace.relative(url))"
    }
}

public struct PatchFileTool: AgentTool {
    public let name = "patch_file"
    public let description = """
    Edit an existing file. Either pass `diff` (a unified diff with @@ hunks; context lines are validated \
    and hunks may float if line numbers are slightly off) OR pass `old_text` + `new_text` for an exact, unique \
    search-and-replace (set replace_all to replace every occurrence).
    """
    public var parameters: JSONValue {
        schema(["path": prop("string", "File path relative to the workspace root"),
                "diff": prop("string", "Unified diff to apply"),
                "old_text": prop("string", "Exact text to replace"),
                "new_text": prop("string", "Replacement text"),
                "replace_all": prop("boolean", "Replace all occurrences of old_text")], required: ["path"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .write }
    public func summary(_ a: JSONValue) -> String { "Patch \(a["path"]?.stringValue ?? "?")" }

    func patched(_ a: JSONValue, _ c: ToolContext) throws -> (URL, String, String) {
        let url = try c.workspace.resolve(try req(a, "path"))
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { throw WorkspaceError.notFound(url.path) }
        let result: String
        if let d = a["diff"]?.stringValue, !d.isEmpty {
            result = try Differ.apply(unifiedDiff: d, to: original)
        } else if let old = a["old_text"]?.stringValue {
            result = try Differ.replace(in: original, old: old, new: a["new_text"]?.stringValue ?? "", replaceAll: a["replace_all"]?.boolValue ?? false)
        } else {
            throw WorkspaceError.invalidArgument("provide either 'diff' or 'old_text'/'new_text'")
        }
        return (url, original, result)
    }
    public func preview(_ a: JSONValue, _ c: ToolContext) throws -> FileDiff? {
        let (url, o, n) = try patched(a, c)
        return Differ.diff(path: c.workspace.relative(url), old: o, new: n)
    }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let (url, o, n) = try patched(a, c)
        try n.write(to: url, atomically: true, encoding: .utf8)
        let d = Differ.diff(path: c.workspace.relative(url), old: o, new: n)
        return "Patched \(d.path): +\(d.additions) -\(d.deletions)"
    }
}

public struct ListDirTool: AgentTool {
    public let name = "list_dir"
    public let description = "List a directory. With recursive=true lists all files below it (respecting .gitignore)."
    public var parameters: JSONValue {
        schema(["path": prop("string", "Directory relative to workspace root (default '.')"),
                "recursive": prop("boolean", "List recursively")], required: [])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .readOnly }
    public func summary(_ a: JSONValue) -> String { "List \(a["path"]?.stringValue ?? ".")" }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let url = try c.workspace.resolve(a["path"]?.stringValue ?? ".")
        if a["recursive"]?.boolValue == true {
            let files = c.workspace.listFiles(under: url, limit: 2000)
            return files.isEmpty ? "(empty)" : files.joined(separator: "\n") + (files.count >= 2000 ? "\n… (truncated)" : "")
        }
        let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { u -> String in
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return v?.isDirectory == true ? u.lastPathComponent + "/" : "\(u.lastPathComponent)  (\(v?.fileSize ?? 0) B)"
        }.joined(separator: "\n")
    }
}

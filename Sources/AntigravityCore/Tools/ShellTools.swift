import Foundation

public struct ExecuteBashTool: AgentTool {
    public let name = "execute_bash"
    public let description = """
    Run a shell command in a pseudo-terminal at the workspace root (or `cwd`). Use for builds, tests, \
    scripts and inspection. Output is streamed to the user and returned (truncated if very long). \
    Commands are killed after `timeout_seconds` (default 120, max 1800). Do not start interactive programs.
    """
    public var parameters: JSONValue {
        schema(["command": prop("string", "Shell command"),
                "cwd": prop("string", "Working directory relative to workspace root"),
                "timeout_seconds": prop("integer", "Timeout in seconds")], required: ["command"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { PermissionEngine.classify(command: a["command"]?.stringValue ?? "") }
    public func summary(_ a: JSONValue) -> String { "$ \(a["command"]?.stringValue ?? "")" }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let cmd = try req(a, "command")
        let cwd = try c.workspace.resolve(a["cwd"]?.stringValue ?? ".")
        let timeout = TimeInterval(min(1800, max(1, a["timeout_seconds"]?.intValue ?? Int(c.commandTimeout))))
        let r = await c.executor.run(command: cmd, cwd: cwd, timeout: timeout, onOutput: c.onOutput)
        var s = clip(r.output)
        if s.isEmpty { s = "(no output)" }
        s += "\n[exit code \(r.exitCode)\(r.timedOut ? ", TIMED OUT" : "") in \(String(format: "%.1f", r.duration))s]"
        return s
    }
}

public struct GitActionTool: AgentTool {
    public let name = "git_action"
    public let description = """
    Run a git operation in the workspace repository. action is one of: status, diff, log, show, branch, \
    checkout, switch, add, restore_staged, commit, stash, blame, current_branch. `args` are extra arguments \
    (e.g. ["--staged"], ["-b","feature/x"], ["-m","message"]).
    """
    public var parameters: JSONValue {
        schema(["action": prop("string", "Git action"),
                "args": ["type": "array", "items": ["type": "string"], "description": "Extra arguments"]], required: ["action"])
    }
    static let readOnly: Set<String> = ["status", "diff", "log", "show", "blame", "current_branch"]
    static let allowed: [String: [String]] = [
        "status": ["status", "--short", "--branch"], "diff": ["diff"], "log": ["log", "--oneline", "-n", "30"],
        "show": ["show", "--stat"], "branch": ["branch"], "checkout": ["checkout"], "switch": ["switch"], "add": ["add"],
        "restore_staged": ["restore", "--staged"], "commit": ["commit"], "stash": ["stash"], "blame": ["blame"],
        "current_branch": ["rev-parse", "--abbrev-ref", "HEAD"],
    ]
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel {
        let action = a["action"]?.stringValue ?? ""
        let extra = (a["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        if Self.readOnly.contains(action) { return .readOnly }
        if action == "branch" && extra.isEmpty { return .readOnly }
        if action == "branch" && extra.contains(where: { $0 == "-D" || $0 == "-d" || $0 == "--delete" }) { return .destructive }
        if action == "checkout" && extra.contains("--") { return .destructive }
        if action == "stash" && extra.contains(where: { $0 == "drop" || $0 == "clear" }) { return .destructive }
        return .write
    }
    public func summary(_ a: JSONValue) -> String {
        "git \(a["action"]?.stringValue ?? "") \((a["args"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " "))"
    }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        guard c.workspace.isGitRepo else { return "Not a git repository. (Use execute_bash with `git init` if appropriate.)" }
        let action = try req(a, "action")
        guard let base = Self.allowed[action] else {
            throw WorkspaceError.invalidArgument("unsupported git action '\(action)'. Allowed: \(Self.allowed.keys.sorted().joined(separator: ", "))")
        }
        let extra = (a["args"]?.arrayValue ?? []).compactMap(\.stringValue)
        let r = Shell.run(Shell.git, ["-c", "color.ui=never", "--no-pager"] + base + extra, cwd: c.workspace.root, timeout: 120)
        return clip(r.output.isEmpty ? "(no output)" : r.output) + (r.exitCode == 0 ? "" : "\n[git exited with \(r.exitCode)]")
    }
}

/// Lets the agent publish a structured task checklist that the UI renders as an artifact.
public struct UpdatePlanTool: AgentTool {
    public let name = "update_plan"
    public let description = "Publish or update the task checklist for the current request. Send the full list every time; statuses: pending, in_progress, completed, failed."
    public var parameters: JSONValue {
        schema(["items": ["type": "array", "description": "Checklist items",
                          "items": schema(["title": prop("string", "Task"), "status": prop("string", "pending|in_progress|completed|failed")],
                                          required: ["title", "status"])]], required: ["items"])
    }
    public init() {}
    public func risk(_ a: JSONValue, _ c: ToolContext) -> RiskLevel { .readOnly }
    public func summary(_ a: JSONValue) -> String { "Update plan" }
    public func run(_ a: JSONValue, _ c: ToolContext) async throws -> String {
        let items = (a["items"]?.arrayValue ?? []).compactMap { v -> PlanItem? in
            guard let t = v["title"]?.stringValue else { return nil }
            return PlanItem(title: t, status: PlanItem.Status(rawValue: v["status"]?.stringValue ?? "pending") ?? .pending)
        }
        c.onPlan(items)
        return "Plan updated (\(items.filter { $0.status == .completed }.count)/\(items.count) done)."
    }
}

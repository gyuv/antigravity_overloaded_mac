import Foundation

public enum ToolStatus: String, Sendable { case awaitingApproval, running, succeeded, failed, denied }

/// Everything the UI / CLI needs to render a live session.
public enum AgentEvent: Sendable {
    case turnStarted(Int)
    case thinking(String)
    case text(String)
    case toolCall(id: UUID, name: String, summary: String, args: JSONValue, risk: RiskLevel, diff: FileDiff?)
    case toolOutput(id: UUID, chunk: String)
    case toolFinished(id: UUID, status: ToolStatus, result: String)
    case plan([PlanItem])
    case usage(prompt: Int, output: Int)
    case error(String)
    case finished(reason: String)
}

/// Asked whenever the permission engine requires explicit consent.
public typealias ApprovalHandler = @Sendable (PermissionRequest) async -> PermissionDecision

/// The multi-turn ReAct loop: send history → stream thoughts/text/function calls →
/// gate each call through the permission engine → execute locally → feed results back.
public actor AgentSession {
    public let workspace: Workspace
    public private(set) var config: AgentConfig
    public private(set) var history: [GeminiContent] = []
    public private(set) var permissions: PermissionEngine
    private let registry: ToolRegistry
    private let executor = PTYExecutor()
    private let audit: AuditLog
    private var cancelled = false

    public init(workspace: Workspace, config: AgentConfig, registry: ToolRegistry = .standard, audit: AuditLog = .shared) {
        self.workspace = workspace
        self.config = config
        self.registry = registry
        self.audit = audit
        self.permissions = PermissionEngine(mode: config.permissionMode)
    }

    public func setPermissionMode(_ m: PermissionMode) { permissions.mode = m; config.permissionMode = m }
    public func setModel(_ m: String) { config.model = m }
    public func reset() { history.removeAll(); permissions.sessionAllowedTools.removeAll() }
    public func cancel() { cancelled = true; executor.cancelAll() }

    public var systemPrompt: String {
        var s = """
        You are Antigravity Code, an autonomous software engineering agent running natively on the user's Mac.
        You operate on the repository at: \(workspace.root.path)\(workspace.isGitRepo ? " (git repository)" : "")
        Today's date: \(ISO8601DateFormatter().string(from: Date()).prefix(10)). Shell: \(PTYExecutor.defaultShell).

        Working style:
        - Investigate before you edit: use glob, grep, outline, list_dir and read_file to gather context. Read files before patching them.
        - For multi-step work, call update_plan first with a checklist and keep it current as you progress.
        - Make focused edits with patch_file (prefer old_text/new_text for small changes); use write_file for new files.
        - After changes, run the project's build / tests with execute_bash and fix failures.
        - Use git_action for status, diffs, branches and commits. Never commit unless the user asked. Never push.
        - Paths are relative to the repository root. You cannot access files outside it.
        - If a tool call is denied, do not retry it unchanged; adapt or ask the user.
        - Finish with a concise summary of what you changed and how you verified it.
        """
        if let mem = workspace.memoryInstructions() {
            s += "\n\nProject instructions (from the repository; follow them):\n\(mem)"
        }
        return s
    }

    /// Run one user request to completion, emitting events as they happen.
    public func send(_ prompt: String, onEvent: @escaping @Sendable (AgentEvent) -> Void, approve: @escaping ApprovalHandler) async {
        cancelled = false
        history.append(.userText(prompt))
        let client = GeminiClient(config: config)
        let system = systemPrompt
        for turn in 1...config.maxTurns {
            if cancelled { onEvent(.finished(reason: "cancelled")); return }
            onEvent(.turnStarted(turn))
            var modelParts: [JSONValue] = []
            var calls: [FunctionCall] = []
            var finish = "STOP"
            do {
                for try await ev in client.stream(system: system, history: history, tools: registry.declarations) {
                    if cancelled { break }
                    switch ev {
                    case .thought(let t): onEvent(.thinking(t))
                    case .text(let t): onEvent(.text(t))
                    case .functionCall(let fc): calls.append(fc)
                    case .part(let p): Self.appendMerging(p, into: &modelParts)
                    case .usage(let p, let o): onEvent(.usage(prompt: p, output: o))
                    case .finish(let r): finish = r
                    }
                }
            } catch {
                onEvent(.error(error.localizedDescription))
                // Keep history consistent: drop the dangling user turn if nothing was produced.
                if modelParts.isEmpty, turn == 1 { history.removeLast() }
                onEvent(.finished(reason: "error"))
                return
            }
            if !modelParts.isEmpty { history.append(GeminiContent(role: "model", parts: modelParts)) }
            if cancelled { onEvent(.finished(reason: "cancelled")); return }
            if calls.isEmpty { onEvent(.finished(reason: finish)); return }

            var responses: [JSONValue] = []
            for call in calls {
                let result = await execute(call, onEvent: onEvent, approve: approve)
                var fr: [String: JSONValue] = ["name": .string(call.name), "response": result]
                if let id = call.id { fr["id"] = .string(id) }
                responses.append(["functionResponse": .object(fr)])
            }
            history.append(GeminiContent(role: "user", parts: responses))
        }
        onEvent(.error("Stopped after \(config.maxTurns) turns."))
        onEvent(.finished(reason: "max_turns"))
    }

    static func appendMerging(_ p: JSONValue, into parts: inout [JSONValue]) {
        // Merge consecutive plain text chunks of the same kind to keep history compact.
        if let t = p["text"]?.stringValue, p["thoughtSignature"] == nil, var last = parts.last?.objectValue,
           let lt = last["text"]?.stringValue, last["thoughtSignature"] == nil,
           (last["thought"]?.boolValue ?? false) == (p["thought"]?.boolValue ?? false) {
            last["text"] = .string(lt + t)
            parts[parts.count - 1] = .object(last)
        } else {
            parts.append(p)
        }
    }

    private func execute(_ call: FunctionCall, onEvent: @escaping @Sendable (AgentEvent) -> Void, approve: ApprovalHandler) async -> JSONValue {
        let id = UUID()
        guard let tool = registry.tools[call.name] else {
            onEvent(.toolFinished(id: id, status: .failed, result: "Unknown tool \(call.name)"))
            return ["error": .string("Unknown tool '\(call.name)'. Available: \(registry.tools.keys.sorted().joined(separator: ", "))")]
        }
        let ctx = ToolContext(workspace: workspace, executor: executor, commandTimeout: config.commandTimeout,
                              onOutput: { onEvent(.toolOutput(id: id, chunk: $0)) },
                              onPlan: { onEvent(.plan($0)) })
        let risk = tool.risk(call.args, ctx)
        var diff: FileDiff?
        do { diff = try tool.preview(call.args, ctx) } catch {
            onEvent(.toolCall(id: id, name: call.name, summary: tool.summary(call.args), args: call.args, risk: risk, diff: nil))
            onEvent(.toolFinished(id: id, status: .failed, result: error.localizedDescription))
            audit.record(tool: call.name, args: call.args, decision: "preview_failed", risk: risk, workspace: workspace.root.path, result: error.localizedDescription)
            return ["error": .string(error.localizedDescription)]
        }
        onEvent(.toolCall(id: id, name: call.name, summary: tool.summary(call.args), args: call.args, risk: risk, diff: diff))

        var decisionLabel = "auto"
        if permissions.needsApproval(risk: risk, toolName: call.name) {
            let req = PermissionRequest(toolName: call.name, summary: tool.summary(call.args), risk: risk, diff: diff,
                                        command: call.name == "execute_bash" ? call.args["command"]?.stringValue : nil)
            switch await approve(req) {
            case .allow: decisionLabel = "approved"
            case .allowAlwaysForSession:
                decisionLabel = "approved_session"
                permissions.sessionAllowedTools.insert(call.name)
            case .deny(let reason):
                let msg = "The user denied this action" + (reason.map { ": \($0)" } ?? ".")
                onEvent(.toolFinished(id: id, status: .denied, result: msg))
                audit.record(tool: call.name, args: call.args, decision: "denied", risk: risk, workspace: workspace.root.path)
                return ["error": .string(msg)]
            }
        }
        do {
            let out = try await tool.run(call.args, ctx)
            onEvent(.toolFinished(id: id, status: .succeeded, result: out))
            audit.record(tool: call.name, args: call.args, decision: decisionLabel, risk: risk, workspace: workspace.root.path, result: out)
            return ["output": .string(out)]
        } catch {
            onEvent(.toolFinished(id: id, status: .failed, result: error.localizedDescription))
            audit.record(tool: call.name, args: call.args, decision: decisionLabel, risk: risk, workspace: workspace.root.path, result: "error: \(error.localizedDescription)")
            return ["error": .string(error.localizedDescription)]
        }
    }
}

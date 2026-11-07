import SwiftUI
import AppKit
import AntigravityCore

struct ToolCard: Identifiable {
    let id: UUID
    var name: String
    var summary: String
    var risk: RiskLevel
    var diff: FileDiff?
    var output: String = ""
    var result: String = ""
    var status: ToolStatus = .running
}

enum TranscriptItem: Identifiable {
    case user(UUID, String)
    case assistant(UUID, String)
    case thinking(UUID, String)
    case tool(ToolCard)
    case plan(UUID, [PlanItem])
    case error(UUID, String)

    var id: UUID {
        switch self {
        case .user(let i, _), .assistant(let i, _), .thinking(let i, _), .plan(let i, _), .error(let i, _): return i
        case .tool(let c): return c.id
        }
    }
}

struct PendingApproval: Identifiable {
    let id = UUID()
    let request: PermissionRequest
    let continuation: CheckedContinuation<PermissionDecision, Never>
}

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var workspace: Workspace?
    @Published var transcript: [TranscriptItem] = []
    @Published var terminal: String = ""
    @Published var selectedDiff: FileDiff?
    @Published var plan: [PlanItem] = []
    @Published var isRunning = false
    @Published var pending: PendingApproval?
    @Published var input = ""
    @Published var tokens = (prompt: 0, output: 0)
    @AppStorage("model") var modelID = AgentConfig.defaultModel
    @AppStorage("permissionMode") var modeRaw = PermissionMode.review.rawValue
    @AppStorage("showThinking") var showThinking = true
    @AppStorage("lastWorkspace") var lastWorkspace = ""

    private var session: AgentSession?
    private var runTask: Task<Void, Never>?

    var mode: PermissionMode {
        get { PermissionMode(rawValue: modeRaw) ?? .review }
        set {
            objectWillChange.send()
            modeRaw = newValue.rawValue
            let s = session
            Task { await s?.setPermissionMode(newValue) }
        }
    }

    init() {
        if !lastWorkspace.isEmpty, FileManager.default.fileExists(atPath: lastWorkspace) { open(path: lastWorkspace) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { open(path: url.path) }
    }

    func open(path: String) {
        let ws = Workspace(path: path)
        workspace = ws
        lastWorkspace = ws.root.path
        newConversation()
    }

    func newConversation() {
        stop()
        transcript.removeAll(); terminal = ""; plan = []; selectedDiff = nil
        session = nil
    }

    private func ensureSession() -> AgentSession? {
        if let s = session { return s }
        guard let ws = workspace else { return nil }
        guard let auth = AgentConfig.resolveAuth() else {
            transcript.append(.error(UUID(), "No API key configured. Open Settings (⌘,) to add your Antigravity / Gemini API key, or set GOOGLE_CLOUD_PROJECT for OAuth."))
            return nil
        }
        let s = AgentSession(workspace: ws, config: AgentConfig(model: modelID, auth: auth, permissionMode: mode))
        session = s
        return s
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let s = ensureSession() else { return }
        input = ""
        transcript.append(.user(UUID(), text))
        isRunning = true
        let model = modelID
        // Events are funnelled through an AsyncStream so they reach the UI in order.
        var sinkRef: AsyncStream<AgentEvent>.Continuation?
        let events = AsyncStream<AgentEvent> { sinkRef = $0 }
        let sink = sinkRef!
        Task { [weak self] in
            for await ev in events { self?.handle(ev) }
            self?.isRunning = false
        }
        runTask = Task { [weak self] in
            await s.setModel(model)
            await s.send(text, onEvent: { ev in
                sink.yield(ev)
            }, approve: { req in
                await withCheckedContinuation { cont in
                    Task { @MainActor in self?.pending = PendingApproval(request: req, continuation: cont) }
                }
            })
            sink.finish()
        }
    }

    func stop() {
        if let p = pending { p.continuation.resume(returning: .deny(reason: "stopped by user")); pending = nil }
        if let s = session { Task { await s.cancel() } }
    }

    func resolve(_ decision: PermissionDecision) {
        guard let p = pending else { return }
        pending = nil
        p.continuation.resume(returning: decision)
    }

    private func appendStreaming(_ text: String, thinking: Bool) {
        if let last = transcript.last {
            switch (last, thinking) {
            case (.assistant(let id, let t), false): transcript[transcript.count - 1] = .assistant(id, t + text); return
            case (.thinking(let id, let t), true): transcript[transcript.count - 1] = .thinking(id, t + text); return
            default: break
            }
        }
        transcript.append(thinking ? .thinking(UUID(), text) : .assistant(UUID(), text))
    }

    private func updateTool(_ id: UUID, _ f: (inout ToolCard) -> Void) {
        guard let idx = transcript.lastIndex(where: { $0.id == id }), case .tool(var c) = transcript[idx] else { return }
        f(&c)
        transcript[idx] = .tool(c)
    }

    func handle(_ ev: AgentEvent) {
        switch ev {
        case .turnStarted: break
        case .thinking(let t): if showThinking { appendStreaming(t, thinking: true) }
        case .text(let t): appendStreaming(t, thinking: false)
        case .toolCall(let id, let name, let summary, _, let risk, let diff):
            transcript.append(.tool(ToolCard(id: id, name: name, summary: summary, risk: risk, diff: diff)))
            if let d = diff { selectedDiff = d }
            if name == "execute_bash" { terminal += "\n$ \(summary.dropFirst(2))\n" }
        case .toolOutput(let id, let chunk):
            terminal += PTYExecutor.stripANSI(chunk)
            if terminal.count > 400_000 { terminal = String(terminal.suffix(300_000)) }
            updateTool(id) { $0.output += chunk }
        case .toolFinished(let id, let status, let result):
            updateTool(id) { $0.status = status; $0.result = result }
        case .plan(let items):
            plan = items
            if let idx = transcript.lastIndex(where: { if case .plan = $0 { return true }; return false }) {
                transcript[idx] = .plan(transcript[idx].id, items)
            } else { transcript.append(.plan(UUID(), items)) }
        case .usage(let p, let o): tokens = (p, o)
        case .error(let m): transcript.append(.error(UUID(), m))
        case .finished: isRunning = false
        }
    }

    func refreshGitDiff() {
        guard let ws = workspace, ws.isGitRepo else { return }
        let r = Shell.run(Shell.git, ["--no-pager", "diff", "--no-color"], cwd: ws.root)
        terminal += "\n$ git diff\n" + r.output
    }
}

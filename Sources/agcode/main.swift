import Foundation
import AntigravityCore

// MARK: - Terminal styling

enum Style {
    static let tty = isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    static func c(_ code: String, _ s: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { c("2", s) }
    static func bold(_ s: String) -> String { c("1", s) }
    static func red(_ s: String) -> String { c("31", s) }
    static func green(_ s: String) -> String { c("32", s) }
    static func yellow(_ s: String) -> String { c("33", s) }
    static func blue(_ s: String) -> String { c("34", s) }
    static func magenta(_ s: String) -> String { c("35", s) }
    static func cyan(_ s: String) -> String { c("36", s) }
}

func out(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func renderDiff(_ d: FileDiff) {
    out(Style.bold("\n  \(d.isNewFile ? "new file" : "modified"): \(d.path)  ") + Style.green("+\(d.additions)") + " " + Style.red("-\(d.deletions)") + "\n")
    var shown = 0
    for h in d.hunks {
        out(Style.cyan("  " + h.header) + "\n")
        for l in h.lines {
            if shown > 400 { out(Style.dim("  … diff truncated\n")); return }
            shown += 1
            switch l.kind {
            case .context: out(Style.dim("   " + l.text) + "\n")
            case .added: out(Style.green("  +" + l.text) + "\n")
            case .removed: out(Style.red("  -" + l.text) + "\n")
            }
        }
    }
}

// MARK: - Arguments

struct Options {
    var cwd = FileManager.default.currentDirectoryPath
    var model = ProcessInfo.processInfo.environment["AGCODE_MODEL"] ?? AgentConfig.defaultModel
    var mode: PermissionMode = .review
    var prompt: String?
    var showThinking = true
    var timeout: TimeInterval = 120
}

let usage = """
agcode \(AntigravityCode.version) — Antigravity Code for the terminal

USAGE:
  agcode [options] [prompt]          Start an interactive session (or run one prompt with -p)
  agcode login                       Store your Antigravity / Gemini API key in the macOS Keychain
  agcode logout                      Remove the stored API key

OPTIONS:
  -p, --print <prompt>    Run a single prompt non-interactively and exit
  -C, --cwd <dir>         Workspace directory (default: current directory / enclosing git repo)
  -m, --model <id>        Model id (default: \(AgentConfig.defaultModel); env AGCODE_MODEL)
      --mode <m>          Permission mode: review (default) | turbo | yolo
      --turbo             Shortcut for --mode turbo
      --timeout <sec>     Default command timeout (default 120)
      --no-thinking       Hide thinking summaries
  -v, --version           Print version
  -h, --help              Show this help

AUTH: ANTIGRAVITY_API_KEY / GEMINI_API_KEY, the Keychain (agcode login), or Vertex AI OAuth via
      GOOGLE_CLOUD_PROJECT (+ GOOGLE_CLOUD_LOCATION) and `gcloud auth login`.

SLASH COMMANDS (interactive): /help /mode <m> /model <id> /clear /diff /status /exit
"""

var opts = Options()
var args = Array(CommandLine.arguments.dropFirst())
var positional: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    func next() -> String { guard !args.isEmpty else { err("missing value for \(a)"); exit(2) }; return args.removeFirst() }
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "-v", "--version": print("agcode \(AntigravityCode.version)"); exit(0)
    case "-p", "--print": opts.prompt = next()
    case "-C", "--cwd": opts.cwd = next()
    case "-m", "--model": opts.model = next()
    case "--mode":
        guard let m = PermissionMode(rawValue: next()) else { err("unknown mode"); exit(2) }
        opts.mode = m
    case "--turbo": opts.mode = .turbo
    case "--timeout": opts.timeout = TimeInterval(next()) ?? 120
    case "--no-thinking": opts.showThinking = false
    default: positional.append(a)
    }
}

if positional.first == "login" {
    out("Paste your Antigravity / Gemini API key (input hidden): ")
    let key: String
    if let p = getpass("") { key = String(cString: p) } else { key = readLine() ?? "" }
    guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { err("No key entered."); exit(1) }
    do { try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); print("Saved to Keychain.") }
    catch { err("Failed to save: \(error)"); exit(1) }
    exit(0)
}
if positional.first == "logout" { KeychainStore.delete(); print("Removed stored API key."); exit(0) }

guard let auth = AgentConfig.resolveAuth() else {
    err("No credentials. Run `agcode login`, set GEMINI_API_KEY, or set GOOGLE_CLOUD_PROJECT for Vertex AI OAuth.")
    exit(1)
}

let workspace = Workspace(path: opts.cwd)
let config = AgentConfig(model: opts.model, auth: auth, permissionMode: opts.mode, commandTimeout: opts.timeout)
let session = AgentSession(workspace: workspace, config: config)

// MARK: - Event rendering

final class Renderer: @unchecked Sendable {
    let lock = NSLock()
    var inThought = false
    var inText = false
    let showThinking: Bool
    init(showThinking: Bool) { self.showThinking = showThinking }

    func handle(_ e: AgentEvent) {
        lock.lock(); defer { lock.unlock() }
        switch e {
        case .turnStarted: break
        case .thinking(let t):
            guard showThinking else { return }
            if !inThought { out(Style.dim(Style.magenta("\n✻ thinking\n"))); inThought = true; inText = false }
            out(Style.dim(t))
        case .text(let t):
            if !inText { out("\n"); inText = true; inThought = false }
            out(t)
        case .toolCall(_, let name, let summary, _, let risk, let diff):
            inText = false; inThought = false
            let icon = risk == .destructive ? Style.red("⚠") : (risk >= .write ? Style.yellow("●") : Style.blue("●"))
            out("\n\(icon) \(Style.bold(name)) \(Style.dim(summary))\n")
            if let d = diff { renderDiff(d) }
        case .toolOutput(_, let chunk):
            out(Style.dim(chunk))
        case .toolFinished(_, let status, let result):
            switch status {
            case .succeeded:
                let first = result.split(separator: "\n").last.map(String.init) ?? ""
                out(Style.green("  ✓ ") + Style.dim(String(first.prefix(160))) + "\n")
            case .failed: out(Style.red("  ✗ \(result.prefix(400))") + "\n")
            case .denied: out(Style.yellow("  ⊘ denied") + "\n")
            default: break
            }
        case .plan(let items):
            out(Style.bold("\n☰ Plan\n"))
            for i in items {
                let mark: String
                switch i.status {
                case .completed: mark = Style.green("[x]")
                case .in_progress: mark = Style.yellow("[~]")
                case .failed: mark = Style.red("[!]")
                case .pending: mark = "[ ]"
                }
                out("  \(mark) \(i.title)\n")
            }
        case .usage: break
        case .error(let m): out(Style.red("\n✗ \(m)\n"))
        case .finished(let reason):
            if reason != "STOP" && reason != "error" { out(Style.dim("\n[\(reason)]")) }
            out("\n")
        }
    }
}

let renderer = Renderer(showThinking: opts.showThinking)
let interactiveStdin = isatty(STDIN_FILENO) == 1

let approve: ApprovalHandler = { req in
    if !interactiveStdin {
        return .deny(reason: "non-interactive session; rerun with --turbo or --mode yolo to allow this")
    }
    let tag = req.risk == .destructive ? Style.red("DESTRUCTIVE") : Style.yellow("approval needed")
    out("\n  \(tag) \(Style.bold(req.summary))\n  Allow? [y]es / [a]lways for \(req.toolName) this session / [n]o (or type feedback): ")
    let answer = (readLine() ?? "n").trimmingCharacters(in: .whitespaces)
    switch answer.lowercased() {
    case "y", "yes", "": return .allow
    case "a", "always": return req.risk == .destructive ? .allow : .allowAlwaysForSession
    case "n", "no": return .deny(reason: nil)
    default: return .deny(reason: answer)
    }
}

func run(_ prompt: String) async {
    await session.send(prompt, onEvent: { renderer.handle($0) }, approve: approve)
}

// Ctrl-C cancels the running request instead of killing the REPL.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
final class Flag: @unchecked Sendable { var value = false }
let busyFlag = Flag()
sigint.setEventHandler {
    if busyFlag.value { Task { await session.cancel() }; out(Style.yellow("\n^C cancelling…\n")) } else { out("\n"); exit(130) }
}
sigint.resume()

func banner() async {
    let mode = await session.config.permissionMode
    print(Style.bold("✦ Antigravity Code ") + Style.dim("v\(AntigravityCode.version)"))
    print(Style.dim("  workspace: \(workspace.root.path)\(workspace.isGitRepo ? " (git)" : "")"))
    print(Style.dim("  model: \(opts.model)   mode: \(mode.label)   memory: \(workspace.memoryInstructions() == nil ? "none" : "loaded")"))
    print(Style.dim("  /help for commands, Ctrl-C to interrupt, /exit to quit\n"))
}

func handleSlash(_ line: String) async -> Bool {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts[0] {
    case "/exit", "/quit": exit(0)
    case "/help": print(usage)
    case "/clear": await session.reset(); print(Style.dim("Conversation cleared."))
    case "/mode":
        if parts.count > 1, let m = PermissionMode(rawValue: parts[1]) { await session.setPermissionMode(m); print("Mode: \(m.label)") }
        else { print("Usage: /mode review|turbo|yolo") }
    case "/model":
        if parts.count > 1 { await session.setModel(parts[1]); print("Model: \(parts[1])") } else { print("Usage: /model <id>") }
    case "/diff":
        print(Shell.run(Shell.git, ["--no-pager", "diff", "--stat"], cwd: workspace.root).output)
    case "/status":
        print(Shell.run(Shell.git, ["status", "--short", "--branch"], cwd: workspace.root).output)
    default: return false
    }
    return true
}

_ = Task {
    if let p = opts.prompt {
        busyFlag.value = true
        await run(p)
        exit(0)
    }
    await banner()
    if !positional.isEmpty { busyFlag.value = true; await run(positional.joined(separator: " ")); busyFlag.value = false }
    while true {
        out(Style.bold(Style.cyan("› ")))
        guard let line = readLine() else { exit(0) }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        if trimmed.hasPrefix("/"), await handleSlash(trimmed) { continue }
        busyFlag.value = true
        await run(trimmed)
        busyFlag.value = false
    }
}
dispatchMain()

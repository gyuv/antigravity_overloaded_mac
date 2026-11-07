import Foundation

public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    /// Every write and every non-read-only shell command needs approval.
    case review
    /// Reads, searches and safe/test commands auto-run; destructive actions still ask.
    case turbo
    /// Everything auto-approved (still audited). Intended for throwaway sandboxes / CI.
    case yolo

    public var label: String {
        switch self {
        case .review: return "Review"
        case .turbo: return "Turbo"
        case .yolo: return "Auto-approve all"
        }
    }
}

public enum RiskLevel: String, Codable, Sendable, Comparable {
    case readOnly, safe, write, destructive
    private var rank: Int { switch self { case .readOnly: 0; case .safe: 1; case .write: 2; case .destructive: 3 } }
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rank < b.rank }
}

public enum PermissionDecision: Sendable, Equatable {
    case allow
    case allowAlwaysForSession
    case deny(reason: String?)
}

/// A request shown to the user before a tool call runs.
public struct PermissionRequest: Sendable, Identifiable {
    public let id = UUID()
    public var toolName: String
    public var summary: String
    public var risk: RiskLevel
    public var diff: FileDiff?
    public var command: String?
}

/// Classifies tool calls and decides whether they need an explicit approval.
public struct PermissionEngine: Sendable {
    public var mode: PermissionMode
    public var sessionAllowedTools: Set<String> = []

    public init(mode: PermissionMode) { self.mode = mode }

    public func needsApproval(risk: RiskLevel, toolName: String) -> Bool {
        if sessionAllowedTools.contains(toolName) && risk < .destructive { return false }
        switch mode {
        case .review: return risk >= .write
        case .turbo:
            // File edits, reads, searches and build/test commands auto-run (and are audited);
            // destructive actions and arbitrary shell commands with side effects still ask.
            if risk == .destructive { return true }
            return risk == .write && (toolName == "execute_bash" || toolName == "git_action")
        case .yolo: return false
        }
    }

    // MARK: Shell command classification

    static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "pwd", "echo", "which", "file", "stat", "grep", "rg", "find", "tree",
        "du", "df", "env", "printenv", "date", "uname", "whoami", "diff", "sort", "uniq", "cut", "less", "more", "type",
        "sw_vers", "xcode-select", "basename", "dirname", "realpath", "jq", "true",
    ]
    static let testPrefixes: [String] = [
        "swift build", "swift test", "xcodebuild build", "xcodebuild test", "npm test", "npm run test", "npm run build",
        "npm run lint", "pnpm test", "pnpm build", "yarn test", "yarn build", "cargo build", "cargo test", "cargo check",
        "cargo clippy", "go build", "go test", "go vet", "pytest", "python -m pytest", "python3 -m pytest", "make test",
        "make check", "make build", "mvn test", "gradle test", "./gradlew test", "bundle exec rspec", "rspec", "tsc",
        "eslint", "ruff", "mypy", "jest", "vitest",
    ]
    static let readOnlyGit: Set<String> = ["status", "diff", "log", "show", "branch", "rev-parse", "ls-files", "blame", "remote", "describe", "shortlog", "grep"]
    static let destructivePatterns: [String] = [
        #"(^|[\s;&|])rm\s"#, #"(^|[\s;&|])rmdir\s"#, #"\bgit\s+reset\b"#, #"\bgit\s+clean\b"#, #"\bgit\s+push\b"#,
        #"\bgit\s+checkout\s+--\s"#, #"\bgit\s+restore\b"#, #"\bgit\s+rebase\b"#, #"\bgit\s+branch\s+-D\b"#,
        #"\bsudo\b"#, #"\bmkfs"#, #"\bdd\s"#, #"\bchmod\s+-R\b"#, #"\bchown\b"#, #"\bkill(all)?\b"#, #"\bshutdown\b"#,
        #"\breboot\b"#, #"\bcurl\b.*\|\s*(ba|z)?sh"#, #"\bwget\b.*\|\s*(ba|z)?sh"#, #"\bnpm\s+publish\b"#,
        #"\b(deploy|release)\b"#, #"\bterraform\s+(apply|destroy)\b"#, #"\bkubectl\s+(apply|delete)\b"#,
        #"\bdocker\s+(rm|rmi|system\s+prune)\b"#, #">\s*/dev/"#, #"\bmv\s"#, #"\bfirebase\s+deploy\b"#, #"\bvercel\b"#,
        #"\bfastlane\b"#, #"\bxcrun\s+altool\b"#, #"\bnotarytool\s+submit\b"#,
    ]

    public static func classify(command: String) -> RiskLevel {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in destructivePatterns where c.range(of: p, options: .regularExpression) != nil { return .destructive }
        // Split compound commands; overall risk is the max of segments.
        let segments = c.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var worst: RiskLevel = .readOnly
        for seg in segments {
            let r = classifySegment(seg)
            if r > worst { worst = r }
        }
        if c.contains(">") && !c.contains("2>&1") && worst < .write { worst = .write }
        return worst
    }

    static func classifySegment(_ seg: String) -> RiskLevel {
        let words = seg.split(separator: " ").map(String.init)
        guard let first = words.first else { return .readOnly }
        if readOnlyCommands.contains(first) { return .readOnly }
        if first == "git", words.count > 1, readOnlyGit.contains(words[1]) { return .readOnly }
        if testPrefixes.contains(where: { seg.hasPrefix($0) }) { return .safe }
        return .write
    }
}

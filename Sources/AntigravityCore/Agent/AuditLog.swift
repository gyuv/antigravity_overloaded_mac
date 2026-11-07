import Foundation

/// Append-only JSONL audit trail of every tool call: ~/Library/Logs/AntigravityCode/audit-YYYY-MM-DD.jsonl
public final class AuditLog: @unchecked Sendable {
    public static let shared = AuditLog()
    private let queue = DispatchQueue(label: "agcode.audit")
    public let directory: URL

    public init(directory: URL? = nil) {
        if let d = directory { self.directory = d } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            #if os(macOS)
            self.directory = home.appendingPathComponent("Library/Logs/AntigravityCode")
            #else
            self.directory = home.appendingPathComponent(".local/state/agcode/logs")
            #endif
        }
    }

    public func record(tool: String, args: JSONValue, decision: String, risk: RiskLevel, workspace: String, result: String? = nil) {
        let entry: JSONValue = [
            "ts": .string(ISO8601DateFormatter().string(from: Date())),
            "tool": .string(tool),
            "args": args,
            "decision": .string(decision),
            "risk": .string(risk.rawValue),
            "workspace": .string(workspace),
            "result": result.map { .string(String($0.prefix(2000))) } ?? .null,
        ]
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let url = directory.appendingPathComponent("audit-\(f.string(from: Date())).jsonl")
            let line = entry.jsonString() + "\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

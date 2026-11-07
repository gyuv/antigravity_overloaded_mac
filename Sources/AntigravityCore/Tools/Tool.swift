import Foundation

public struct ToolContext: Sendable {
    public var workspace: Workspace
    public var executor: PTYExecutor
    public var commandTimeout: TimeInterval
    /// Live stdout/stderr stream for the UI (tool call id, chunk).
    public var onOutput: @Sendable (String) -> Void
    /// Structured plan/checklist updates.
    public var onPlan: @Sendable ([PlanItem]) -> Void
}

public struct PlanItem: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, in_progress, completed, failed }
    public var id: String { title }
    public var title: String
    public var status: Status
}

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    /// OpenAPI-subset JSON schema accepted by Gemini function declarations.
    var parameters: JSONValue { get }
    func risk(_ args: JSONValue, _ ctx: ToolContext) -> RiskLevel
    /// Diff shown in the approval prompt before writes hit the disk.
    func preview(_ args: JSONValue, _ ctx: ToolContext) throws -> FileDiff?
    func run(_ args: JSONValue, _ ctx: ToolContext) async throws -> String
    func summary(_ args: JSONValue) -> String
}

public extension AgentTool {
    func preview(_ args: JSONValue, _ ctx: ToolContext) throws -> FileDiff? { nil }
    func summary(_ args: JSONValue) -> String { "\(name)(\(args.jsonString()))" }
    var declaration: JSONValue {
        ["name": .string(name), "description": .string(description), "parameters": parameters]
    }
}

func schema(_ props: [String: JSONValue], required: [String]) -> JSONValue {
    ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })]
}
func prop(_ type: String, _ desc: String) -> JSONValue { ["type": .string(type), "description": .string(desc)] }

func req(_ args: JSONValue, _ key: String) throws -> String {
    guard let v = args[key]?.stringValue else { throw WorkspaceError.invalidArgument("missing '\(key)'") }
    return v
}

/// Truncate long tool output so it does not overwhelm the model context.
func clip(_ s: String, max: Int = 30_000) -> String {
    guard s.count > max else { return s }
    let head = s.prefix(max / 3), tail = s.suffix(max * 2 / 3)
    return "\(head)\n\n… [\(s.count - max) characters truncated] …\n\n\(tail)"
}

public struct ToolRegistry: Sendable {
    public var tools: [String: AgentTool]
    public init(_ tools: [AgentTool]) { self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) }) }

    public static let standard = ToolRegistry([
        ReadFileTool(), WriteFileTool(), PatchFileTool(), ListDirTool(), GlobTool(), GrepTool(), OutlineTool(),
        ExecuteBashTool(), GitActionTool(), UpdatePlanTool(),
    ])

    public var declarations: JSONValue { .array(tools.values.sorted { $0.name < $1.name }.map(\.declaration)) }
}

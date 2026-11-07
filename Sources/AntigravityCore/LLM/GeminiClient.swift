import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One message in the conversation. Parts are kept as raw JSON so opaque fields such as
/// `thoughtSignature` are echoed back to the model verbatim, as Gemini 3 requires.
public struct GeminiContent: Sendable, Equatable {
    public var role: String          // "user" | "model"
    public var parts: [JSONValue]
    public init(role: String, parts: [JSONValue]) { self.role = role; self.parts = parts }

    public static func userText(_ t: String) -> GeminiContent { .init(role: "user", parts: [["text": .string(t)]]) }
    public var json: JSONValue { ["role": .string(role), "parts": .array(parts)] }
}

public struct FunctionCall: Sendable, Equatable {
    public var id: String?
    public var name: String
    public var args: JSONValue
}

public enum StreamEvent: Sendable {
    case thought(String)
    case text(String)
    case functionCall(FunctionCall)
    /// Raw part to append to the model turn in history.
    case part(JSONValue)
    case usage(prompt: Int, output: Int)
    case finish(reason: String)
}

public enum GeminiError: Error, LocalizedError {
    case http(Int, String)
    case auth(String)
    case blocked(String)

    public var errorDescription: String? {
        switch self {
        case .http(let c, let b): return "Antigravity API error \(c): \(b.prefix(800))"
        case .auth(let m): return "Authentication error: \(m)"
        case .blocked(let r): return "Response blocked: \(r)"
        }
    }
}

/// Minimal Server-Sent-Events client for `streamGenerateContent?alt=sse` with function calling.
public final class GeminiClient: @unchecked Sendable {
    public let config: AgentConfig
    private var cachedToken: (String, Date)?

    public init(config: AgentConfig) { self.config = config }

    func endpoint() throws -> (URL, [String: String]) {
        switch config.auth {
        case .apiKey(let key):
            let url = URL(string: "\(config.baseURL)/models/\(config.model):streamGenerateContent?alt=sse")!
            return (url, ["x-goog-api-key": key])
        case .oauth(let project, let location, let token):
            let host = location == "global" ? "aiplatform.googleapis.com" : "\(location)-aiplatform.googleapis.com"
            let url = URL(string: "https://\(host)/v1/projects/\(project)/locations/\(location)/publishers/google/models/\(config.model):streamGenerateContent?alt=sse")!
            return (url, ["Authorization": "Bearer \(try token ?? gcloudToken())"])
        }
    }

    func gcloudToken() throws -> String {
        if let (t, exp) = cachedToken, exp > Date() { return t }
        guard let gcloud = Shell.which("gcloud") else { throw GeminiError.auth("gcloud not found; run `gcloud auth application-default login` or set an API key") }
        let r = Shell.run(gcloud, ["auth", "print-access-token"], timeout: 30)
        let t = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.exitCode == 0, !t.isEmpty, !t.contains(" ") else { throw GeminiError.auth(r.output) }
        cachedToken = (t, Date().addingTimeInterval(45 * 60))
        return t
    }

    public func requestBody(system: String, history: [GeminiContent], tools: JSONValue) -> JSONValue {
        var gen: [String: JSONValue] = ["temperature": .number(1.0)]
        if config.includeThoughts { gen["thinkingConfig"] = ["includeThoughts": true] }
        return [
            "systemInstruction": ["parts": [["text": .string(system)]]],
            "contents": .array(history.map(\.json)),
            "tools": [["functionDeclarations": tools]],
            "toolConfig": ["functionCallingConfig": ["mode": "AUTO"]],
            "generationConfig": .object(gen),
        ]
    }

    public func stream(system: String, history: [GeminiContent], tools: JSONValue) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (url, headers) = try self.endpoint()
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                    req.httpBody = Data(self.requestBody(system: system, history: history, tools: tools).jsonString().utf8)

                    let sse = SSEStream(request: req)
                    for try await payload in sse.events() {
                        guard let json = try? JSONValue.parse(Data(payload.utf8)) else { continue }
                        if let err = json["error"] {
                            throw GeminiError.http(err["code"]?.intValue ?? 0, err["message"]?.stringValue ?? err.jsonString())
                        }
                        if let fb = json["promptFeedback"]?["blockReason"]?.stringValue { throw GeminiError.blocked(fb) }
                        if let u = json["usageMetadata"] {
                            continuation.yield(.usage(prompt: u["promptTokenCount"]?.intValue ?? 0, output: u["candidatesTokenCount"]?.intValue ?? 0))
                        }
                        guard let cand = json["candidates"]?.arrayValue?.first else { continue }
                        for part in cand["content"]?["parts"]?.arrayValue ?? [] {
                            continuation.yield(.part(part))
                            if let fc = part["functionCall"] {
                                continuation.yield(.functionCall(FunctionCall(id: fc["id"]?.stringValue,
                                                                              name: fc["name"]?.stringValue ?? "",
                                                                              args: fc["args"] ?? [:])))
                            } else if let t = part["text"]?.stringValue {
                                continuation.yield(part["thought"]?.boolValue == true ? .thought(t) : .text(t))
                            }
                        }
                        if let r = cand["finishReason"]?.stringValue { continuation.yield(.finish(reason: r)) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Delegate-based streaming (works on macOS 12+ and Linux) that yields each SSE `data:` payload.
final class SSEStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let request: URLRequest
    private var buffer = Data()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var statusCode = 200
    private var errorBody = Data()
    private var session: URLSession?

    init(request: URLRequest) { self.request = request }

    func events() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            self.continuation = c
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = s
            let t = s.dataTask(with: request)
            c.onTermination = { _ in t.cancel(); s.invalidateAndCancel() }
            t.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if statusCode >= 400 { errorBody.append(data); return }
        buffer.append(data)
        flush(final: false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error { continuation?.finish(throwing: e) }
        else if statusCode >= 400 {
            continuation?.finish(throwing: GeminiError.http(statusCode, String(decoding: errorBody, as: UTF8.self)))
        } else {
            flush(final: true)
            continuation?.finish()
        }
        session.finishTasksAndInvalidate()
    }

    private func flush(final: Bool) {
        // Events are separated by a blank line.
        while true {
            let text = String(decoding: buffer, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            guard let r = text.range(of: "\n\n") else {
                if final, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(text); buffer.removeAll() }
                return
            }
            emit(String(text[..<r.lowerBound]))
            buffer = Data(text[r.upperBound...].utf8)
        }
    }

    private func emit(_ block: String) {
        let data = block.split(separator: "\n").filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        if !data.isEmpty, data != "[DONE]" { continuation?.yield(data) }
    }
}

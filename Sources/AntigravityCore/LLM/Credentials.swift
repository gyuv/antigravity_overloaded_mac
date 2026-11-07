import Foundation
#if canImport(Security)
import Security
#endif

/// Stores the Antigravity / Gemini API key in the macOS login Keychain.
public enum KeychainStore {
    static let service = "com.antigravity.code"

    public static func save(_ value: String, account: String = "gemini-api-key") throws {
        #if canImport(Security)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        #else
        let url = fallbackURL(account)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #endif
    }

    public static func load(account: String = "gemini-api-key") -> String? {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
        #else
        return try? String(contentsOf: fallbackURL(account), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }

    public static func delete(account: String = "gemini-api-key") {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        #else
        try? FileManager.default.removeItem(at: fallbackURL(account))
        #endif
    }

    #if !canImport(Security)
    static func fallbackURL(_ account: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/agcode/\(account)")
    }
    #endif
}

public enum AuthMode: Sendable, Equatable {
    /// Gemini Developer API / Antigravity API key (x-goog-api-key).
    case apiKey(String)
    /// Google Cloud OAuth (Vertex AI): bearer token from `gcloud auth print-access-token` or an explicit token.
    case oauth(project: String, location: String, token: String?)
}

public struct AgentConfig: Sendable {
    public var model: String
    public var auth: AuthMode
    public var permissionMode: PermissionMode
    public var commandTimeout: TimeInterval
    public var maxTurns: Int
    public var includeThoughts: Bool
    public var baseURL: String

    public static let defaultModel = "gemini-3.1-pro-preview"

    public init(model: String = AgentConfig.defaultModel, auth: AuthMode, permissionMode: PermissionMode = .review,
                commandTimeout: TimeInterval = 120, maxTurns: Int = 60, includeThoughts: Bool = true,
                baseURL: String = "https://generativelanguage.googleapis.com/v1beta") {
        self.model = model; self.auth = auth; self.permissionMode = permissionMode
        self.commandTimeout = commandTimeout; self.maxTurns = maxTurns; self.includeThoughts = includeThoughts
        self.baseURL = baseURL
    }

    /// Resolve credentials from the environment, then the Keychain, then gcloud project settings.
    public static func resolveAuth() -> AuthMode? {
        let env = ProcessInfo.processInfo.environment
        for k in ["ANTIGRAVITY_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY"] {
            if let v = env[k], !v.isEmpty { return .apiKey(v) }
        }
        if let k = KeychainStore.load(), !k.isEmpty { return .apiKey(k) }
        if let p = env["GOOGLE_CLOUD_PROJECT"], !p.isEmpty {
            return .oauth(project: p, location: env["GOOGLE_CLOUD_LOCATION"] ?? "global", token: env["GOOGLE_OAUTH_ACCESS_TOKEN"])
        }
        return nil
    }
}

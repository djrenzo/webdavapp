import Foundation
#if canImport(Security)
import Security
#endif

/// Secrets live in the Keychain (§4): WebDAV passwords, the Supabase password and session,
/// and the TMDB token.
enum Secrets {
    static func tmdbToken() -> String? { get("tmdb.token") }
    static func setTMDBToken(_ value: String?) { set("tmdb.token", value) }

    static func supabasePassword() -> String? { get("supabase.password") }
    static func setSupabasePassword(_ value: String?) { set("supabase.password", value) }

    static func supabaseSession() -> Data? { get("supabase.session").map { Data($0.utf8) } }
    static func setSupabaseSession(_ value: Data?) { set("supabase.session", value.map { String(decoding: $0, as: UTF8.self) }) }

    static func openSubtitlesKey() -> String? { get("opensubtitles.key") }
    static func setOpenSubtitlesKey(_ value: String?) { set("opensubtitles.key", value) }

    static func traktSecret() -> String? { get("trakt.secret") }
    static func setTraktSecret(_ value: String?) { set("trakt.secret", value) }

    static func traktToken() -> Data? { get("trakt.token").map { Data($0.utf8) } }
    static func setTraktToken(_ value: Data?) { set("trakt.token", value.map { String(decoding: $0, as: UTF8.self) }) }

    static func webdavPassword(account: UUID) -> String? { get("webdav.\(account.uuidString)") }
    static func setWebDAVPassword(_ value: String?, account: UUID) { set("webdav.\(account.uuidString)", value) }

    #if canImport(Security)
    private static let service = "TorBoxLibrary"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            AppLog.write("Keychain write failed for \(key): \(status)")
        }
    }
    #else
    // Non-Apple platforms (unit tests on Linux): an in-memory store.
    nonisolated(unsafe) private static var memory: [String: String] = [:]
    private static let lock = NSLock()

    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return memory[key]
    }

    static func set(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        memory[key] = value
    }
    #endif
}

/// Non-secret settings (UserDefaults).
struct AppSettings: Sendable, Equatable {
    var supabaseURL: String
    var supabaseKey: String
    var supabaseEmail: String

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        return AppSettings(
            supabaseURL: defaults.string(forKey: "supabase.url") ?? "",
            supabaseKey: defaults.string(forKey: "supabase.key") ?? "",
            supabaseEmail: defaults.string(forKey: "supabase.email") ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(supabaseURL, forKey: "supabase.url")
        defaults.set(supabaseKey, forKey: "supabase.key")
        defaults.set(supabaseEmail, forKey: "supabase.email")
    }

    var supabaseConfig: SupabaseConfig? {
        let config = SupabaseConfig(
            url: SupabaseConfig.projectURL(supabaseURL),
            key: supabaseKey.trimmingCharacters(in: .whitespacesAndNewlines),
            email: supabaseEmail.trimmingCharacters(in: .whitespacesAndNewlines),
            password: Secrets.supabasePassword() ?? ""
        )
        return config.isComplete ? config : nil
    }
}

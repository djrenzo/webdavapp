import Foundation

/// One TorBox WebDAV login. The password lives in the Keychain under `id`.
struct Account: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// `accounts.id` in Supabase (§3.5). Nil until resolved; never changes afterwards.
    var remoteID: Int?
    var name: String
    var baseURL: String
    var username: String
    var isEnabled: Bool = true
    var lastListedAt: Date?
    var lastListingComplete: Bool = true
    var fileCount: Int = 0
    var lastError: String?

    var host: String { URLComponents(string: baseURL)?.host ?? baseURL }

    var credentials: WebDAVCredentials? {
        guard let password = Secrets.webdavPassword(account: id), !password.isEmpty else { return nil }
        return WebDAVCredentials(baseURL: WebDAV.normalizedBaseURL(baseURL), username: username, password: password)
    }
}

struct ListedFile: Codable, Sendable, Equatable {
    var name: String
    /// href path as listed (percent-encoded)
    var path: String
    /// scheme://host + path, as listed
    var fullURL: String
    var size: Int64
    var firstSeenAt: Date

    var decodedPath: String { URLText.unquote(path) }
}

struct ListedFolder: Codable, Sendable, Equatable {
    var name: String
    /// decoded path, ends with '/'
    var path: String
    var files: [ListedFile]
}

struct AccountListing: Codable, Sendable {
    var accountID: UUID
    var folders: [ListedFolder]
    var complete: Bool
    var listedAt: Date
}

struct OverrideConflict: Codable, Sendable, Identifiable, Equatable {
    var folderName: String
    var local: JSONObject
    var remote: JSONObject
    var id: String { folderName }
}

struct CatalogState: Codable, Sendable {
    /// Remote account ids deleted on this device, to remove from Supabase on the next push.
    var tombstones: [Int] = []
    var conflicts: [OverrideConflict] = []
    /// Why a folder is still unidentified ("No TMDB result", "Best score 0.74 for X").
    var unidentifiedReasons: [String: String] = [:]
    var lastPushAt: Date?
    var lastPushStats: JSONObject?
    var lastFetchAt: Date?
}

/// Everything the UI shows, built off the main actor.
struct GalleryFile: Sendable, Identifiable {
    let id: String
    let accountID: UUID
    let name: String
    /// directory between the root folder and the file ("" in the root folder)
    let subfolder: String
    let fullURL: String
    let size: Int64
    let firstSeenAt: Date
    let number: EpisodeNumber
    let isMain: Bool

    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct GalleryFolder: Sendable, Identifiable {
    var id: String { "\(accountID.uuidString)|\(name)" }
    let accountID: UUID
    let accountName: String
    let name: String
    let path: String
    let entry: JSONObject
    let files: [GalleryFile]

    var episodesNeedingSeason: Int { files.filter(\.number.needsSeason).count }
}

struct GalleryTitle: Sendable, Identifiable {
    let id: String
    let title: String
    let mediaType: String
    let year: Int?
    let posterURL: URL?
    let plot: String?
    let tmdbID: String?
    let folders: [GalleryFolder]
    let latestSeen: Date

    var isMovie: Bool { mediaType == "movie" }
    var accountIDs: Set<UUID> { Set(folders.map(\.accountID)) }
    var fileCount: Int { folders.reduce(0) { $0 + $1.files.count } }
    var episodesNeedingSeason: Int { folders.reduce(0) { $0 + $1.episodesNeedingSeason } }
    var searchText: String { ([title] + folders.map(\.name)).joined(separator: " ") }
}

struct UnidentifiedFolder: Sendable, Identifiable {
    var id: String { "\(accountID.uuidString)|\(name)" }
    let accountID: UUID
    let accountName: String
    let name: String
    let path: String
    let parsedTitle: String
    let reason: String
    let entry: JSONObject
}

struct CatalogSnapshot: Sendable {
    var accounts: [Account] = []
    var titles: [GalleryTitle] = []
    var unidentified: [UnidentifiedFolder] = []
    var conflicts: [OverrideConflict] = []
    var overrideCount = 0
    var folderCount = 0
    var state = CatalogState()
}

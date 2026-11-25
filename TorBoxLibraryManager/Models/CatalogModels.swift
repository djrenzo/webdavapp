import Foundation
import SwiftData

// Demo records deliberately have no remote account IDs or credentials.
@Model final class DemoAccount {
    @Attribute(.unique) var id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

@Model final class DemoFolder {
    @Attribute(.unique) var id: UUID
    var accountID: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), accountID: UUID, name: String) {
        self.id = id
        self.accountID = accountID
        let normalizedName = name.precomposedStringWithCanonicalMapping
        self.name = normalizedName
        self.path = "/\(normalizedName)/"
    }
}

@Model final class DemoMediaFile {
    @Attribute(.unique) var id: UUID
    var folderID: UUID
    var name: String
    var remotePath: String
    var size: Int64
    var firstSeenAt: Date
    var season: Int?
    var episode: Int?
    var isMain: Bool

    init(folderID: UUID, name: String, path: String, size: Int64, firstSeenAt: Date) {
        id = UUID()
        self.folderID = folderID
        self.name = name.precomposedStringWithCanonicalMapping
        remotePath = path
        self.size = size
        self.firstSeenAt = firstSeenAt
        isMain = false
    }
}

@Model final class DemoOverride {
    @Attribute(.unique) var folderName: String
    var raw: Data

    init(folderName: String, raw: Data) {
        self.folderName = folderName
        self.raw = raw
    }
}

@Model final class DemoSeedState {
    @Attribute(.unique) var key: String
    var version: Int

    init() {
        key = "demo-seed"
        version = 1
    }
}

struct AccountLabel: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
}

struct FileSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let name: String
    let subfolder: String
    let size: Int64
    let firstSeenAt: Date
    let numbering: EpisodeNumber
    let isMain: Bool

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct FolderSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let accountID: UUID
    let accountName: String
    let name: String
    let raw: Data
    let files: [FileSnapshot]
}

struct GalleryTitle: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let originalTitle: String
    let mediaType: String
    let year: Int?
    let posterURL: URL?
    let folders: [FolderSnapshot]
    let accountIDs: Set<UUID>
    let firstSeenAt: Date
    let episodesNeedingSeason: Int

    var isMovie: Bool { mediaType == "movie" }
    var fileCount: Int { folders.reduce(0) { $0 + $1.files.count } }
    var searchText: String {
        ([title, originalTitle] + folders.map(\.name)).joined(separator: " ")
    }
}

struct CatalogSnapshot: Sendable {
    let accounts: [AccountLabel]
    let titles: [GalleryTitle]
    let folderCount: Int
}

enum CatalogError: LocalizedError {
    case invalidJSON, missingFolder, nameInUse, invalidField(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "An existing override cannot be read. Your saved data has not been replaced."
        case .missingFolder:
            "This folder is no longer in the demo library. Close the editor and try again."
        case .nameInUse:
            "Another folder already uses that name. Choose a different name to keep its override safe."
        case .invalidField(let message): message
        }
    }
}

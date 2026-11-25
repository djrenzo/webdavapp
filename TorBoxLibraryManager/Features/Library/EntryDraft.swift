import Foundation

struct FileDraft: Identifiable, Sendable, Equatable {
    let id: UUID
    var name: String
    var subfolder: String
    let size: Int64
}

struct EntryDraft: Sendable, Equatable {
    let folderID: UUID
    var folderName: String
    var title: String
    var mediaType: String
    var year: String
    var season: String
    var forceSeason: Bool
    var files: [FileDraft]

    init(folder: FolderSnapshot) throws {
        let entry = try OverrideJSON(raw: folder.raw)
        folderID = folder.id
        folderName = folder.name
        title = entry.title
        mediaType = entry.mediaType
        year = entry.year.map(String.init) ?? ""
        season = entry.season.map(String.init) ?? ""
        forceSeason = entry.forceSeason
        files = folder.files.map {
            FileDraft(id: $0.id, name: $0.name, subfolder: $0.subfolder, size: $0.size)
        }
    }

    func validate() throws {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CatalogError.invalidField("Enter a title before saving.")
        }
        if folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folderName.contains("/") {
            throw CatalogError.invalidField("Use a folder name without a slash.")
        }
        if !year.isEmpty, Int(year).map({ (1...9999).contains($0) }) != true {
            throw CatalogError.invalidField("The year must be a number between 1 and 9999, or left empty.")
        }
        if !season.isEmpty, Int(season).map({ (0...99).contains($0) }) != true {
            throw CatalogError.invalidField("The season must be between 0 and 99, or left empty.")
        }
        for file in files {
            if file.name.isEmpty || file.name.contains("/") || file.name == "." || file.name == ".." {
                throw CatalogError.invalidField("Each file needs a name without a slash.")
            }
            if file.subfolder.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
                throw CatalogError.invalidField("Subfolders cannot contain . or .. path segments.")
            }
        }
    }

    func numbering(for file: FileDraft) -> EpisodeNumber {
        guard mediaType != "movie" else { return EpisodeNumber(season: nil, episode: nil) }
        return EpisodeNumbering.number(
            name: file.name, subfolder: file.subfolder, rootName: folderName,
            season: Int(season), force: forceSeason
        )
    }
}

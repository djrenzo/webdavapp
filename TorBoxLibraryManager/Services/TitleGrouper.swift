import Foundation

enum TitleGrouper {
    static func group(_ folders: [FolderSnapshot]) throws -> [GalleryTitle] {
        let sorted = folders.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
        var groups: [String: [(FolderSnapshot, OverrideJSON)]] = [:]
        for folder in sorted {
            let entry = try OverrideJSON(raw: folder.raw)
            guard entry.isIdentified else { continue }
            groups[entry.titleKey, default: []].append((folder, entry))
        }
        return try groups.map { key, members in
            let metadata = try OverrideJSON.mergedMetadata(members.map { $0.1 })
            let groupFolders = members.map { $0.0 }
            let files = groupFolders.flatMap(\.files)
            return GalleryTitle(
                id: key, title: metadata.title, originalTitle: metadata.originalTitle,
                mediaType: metadata.mediaType, year: metadata.year,
                posterURL: URL(string: metadata.poster), folders: groupFolders,
                accountIDs: Set(groupFolders.map(\.accountID)),
                firstSeenAt: files.map(\.firstSeenAt).max() ?? .distantPast,
                episodesNeedingSeason: files.filter { $0.numbering.needsSeason }.count
            )
        }
    }
}

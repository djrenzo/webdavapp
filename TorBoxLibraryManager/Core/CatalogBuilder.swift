import Foundation

enum CatalogBuilder {
    /// "Not a movie or show" marker (§9.3): manual, no ids, titled with the folder name.
    static func isIgnoredMarker(_ entry: JSONObject, folderName: String) -> Bool {
        Overrides.isManual(entry) && Overrides.title(entry) == folderName
            && Py.text(entry["tmdb_id"]) == nil && Py.text(entry["tvdb_id"]) == nil && Py.text(entry["imdb_id"]) == nil
    }

    static func numberedFiles(folder: ListedFolder, accountID: UUID, entry: JSONObject) -> [GalleryFile] {
        let inputs = folder.files.map { EpisodeNumbering.Input(name: $0.name, decodedPath: $0.decodedPath, size: $0.size) }
        let outputs = EpisodeNumbering.number(rootName: folder.name, override: entry, files: inputs)
        return zip(folder.files, outputs).map { file, output in
            let decoded = file.decodedPath
            var relative = decoded.hasPrefix(folder.path) ? String(decoded.dropFirst(folder.path.count)) : file.name
            if let slash = relative.lastIndex(of: "/") { relative = String(relative[..<slash]) } else { relative = "" }
            return GalleryFile(
                id: "\(accountID.uuidString)|\(file.path)", accountID: accountID, name: file.name,
                subfolder: relative, fullURL: file.fullURL, size: file.size, firstSeenAt: file.firstSeenAt,
                number: output.number, isMain: output.isMain
            )
        }
    }

    static func build(accounts: [Account], listings: [UUID: AccountListing], overrides: [String: JSONObject], state: CatalogState) -> CatalogSnapshot {
        let rowSet = TitleRowSet(overrides: overrides)
        var groups: [String: [GalleryFolder]] = [:]
        var unidentified: [UnidentifiedFolder] = []
        var folderCount = 0

        for account in accounts where account.isEnabled {
            guard let listing = listings[account.id] else { continue }
            for folder in listing.folders {
                folderCount += 1
                let entry = overrides[folder.name] ?? [:]
                if isIgnoredMarker(entry, folderName: folder.name) { continue }
                let galleryFolder = GalleryFolder(
                    accountID: account.id, accountName: account.name, name: folder.name, path: folder.path,
                    entry: entry, files: numberedFiles(folder: folder, accountID: account.id, entry: entry)
                )
                if let key = rowSet.folderKeys[folder.name] {
                    groups[key, default: []].append(galleryFolder)
                } else {
                    unidentified.append(UnidentifiedFolder(
                        accountID: account.id, accountName: account.name, name: folder.name, path: folder.path,
                        parsedTitle: ReleaseParser.parse(folder.name).title,
                        reason: state.unidentifiedReasons[folder.name] ?? "Not identified yet",
                        entry: entry
                    ))
                }
            }
        }

        let titles = groups.compactMap { key, folders -> GalleryTitle? in
            guard let row = rowSet.rows[key] else { return nil }
            let latest = folders.flatMap { $0.files.map(\.firstSeenAt) }.max() ?? .distantPast
            return GalleryTitle(
                id: key,
                title: Py.text(row["title"]) ?? "Untitled",
                mediaType: row["media_type"]?.stringValue ?? "tvshow",
                year: Py.int(row["year"]),
                posterURL: Py.text(row["poster_url"]).flatMap(URL.init(string:)),
                plot: Py.text(row["plot"]),
                tmdbID: Py.text(row["tmdb_id"]),
                folders: folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                latestSeen: latest
            )
        }

        return CatalogSnapshot(
            accounts: accounts,
            titles: titles,
            unidentified: unidentified.sorted { ($0.accountName, $0.name) < ($1.accountName, $1.name) },
            conflicts: state.conflicts,
            overrideCount: overrides.count,
            folderCount: folderCount,
            state: state
        )
    }
}

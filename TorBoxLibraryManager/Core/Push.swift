import Foundation

enum PushMode: String, Sendable, CaseIterable, Identifiable {
    case changedOnly = "Changed only"
    case refreshAll = "Refresh every title"
    var id: String { rawValue }
}

struct PushError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Port of torbox_sync row builders and `_push` (§8.2).
enum Push {
    static let tmdbRefreshDays = 30
    static let subtitleLanguages = ["sp": "es"]

    static func nowISO() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return formatter.string(from: Date())
    }

    static func date(_ value: JSONValue?) -> String? {
        guard let text = Py.text(value), text.count >= 10 else { return nil }
        return String(text.prefix(10))
    }

    static func rating(_ value: JSONValue?) -> Double? {
        guard let value, value.isTruthy, let number = value.pythonDouble else { return nil }
        return (number * 100).rounded() / 100
    }

    // MARK: Rows

    static func overrideRow(_ folderName: String, _ entry: JSONObject, titleID: Int?, syncedAt: String) -> JSONObject {
        let season = Py.int(entry["season"])
        return [
            "folder_name": .string(folderName),
            "title_id": Py.number(titleID),
            "source": .string(Overrides.isAutomatic(entry) ? "auto" : "manual"),
            "media_type": Py.string(Overrides.mediaType(entry)),
            "title": Py.string(Py.text(entry["title"])),
            "year": Py.number(Py.int(entry["year"])),
            "tmdb_id": Py.string(Py.text(entry["tmdb_id"])),
            "tvdb_id": Py.string(Py.text(entry["tvdb_id"])),
            "imdb_id": Py.string(Py.text(entry["imdb_id"])),
            "thumb_url": Py.string(Py.text(entry["thumb"])),
            "plot": Py.string(Py.text(entry["plot"])),
            "season": Py.number(season),
            "force_season": .bool(Py.truthy(entry["force_season"]) && season != nil),
            "raw": .object(entry),
            "synced_at": .string(syncedAt),
        ]
    }

    static func subtitleRows(_ folderName: String, _ entry: JSONObject, titleID: Int?, syncedAt: String) -> [JSONObject] {
        let isTV = Overrides.mediaType(entry) == "tvshow"
        var rows: [JSONObject] = []
        for sub in entry["subs"]?.arrayValue ?? [] {
            guard let sub = sub.objectValue, let url = Py.text(sub["url"]), let fileName = Py.text(sub["fileName"]) else { continue }
            let info = isTV ? EpisodeNumbering.extractEpisodeInfo(fileName) : nil
            let language = Py.text(sub["language"]) ?? "en"
            // adjustments_of: fps pair only when both set, shift only when non-zero.
            var fpsFrom: Double?, fpsTo: Double?, shift: Int?
            if Py.truthy(sub["fps_from"]) && Py.truthy(sub["fps_to"]) {
                fpsFrom = sub["fps_from"]?.pythonDouble
                fpsTo = sub["fps_to"]?.pythonDouble
                if fpsFrom == nil || fpsTo == nil { fpsFrom = nil; fpsTo = nil }
            }
            if Py.truthy(sub["shift_ms"]) { shift = sub["shift_ms"]?.pythonInt }
            rows.append([
                "folder_name": .string(folderName),
                "title_id": Py.number(titleID),
                "season_number": Py.number(info?.season),
                "episode_number": Py.number(info?.episode),
                "language": .string(subtitleLanguages[language] ?? language),
                "hearing_impaired": .bool(Py.truthy(sub["hi"])),
                "file_name": .string(fileName),
                "url": .string(url),
                "fps_from": Py.number(fpsFrom),
                "fps_to": Py.number(fpsTo),
                "shift_ms": Py.number(shift),
                "synced_at": .string(syncedAt),
            ])
        }
        return rows
    }

    static func needsTMDB(_ row: JSONObject, remote: JSONObject?, seasons: Set<Int>, refreshAll: Bool) -> Bool {
        guard Py.truthy(row["tmdb_id"]) else { return false }
        guard let remote, Py.truthy(remote["tmdb_synced_at"]), !refreshAll else { return true }
        let remoteSeasons = Set((remote["episode_seasons"]?.arrayValue ?? []).compactMap(\.pythonInt))
        if !seasons.isSubset(of: remoteSeasons) { return true }
        guard let text = remote["tmdb_synced_at"]?.stringValue, text.count >= 10 else { return true }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let synced = formatter.date(from: String(text.prefix(10))) else { return true }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: synced), to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return days >= tmdbRefreshDays
    }

    /// `_enriched`: the title row completed with TMDB details; override values win.
    static func enriched(_ row: JSONObject, details: JSONObject, episodes: [Int: [JSONObject]], previousSeasons: [Int], syncedAt: String) -> JSONObject {
        let isTV = row["media_type"]?.stringValue == "tvshow"
        let ids = details["external_ids"]?.objectValue ?? [:]
        let premiered = date(details[isTV ? "first_air_date" : "release_date"])
        let runtime: JSONValue? = isTV ? details["episode_run_time"]?.arrayValue?.first : details["runtime"]
        var result = row
        result["original_title"] = Py.string(Py.text(details[isTV ? "original_name" : "original_title"]))
        result["tagline"] = Py.string(Py.text(details["tagline"]))
        result["fanart_url"] = Py.string(TMDBClient.image(details["backdrop_path"]?.stringValue, size: "w1280"))
        result["genres"] = .array((details["genres"]?.arrayValue ?? []).compactMap { genre in
            Py.text(genre.objectValue?["name"]).map(JSONValue.string)
        })
        result["rating"] = Py.number(rating(details["vote_average"]))
        result["premiered"] = Py.string(premiered)
        result["runtime"] = Py.number(Py.int(runtime))
        result["status"] = Py.string(Py.text(details["status"]))
        result["episode_seasons"] = .array(Set(previousSeasons).union(episodes.keys).sorted().map { .int($0) })
        result["tmdb_synced_at"] = .string(syncedAt)
        let defaults: [(String, JSONValue)] = [
            ("poster_url", Py.string(TMDBClient.image(details["poster_path"]?.stringValue, size: "w500"))),
            ("plot", Py.string(Py.text(details["overview"]))),
            ("year", Py.number(premiered.flatMap { Int($0.prefix(4)) })),
            ("imdb_id", Py.string(Py.text(ids["imdb_id"]))),
            ("tvdb_id", isTV ? Py.string(Py.text(ids["tvdb_id"])) : .null),
        ]
        for (field, value) in defaults where !Py.truthy(result[field]) {
            result[field] = value
        }
        return result
    }

    static func seasonRows(titleID: Int, details: JSONObject) -> [JSONObject] {
        (details["seasons"]?.arrayValue ?? []).compactMap { value -> JSONObject? in
            guard let season = value.objectValue, let number = Py.int(season["season_number"]) else { return nil }
            return [
                "title_id": .int(titleID),
                "season_number": season["season_number"] ?? .int(number),
                "name": Py.string(Py.text(season["name"])),
                "overview": Py.string(Py.text(season["overview"])),
                "poster_url": Py.string(TMDBClient.image(season["poster_path"]?.stringValue, size: "w500")),
                "air_date": Py.string(date(season["air_date"])),
                "episode_count": Py.number(Py.int(season["episode_count"])),
            ]
        }
    }

    static func episodeRows(titleID: Int, episodes: [Int: [JSONObject]]) -> [JSONObject] {
        var rows: [JSONObject] = []
        for (season, items) in episodes.sorted(by: { $0.key < $1.key }) {
            for episode in items {
                guard let number = Py.int(episode["episode_number"]) else { continue }
                let seasonNumber = (episode["season_number"].map { $0.isNull } ?? true) ? season : (Py.int(episode["season_number"]) ?? season)
                rows.append([
                    "title_id": .int(titleID),
                    "season_number": .int(seasonNumber),
                    "episode_number": .int(number),
                    "name": Py.string(Py.text(episode["name"])),
                    "overview": Py.string(Py.text(episode["overview"])),
                    "still_url": Py.string(TMDBClient.image(episode["still_path"]?.stringValue, size: "w300")),
                    "air_date": Py.string(date(episode["air_date"])),
                    "runtime": Py.number(Py.int(episode["runtime"])),
                    "rating": Py.number(rating(episode["vote_average"])),
                ])
            }
        }
        return rows
    }

    // MARK: Account ids (§3.5)

    /// Reuse the id of a remote row with the same URL and username, otherwise
    /// max(100, max(existing ids)) + 1. Returns the ids assigned to local accounts.
    static func resolveAccountIDs(_ client: SupabaseClient, accounts: [Account]) async throws -> [UUID: Int] {
        let pending = accounts.filter { $0.remoteID == nil }
        guard !pending.isEmpty else { return [:] }
        let remote = try await client.selectAll("accounts", select: "id,webdav_url,username", order: "id")
        var used = Set(remote.compactMap { Py.int($0["id"]) })
        used.formUnion(accounts.compactMap(\.remoteID))
        var assigned: [UUID: Int] = [:]
        for account in pending {
            let url = WebDAV.normalizedBaseURL(account.baseURL)
            if let match = remote.first(where: {
                WebDAV.normalizedBaseURL($0["webdav_url"]?.stringValue ?? "") == url && $0["username"]?.stringValue == account.username
            }), let id = Py.int(match["id"]), !accounts.contains(where: { $0.remoteID == id }), !assigned.values.contains(id) {
                assigned[account.id] = id
            } else {
                let id = max(100, used.max() ?? 0) + 1
                assigned[account.id] = id
                used.insert(id)
            }
        }
        return assigned
    }

    // MARK: The push

    struct Input: Sendable {
        var overrides: [String: JSONObject]
        /// Enabled accounts that have a remote id, credentials and a listing.
        var accounts: [(account: Account, credentials: WebDAVCredentials, listing: AccountListing)]
        var tombstones: [Int]
        var mode: PushMode
        var tmdb: TMDBClient?
    }

    typealias Report = @Sendable (String, Double) async -> Void
    typealias ConfirmStale = @Sendable ([String]) async -> Bool

    static func run(_ client: SupabaseClient, input: Input, report: Report, confirmStale: ConfirmStale) async throws -> (stats: JSONObject, deletedTombstones: [Int]) {
        let overrides = input.overrides
        guard !overrides.isEmpty else {
            throw PushError(message: "There are no overrides on this device. Pushing would wipe the shared catalog, so nothing was sent.")
        }
        guard try await client.isAdmin() else {
            throw PushError(message: "This Supabase user isn't an admin, so it can't push.")
        }
        let runStarted = nowISO()
        var stats: JSONObject = [:]

        await report("Checking Supabase overrides", 0.0)
        let remoteFolders = Set(try await client.selectAll("overrides", select: "folder_name", order: "folder_name").compactMap { $0["folder_name"]?.stringValue })
        let stale = remoteFolders.subtracting(overrides.keys).sorted()
        var deleteOverrides = true
        if !stale.isEmpty {
            deleteOverrides = await confirmStale(stale)
        }

        let rowSet = TitleRowSet(overrides: overrides)
        struct NumberedRow { let accountID: Int; let credentials: WebDAVCredentials; let folder: String; let file: ListedFile; let output: EpisodeNumbering.Output }
        var numbered: [NumberedRow] = []
        var seasonsByKey: [String: Set<Int>] = [:]
        for item in input.accounts {
            guard let remoteID = item.account.remoteID else { continue }
            for folder in item.listing.folders {
                let entry = overrides[folder.name] ?? [:]
                let key = rowSet.folderKeys[folder.name]
                let inputs = folder.files.map { EpisodeNumbering.Input(name: $0.name, decodedPath: $0.decodedPath, size: $0.size) }
                for (file, output) in zip(folder.files, EpisodeNumbering.number(rootName: folder.name, override: entry, files: inputs)) {
                    numbered.append(NumberedRow(accountID: remoteID, credentials: item.credentials, folder: folder.name, file: file, output: output))
                    if let key, let season = output.number.season { seasonsByKey[key, default: []].insert(season) }
                }
            }
        }

        // TMDB details.
        await report("Reading Supabase titles", 0.05)
        var remoteTitles: [String: JSONObject] = [:]
        for row in try await client.selectAll("titles", select: "key,tmdb_synced_at,episode_seasons", order: "key") {
            if let key = row["key"]?.stringValue { remoteTitles[key] = row }
        }
        var enrichedRows: [String: JSONObject] = [:]
        var fetched: [String: (details: JSONObject, episodes: [Int: [JSONObject]])] = [:]
        if let tmdb = input.tmdb {
            let todo = rowSet.rows.filter {
                needsTMDB($0.value, remote: remoteTitles[$0.key], seasons: seasonsByKey[$0.key] ?? [], refreshAll: input.mode == .refreshAll)
            }
            var done = 0
            try await withThrowingTaskGroup(of: (String, JSONObject, [Int: [JSONObject]])?.self) { group in
                for (key, row) in todo {
                    let type = row["media_type"]?.stringValue ?? "tvshow"
                    let id = row["tmdb_id"]?.stringValue ?? ""
                    let seasons = seasonsByKey[key] ?? []
                    group.addTask {
                        do {
                            let result = try await tmdb.details(type: type, id: id, seasons: seasons)
                            return (key, result.details, result.episodes)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            AppLog.write("Push: TMDB details for \(key) failed: \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
                for try await result in group {
                    done += 1
                    if let (key, details, episodes) = result, let row = rowSet.rows[key] {
                        let previous = (remoteTitles[key]?["episode_seasons"]?.arrayValue ?? []).compactMap(\.pythonInt)
                        enrichedRows[key] = enriched(row, details: details, episodes: episodes, previousSeasons: previous, syncedAt: runStarted)
                        fetched[key] = (details, episodes)
                    }
                    await report("TMDB details \(done)/\(todo.count)", 0.05 + 0.45 * Double(done) / Double(max(todo.count, 1)))
                }
            }
        } else {
            AppLog.write("Push: no TMDB token, skipping TMDB details")
        }
        stats["tmdb_fetched"] = .int(enrichedRows.count)
        try Task.checkCancellation()

        // Upload.
        await report("Uploading titles", 0.5)
        let run = try await client.insert("sync_runs", row: ["started_at": .string(runStarted)], returning: "id")
        try await client.upsert("accounts", rows: input.accounts.compactMap { item in
            guard let id = item.account.remoteID else { return nil }
            return ["id": .int(id), "name": .string(item.account.name), "webdav_url": .string(WebDAV.normalizedBaseURL(item.account.baseURL)), "username": .string(item.account.username)]
        }, onConflict: "id")

        let titleRows = rowSet.rows.map { enrichedRows[$0.key] ?? $0.value }
        var titleIDs: [String: Int] = [:]
        for row in try await client.upsert("titles", rows: titleRows, onConflict: "key", returning: "id,key") {
            if let key = row["key"]?.stringValue, let id = Py.int(row["id"]) { titleIDs[key] = id }
        }
        stats["titles"] = .int(titleIDs.count)

        await report("Uploading seasons and episodes", 0.6)
        var seasonRowsAll: [JSONObject] = []
        var episodeRowsAll: [JSONObject] = []
        for (key, value) in fetched where rowSet.rows[key]?["media_type"]?.stringValue == "tvshow" {
            guard let titleID = titleIDs[key] else { continue }
            seasonRowsAll += seasonRows(titleID: titleID, details: value.details)
            episodeRowsAll += episodeRows(titleID: titleID, episodes: value.episodes)
        }
        try await client.upsert("seasons", rows: seasonRowsAll, onConflict: "title_id,season_number")
        try await client.upsert("episodes", rows: episodeRowsAll, onConflict: "title_id,season_number,episode_number")
        stats["seasons"] = .int(seasonRowsAll.count)
        stats["episodes"] = .int(episodeRowsAll.count)

        await report("Uploading overrides and subtitles", 0.7)
        var overrideRowsAll: [JSONObject] = []
        var subtitleRowsAll: [JSONObject] = []
        for (folder, entry) in overrides.sorted(by: { $0.key < $1.key }) {
            let titleID = rowSet.folderKeys[folder].flatMap { titleIDs[$0] }
            overrideRowsAll.append(overrideRow(folder, entry, titleID: titleID, syncedAt: runStarted))
            subtitleRowsAll += subtitleRows(folder, entry, titleID: titleID, syncedAt: runStarted)
        }
        try await client.upsert("overrides", rows: overrideRowsAll, onConflict: "folder_name")
        try await client.upsert("subtitles", rows: subtitleRowsAll, onConflict: "folder_name,url")
        stats["overrides"] = .int(overrideRowsAll.count)
        stats["subtitles"] = .int(subtitleRowsAll.count)
        stats["overrides_deleted"] = 0
        if deleteOverrides {
            if !stale.isEmpty {
                stats["overrides_deleted"] = .int(try await client.delete("overrides", filters: [("synced_at", "lt.\(runStarted)")]))
            }
            // Only when every remote override was just pushed; otherwise kept ones would lose theirs.
            _ = try await client.delete("subtitles", filters: [("synced_at", "lt.\(runStarted)")])
        }

        await report("Uploading files", 0.8)
        let fileRows: [JSONObject] = numbered.map { row in
            let titleID = rowSet.folderKeys[row.folder].flatMap { titleIDs[$0] }
            return [
                "account_id": .int(row.accountID),
                "folder_name": .string(row.folder),
                "title_id": Py.number(titleID),
                "remote_path": .string(URLText.unquote(URLText.path(of: row.file.fullURL))),
                "file_name": .string(row.file.name),
                "size_bytes": .int(Int(row.file.size)),
                "season_number": Py.number(row.output.number.season),
                "episode_number": Py.number(row.output.number.episode),
                "is_main": .bool(row.output.isMain),
                "webdav_url": .string(row.file.fullURL),
                "stream_url": .string(WebDAV.authedURL(row.file.fullURL, username: row.credentials.username, password: row.credentials.password)),
                "last_seen_at": .string(runStarted),
            ]
        }
        try await client.upsert("media_files", rows: fileRows, onConflict: "account_id,remote_path")
        stats["files"] = .int(fileRows.count)
        var filesDeleted = 0
        for item in input.accounts where item.listing.complete {
            guard let id = item.account.remoteID else { continue }
            filesDeleted += try await client.delete("media_files", filters: [("account_id", "eq.\(id)"), ("last_seen_at", "lt.\(runStarted)")])
        }
        stats["files_deleted"] = .int(filesDeleted)

        // Accounts removed on this device.
        var deletedTombstones: [Int] = []
        let liveIDs = Set(input.accounts.compactMap(\.account.remoteID))
        for id in input.tombstones where !liveIDs.contains(id) {
            _ = try await client.delete("accounts", filters: [("id", "eq.\(id)")])
            deletedTombstones.append(id)
        }

        await report("Cleaning up", 0.95)
        stats["titles_pruned"] = .int(Py.int(try await client.rpc("prune_orphan_titles")) ?? 0)
        var unidentified = 0
        for item in input.accounts {
            unidentified += item.listing.folders.filter { rowSet.folderKeys[$0.name] == nil }.count
        }
        stats["unidentified_folders"] = .int(unidentified)
        stats["incomplete_accounts"] = .array(input.accounts.filter { !$0.listing.complete }.map { .string($0.account.name) })

        if let runID = Py.int(run["id"]) {
            try await client.update("sync_runs", values: ["finished_at": .string(nowISO()), "stats": .object(stats)], filters: [("id", "eq.\(runID)")])
        }
        await report("Done", 1.0)
        return (stats, deletedTombstones)
    }
}

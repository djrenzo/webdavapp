import Foundation

/// A card in Continue watching or Keep going.
struct WatchingItem: Identifiable {
    let id: String
    let title: GalleryTitle
    let episode: EpisodeKey?
    let episodeTitle: String?
    /// nil when the episode isn't in the library (Keep going only).
    let file: GalleryFile?
    /// 0–100, Continue watching only.
    let progress: Double?
    let playbackID: Int?
    let date: Date?

    var label: String {
        var parts: [String] = []
        if let episode { parts.append(episode.description) }
        if let progress { parts.append("\(Int(progress.rounded()))%") }
        if file == nil { parts.append("not in library") }
        return parts.joined(separator: " · ")
    }
}

extension AppModel {
    /// After every catalog reload: cached aired data, completeness and the watching rows.
    func libraryChanged() async {
        let ids = showTMDBIDs
        aired = await AiredEpisodeCache.shared.cached(ids)
        updateCompleteness()
        updateWatching()
    }

    private var showTMDBIDs: [String] {
        snapshot.titles.filter { !$0.isMovie }.compactMap(\.tmdbID)
    }

    // MARK: Completeness

    /// Fetch aired episode counts from TMDB for shows that are missing or stale.
    func loadAiredEpisodes(force: Bool = false) async {
        guard !isLoadingAired, let tmdb = try? TMDBClient.fromKeychain() else { return }
        let ids = showTMDBIDs
        guard !ids.isEmpty else { return }
        isLoadingAired = true
        defer { isLoadingAired = false }
        _ = await AiredEpisodeCache.shared.refresh(ids, tmdb: tmdb, force: force)
        aired = await AiredEpisodeCache.shared.cached(ids)
        updateCompleteness()
        updateWatching()
    }

    func updateCompleteness() {
        var result: [String: CompletenessReport] = [:]
        for item in snapshot.titles where !item.isMovie {
            guard let id = item.tmdbID, let aired = aired[id] else { continue }
            result[item.id] = CompletenessReport.make(aired: aired, present: item.presentEpisodes)
        }
        completeness = result
    }

    // MARK: Trakt

    var traktClientID: String {
        get { UserDefaults.standard.string(forKey: "trakt.clientID") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "trakt.clientID") }
    }

    /// Pull watched history and paused items. Skipped when synced in the last two minutes
    /// unless forced.
    func syncTrakt(force: Bool = false) async {
        guard isTraktConnected, !isSyncingTrakt, let client = TraktClient.configured() else { return }
        if !force, let last = lastTraktSync, Date().timeIntervalSince(last) < 120 { return }
        isSyncingTrakt = true
        defer { isSyncingTrakt = false }
        do {
            let state = try await client.sync()
            trakt = state
            lastTraktSync = Date()
            traktError = nil
            LocalFile.save(state, TraktState.fileName)
            updateWatching()
        } catch {
            traktError = error.localizedDescription
            AppLog.write("Trakt sync failed: \(error.localizedDescription)")
            if TraktToken.load() == nil { isTraktConnected = false }
        }
    }

    func traktDidConnect() async {
        isTraktConnected = true
        await syncTrakt(force: true)
        noticeMessage = trakt.username.map { "Connected to Trakt as \($0)." } ?? "Connected to Trakt."
    }

    func disconnectTrakt() async {
        await TraktClient.configured()?.revoke()
        Secrets.setTraktToken(nil)
        isTraktConnected = false
        trakt = TraktState()
        LocalFile.remove(TraktState.fileName)
        updateWatching()
    }

    func isWatched(_ item: GalleryTitle) -> Bool {
        guard item.isMovie else { return false }
        return trakt.movie(tmdbID: item.tmdbID, imdbID: item.imdbID) != nil
    }

    func watchedEpisodes(_ item: GalleryTitle) -> Set<EpisodeKey> {
        trakt.show(tmdbID: item.tmdbID, imdbID: item.imdbID)?.watchedKeys ?? []
    }

    func playback(_ item: GalleryTitle, episode: EpisodeKey?) -> TraktPlayback? {
        trakt.playback.first { $0.ids.matches(tmdbID: item.tmdbID, imdbID: item.imdbID) && $0.episode == episode && $0.isMovie == item.isMovie }
    }

    /// Mark a movie watched or unwatched on Trakt.
    func setWatched(movie item: GalleryTitle, _ watched: Bool) async {
        await sendHistory(TraktParser.movieBody(item.traktIDs), remove: !watched)
    }

    /// Mark episodes, whole seasons, or (both empty) the whole show.
    func setWatched(show item: GalleryTitle, episodes: [EpisodeKey] = [], seasons: [Int] = [], _ watched: Bool) async {
        let whole = episodes.isEmpty && seasons.isEmpty
        await sendHistory(TraktParser.showBody(item.traktIDs, episodes: whole ? nil : episodes, seasons: seasons), remove: !watched)
    }

    private func sendHistory(_ body: JSONObject, remove: Bool) async {
        guard isTraktConnected, let client = TraktClient.configured() else {
            alertMessage = TraktError.notConnected.localizedDescription
            return
        }
        do {
            try await client.history(body, remove: remove)
            await syncTrakt(force: true)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func removePlayback(_ id: Int) async {
        guard let client = TraktClient.configured() else { return }
        do {
            try await client.removePlayback(id)
            trakt.playback.removeAll { $0.id == id }
            LocalFile.save(trakt, TraktState.fileName)
            updateWatching()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Rows

    func updateWatching() {
        guard isTraktConnected else {
            continueWatching = []
            keepGoing = []
            return
        }
        let titles = snapshot.titles
        func title(for ids: TraktIDs, movie: Bool) -> GalleryTitle? {
            titles.first { $0.isMovie == movie && ids.matches(tmdbID: $0.tmdbID, imdbID: $0.imdbID) }
        }

        var resume: [WatchingItem] = []
        var pausedEpisodes: [String: Set<EpisodeKey>] = [:]
        for paused in trakt.playback where paused.progress >= 1 {
            guard let item = title(for: paused.ids, movie: paused.isMovie) else { continue }
            let file = paused.episode.flatMap { item.file(for: $0)?.file } ?? (paused.isMovie ? item.mainFile : nil)
            guard let file else { continue }
            if let episode = paused.episode { pausedEpisodes[item.id, default: []].insert(episode) }
            resume.append(WatchingItem(
                id: "resume-\(paused.id)", title: item, episode: paused.episode, episodeTitle: paused.episodeTitle,
                file: file, progress: paused.progress, playbackID: paused.id, date: paused.pausedAt
            ))
        }
        continueWatching = resume

        var next: [WatchingItem] = []
        for show in trakt.shows {
            guard let item = title(for: show.ids, movie: false) else { continue }
            let present = item.presentEpisodes
            let order = item.tmdbID.flatMap { aired[$0]?.keys } ?? []
            guard let pick = UpNext.pick(watched: show, order: order, present: present),
                  !(pausedEpisodes[item.id]?.contains(pick.next) ?? false) else { continue }
            next.append(WatchingItem(
                id: "next-\(item.id)", title: item, episode: pick.next, episodeTitle: nil,
                file: item.file(for: pick.next)?.file, progress: nil, playbackID: nil, date: show.lastWatchedAt
            ))
        }
        // Playable ones first, each group by last watched.
        keepGoing = next.sorted { lhs, rhs in
            if (lhs.file != nil) != (rhs.file != nil) { return lhs.file != nil }
            return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
        }
    }
}

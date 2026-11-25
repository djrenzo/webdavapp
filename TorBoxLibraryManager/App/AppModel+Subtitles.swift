import Foundation

extension AppModel {
    /// Languages offered first when searching (Settings → Subtitles).
    var subtitleLanguages: [String] {
        get { UserDefaults.standard.stringArray(forKey: "subtitles.languages") ?? ["en"] }
        set { UserDefaults.standard.set(newValue, forKey: "subtitles.languages") }
    }

    /// Save a pick in the folder's `subs`, the way the Kodi addon does, after checking that
    /// its link downloads. Replaces an earlier pick for the same video and language.
    func addSubtitle(_ result: SubtitleSearchResult, folder: GalleryFolder, episode: EpisodeKey?) async throws {
        guard let url = result.url else { throw SubtitleError.noPermanentLink }
        _ = try await OpenSubtitlesClient.verify(url)
        let latest = await store.overrides[folder.name] ?? folder.entry
        let fileName = SubtitleEntries.fileName(for: latest, episode: episode, language: result.language)
        await setOverride(folder.name, SubtitleEntries.adding(result.entry(fileName: fileName), to: latest))
        noticeMessage = "\(result.languageName) subtitle saved\(episode.map { " for \($0)" } ?? ""). It syncs with the next push."
    }

    func removeSubtitle(_ subtitle: SavedSubtitle, folder: GalleryFolder) async {
        let latest = await store.overrides[folder.name] ?? folder.entry
        await setOverride(folder.name, SubtitleEntries.removing(url: subtitle.url, from: latest))
    }

    /// Subtitles saved for one file: by SxxEyy for an episode, all of the folder's for a movie.
    func subtitles(for file: GalleryFile, in item: GalleryTitle) -> [SavedSubtitle] {
        guard let folder = item.folder(containing: file) else { return [] }
        if item.isMovie { return SubtitleEntries.saved(folder.entry) }
        guard let key = file.number.key else { return [] }
        return SubtitleEntries.saved(folder.entry, episode: key)
    }
}

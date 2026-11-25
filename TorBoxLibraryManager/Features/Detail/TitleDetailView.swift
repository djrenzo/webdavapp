import SwiftUI
import UIKit

struct TitleDetailView: View {
    let model: AppModel
    let titleID: String
    @State private var metadata: TitleMetadata?
    @State private var selectedSeason: Int?
    @State private var playFile: GalleryFile?
    @State private var showFixMatch = false
    @State private var showSetSeason = false
    @State private var showFolders = false
    @State private var subtitleFile: SubtitleTargetRef?
    @State private var showSubtitleOverview = false

    private var item: GalleryTitle? { model.snapshot.titles.first { $0.id == titleID } }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                ContentUnavailableView(
                    "This title changed",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("Its match was edited. Go back to the library to find it again.")
                )
            }
        }
        .background(CinemaTheme.background)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ item: GalleryTitle) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(item)
                if !item.isMovie, let report = model.completeness[item.id] {
                    MissingEpisodesPanel(report: report)
                }
                if item.isMovie {
                    movieFiles(item)
                } else {
                    showEpisodes(item)
                }
            }
            .padding(.bottom, 30)
        }
        .navigationTitle(item.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actionsMenu(item) }
        }
        .task(id: item.id) { await loadMetadata(item) }
        .confirmationDialog(playFile?.name ?? "Play", isPresented: Binding(
            get: { playFile != nil }, set: { if !$0 { playFile = nil } }
        ), titleVisibility: .visible, presenting: playFile) { file in
            PlayButtons(model: model, file: file)
        }
        .sheet(isPresented: $showFixMatch) { FixMatchView(model: model, folders: item.folders) }
        .sheet(isPresented: $showSetSeason) { SetSeasonView(model: model, folders: item.folders) }
        .sheet(isPresented: $showFolders) { FoldersSheet(item: item) }
        .sheet(item: $subtitleFile) { ref in SubtitleManagerView(model: model, titleID: item.id, fileID: ref.file.id) }
        .sheet(isPresented: $showSubtitleOverview) { SubtitleOverviewView(model: model, titleID: item.id) }
    }

    // MARK: Header

    private func header(_ item: GalleryTitle) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: metadata?.fanartURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [CinemaTheme.elevated, CinemaTheme.background], startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(height: 190)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.clear, CinemaTheme.background], startPoint: .center, endPoint: .bottom)
                }
                HStack(alignment: .bottom, spacing: 14) {
                    PosterArtwork(url: item.posterURL, title: item.title, isMovie: item.isMovie)
                        .frame(width: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.15)) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.title2.weight(.bold)).lineLimit(3)
                        Text(subtitle(item)).font(.subheadline).foregroundStyle(CinemaTheme.secondary)
                        if let genres = metadata?.genres, !genres.isEmpty {
                            Text(genres.joined(separator: " · ")).font(.caption).foregroundStyle(CinemaTheme.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .offset(y: 60)
            }
            .padding(.bottom, 60)

            VStack(alignment: .leading, spacing: 10) {
                if let tagline = metadata?.tagline {
                    Text(tagline).font(.subheadline.italic()).foregroundStyle(CinemaTheme.secondary)
                }
                if let plot = metadata?.plot ?? item.plot {
                    Text(plot).font(.callout)
                }
                badges(item)
            }
            .padding(.horizontal, 16)
        }
    }

    private func subtitle(_ item: GalleryTitle) -> String {
        var parts: [String] = [item.isMovie ? "Movie" : "Show"]
        if let year = item.year { parts.append(String(year)) }
        if let rating = metadata?.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        if let runtime = metadata?.runtime, runtime > 0 { parts.append("\(runtime) min") }
        if let status = metadata?.status, !item.isMovie { parts.append(status) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func badges(_ item: GalleryTitle) -> some View {
        let manual = item.folders.contains { Overrides.isManual($0.entry) }
        HStack(spacing: 8) {
            if model.isWatched(item) {
                capsule("Watched", color: CinemaTheme.green)
            }
            capsule(manual ? "Manual match" : "Automatic match", color: manual ? CinemaTheme.blue : CinemaTheme.secondary)
            if item.accountIDs.count > 1 { capsule("\(item.accountIDs.count) accounts", color: CinemaTheme.secondary) }
            if item.episodesNeedingSeason > 0 {
                Button { showSetSeason = true } label: {
                    capsule("\(item.episodesNeedingSeason) episodes need a season", color: CinemaTheme.amber)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func capsule(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(CinemaTheme.surface, in: Capsule())
    }

    // MARK: Movie

    private func movieFiles(_ item: GalleryTitle) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(item.folders) { folder in
                VStack(alignment: .leading, spacing: 8) {
                    folderHeader(folder)
                    let files = folder.files.sorted { ($0.isMain ? 0 : 1, $0.name) < ($1.isMain ? 0 : 1, $1.name) }
                    ForEach(files) { file in
                        fileRow(file, title: file.isMain ? "Main file" : file.name, subtitle: file.isMain ? "\(file.name) · \(file.sizeLabel)" : file.sizeLabel, item: item)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func folderHeader(_ folder: GalleryFolder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(folder.accountName.uppercased()).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(CinemaTheme.blue)
            Text(folder.name).font(.caption).foregroundStyle(CinemaTheme.secondary).lineLimit(2)
        }
    }

    // MARK: Show

    private func showEpisodes(_ item: GalleryTitle) -> some View {
        let files = item.folders.flatMap(\.files)
        let numbered = files.filter(\.number.isNumbered)
        let seasons = Array(Set(numbered.compactMap(\.number.season))).sorted()
        let extras = files.filter { !$0.number.isNumbered }
        let season = selectedSeason.flatMap { seasons.contains($0) ? $0 : nil } ?? seasons.first
        let episodes = numbered.filter { $0.number.season == season }
            .sorted { ($0.number.episode ?? 0, $0.name) < ($1.number.episode ?? 0, $1.name) }
        let watched = model.watchedEpisodes(item)

        return VStack(alignment: .leading, spacing: 14) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { number in
                            Button { selectedSeason = number } label: {
                                Text(number == 0 ? "Specials" : "Season \(number)")
                                    .font(.footnote.weight(number == season ? .semibold : .regular))
                                    .foregroundStyle(number == season ? CinemaTheme.background : CinemaTheme.text)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 36)
                                    .background(number == season ? CinemaTheme.blue : CinemaTheme.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if let season {
                Text(season == 0 ? "Specials" : "Season \(season)").font(.headline)
            }
            if let season, model.isTraktConnected {
                seasonWatchBar(item, season: season, episodes: episodes)
            }
            ForEach(episodes) { file in
                episodeRow(file, season: season, item: item, watched: watched)
            }
            if !extras.isEmpty {
                Text("Extras").font(.headline).padding(.top, 8)
                ForEach(extras) { file in
                    fileRow(file, title: file.name, subtitle: file.number.needsSeason ? "Episode \(file.number.episode ?? 0) · season needed · \(file.sizeLabel)" : file.sizeLabel, item: nil)
                }
            }
            if files.isEmpty {
                Text("No video files in this title’s folders.").foregroundStyle(CinemaTheme.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    private func seasonWatchBar(_ item: GalleryTitle, season: Int, episodes: [GalleryFile]) -> some View {
        let watched = model.watchedEpisodes(item)
        let keys = episodes.compactMap(\.number.key)
        let seen = keys.filter { watched.contains($0) }.count
        let all = !keys.isEmpty && seen == keys.count
        return HStack {
            Text("\(seen) of \(keys.count) watched").font(.caption).foregroundStyle(CinemaTheme.secondary)
            Spacer()
            Button(all ? "Mark season unwatched" : "Mark season watched") {
                Task { await model.setWatched(show: item, seasons: [season], !all) }
            }
            .font(.caption.weight(.medium))
            .disabled(model.isSyncingTrakt)
        }
    }

    private func episodeRow(_ file: GalleryFile, season: Int?, item: GalleryTitle, watched: Set<EpisodeKey>) -> some View {
        let info = season.flatMap { metadata?.episodes[$0]?[file.number.episode ?? -1] }
        let key = file.number.key
        let isWatched = key.map { watched.contains($0) } ?? false
        let paused = key.flatMap { model.playback(item, episode: $0) }
        let subs = SubtitleEntries.active(model.subtitles(for: file, in: item))
        return Button { playFile = file } label: {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: info?.stillURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            CinemaTheme.surface
                            Text("E\(file.number.episode ?? 0)").font(.headline).foregroundStyle(CinemaTheme.secondary)
                        }
                    }
                }
                .frame(width: 112, height: 63)
                .overlay(alignment: .bottom) {
                    if let paused { ProgressBar(fraction: paused.progress / 100).padding(4) }
                }
                .overlay(alignment: .topTrailing) {
                    if isWatched {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, CinemaTheme.green)
                            .padding(4)
                            .accessibilityLabel("Watched")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(isWatched ? 0.7 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(file.number.episode ?? 0). \(info?.name ?? "Episode \(file.number.episode ?? 0)")")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if let air = info?.airDate {
                        Text(air).font(.caption).foregroundStyle(CinemaTheme.secondary)
                    }
                    Text("\(file.name) · \(file.sizeLabel)")
                        .font(.caption2)
                        .foregroundStyle(CinemaTheme.secondary)
                        .lineLimit(2)
                    if !subs.isEmpty { SubtitleBadges(subs: subs) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Subtitles…", systemImage: "captions.bubble") { subtitleFile = SubtitleTargetRef(file: file) }
            if model.isTraktConnected, let key {
                Button(isWatched ? "Mark unwatched" : "Mark watched", systemImage: isWatched ? "eye.slash" : "eye") {
                    Task { await model.setWatched(show: item, episodes: [key], !isWatched) }
                }
                if let paused {
                    Button("Remove from Continue watching", systemImage: "xmark.circle") { Task { await model.removePlayback(paused.id) } }
                }
            }
        }
    }

    private func fileRow(_ file: GalleryFile, title: String, subtitle: String, item: GalleryTitle?) -> some View {
        let subs = item.map { SubtitleEntries.active(model.subtitles(for: file, in: $0)) } ?? []
        let paused = item.flatMap { $0.isMovie && file.isMain ? model.playback($0, episode: nil) : nil }
        return Button { playFile = file } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(CinemaTheme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(CinemaTheme.secondary).lineLimit(2)
                    if !file.subfolder.isEmpty {
                        Label(file.subfolder, systemImage: "folder").font(.caption2).foregroundStyle(CinemaTheme.secondary).lineLimit(1)
                    }
                    if !subs.isEmpty { SubtitleBadges(subs: subs) }
                    if let paused {
                        ProgressBar(fraction: paused.progress / 100).frame(maxWidth: 160).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                if item != nil {
                    Button { subtitleFile = SubtitleTargetRef(file: file) } label: {
                        Image(systemName: "captions.bubble").font(.title3).foregroundStyle(CinemaTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Subtitles")
                }
            }
            .padding(12)
            .background(CinemaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item != nil {
                Button("Subtitles…", systemImage: "captions.bubble") { subtitleFile = SubtitleTargetRef(file: file) }
            }
            if let paused {
                Button("Remove from Continue watching", systemImage: "xmark.circle") { Task { await model.removePlayback(paused.id) } }
            }
        }
    }

    // MARK: Actions

    private func actionsMenu(_ item: GalleryTitle) -> some View {
        let manual = item.folders.contains { Overrides.isManual($0.entry) }
        return Menu {
            Button("Fix match", systemImage: "wand.and.stars") { showFixMatch = true }
            if !item.isMovie {
                Button("Set season", systemImage: "number") { showSetSeason = true }
            }
            if manual {
                Button("Reset to automatic", systemImage: "arrow.uturn.backward") { setSource(item, "auto") }
            } else {
                Button("Mark as manual", systemImage: "hand.raised") { setSource(item, "manual") }
            }
            Button("Show folders", systemImage: "folder") { showFolders = true }
            Section {
                if item.isMovie, let main = item.mainFile {
                    Button("Subtitles", systemImage: "captions.bubble") { subtitleFile = SubtitleTargetRef(file: main) }
                }
                Button("All subtitles", systemImage: "list.bullet.rectangle") { showSubtitleOverview = true }
            }
            if model.isTraktConnected {
                Section("Trakt") {
                    if item.isMovie {
                        let watched = model.isWatched(item)
                        Button(watched ? "Mark unwatched" : "Mark watched", systemImage: watched ? "eye.slash" : "eye") {
                            Task { await model.setWatched(movie: item, !watched) }
                        }
                    } else {
                        Button("Mark all episodes in library watched", systemImage: "eye") {
                            Task { await model.setWatched(show: item, episodes: Array(item.presentEpisodes.filter { $0.season > 0 }), true) }
                        }
                        Button("Mark whole show watched", systemImage: "checkmark.circle") {
                            Task { await model.setWatched(show: item, true) }
                        }
                        Button("Mark show unwatched", systemImage: "eye.slash") {
                            Task { await model.setWatched(show: item, false) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Title actions")
    }

    private func setSource(_ item: GalleryTitle, _ source: String) {
        Task {
            for folder in item.folders where Overrides.isIdentified(folder.entry) {
                var entry = folder.entry
                entry["source"] = .string(source)
                await model.setOverride(folder.name, entry)
            }
        }
    }

    private func loadMetadata(_ item: GalleryTitle) async {
        let seasons = Set(item.folders.flatMap(\.files).compactMap(\.number.season))
        metadata = await TitleMetadata.load(key: item.id, mediaType: item.mediaType, tmdbID: item.tmdbID, seasons: seasons, settings: model.settings)
    }
}

/// The play menu (§10): installed players only, plus Copy stream URL.
struct PlayButtons: View {
    let model: AppModel
    let file: GalleryFile

    var body: some View {
        if let stream = model.streamURL(for: file) {
            let encoded = URLText.queryValue(stream)
            if let infuse = URL(string: "infuse://x-callback-url/play?url=\(encoded)"), canOpen("infuse://") {
                Button("Play in Infuse") { UIApplication.shared.open(infuse) }
            }
            if let vlc = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)"), canOpen("vlc-x-callback://") {
                Button("Play in VLC") { UIApplication.shared.open(vlc) }
            }
            Button("Copy stream URL") { UIPasteboard.general.string = stream }
        } else {
            Button("No password saved for this account", role: .cancel) {}
        }
    }

    private func canOpen(_ scheme: String) -> Bool {
        guard let url = URL(string: scheme) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

struct FoldersSheet: View {
    let item: GalleryTitle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(item.folders) { folder in
                    Section(folder.accountName) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(folder.name).font(.subheadline)
                            Text("\(folder.files.count) files · \(Overrides.isManual(folder.entry) ? "manual" : "automatic")")
                                .font(.caption).foregroundStyle(CinemaTheme.secondary)
                            if let season = Overrides.season(folder.entry) {
                                Text("Season \(season)\(Overrides.forceSeason(folder.entry) ? " (replaces file numbers)" : "")")
                                    .font(.caption).foregroundStyle(CinemaTheme.secondary)
                            }
                        }
                        .textSelection(.enabled)
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The panel at the top of a show: which aired seasons and episodes the library lacks.
struct MissingEpisodesPanel: View {
    let report: CompletenessReport
    @State private var expanded = false

    var body: some View {
        Group {
            if report.isComplete {
                Label("All \(report.airedCount) aired episodes are in your library", systemImage: "checkmark.seal.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(CinemaTheme.green)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CinemaTheme.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            } else if report.missingCount > 0 {
                let lines = report.lines
                VStack(alignment: .leading, spacing: 8) {
                    Label(summary, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CinemaTheme.amber)
                    ForEach(expanded ? lines : Array(lines.prefix(4)), id: \.season) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text("Season \(line.season)").font(.caption.weight(.semibold)).frame(width: 74, alignment: .leading)
                            Text(line.text).font(.caption).foregroundStyle(CinemaTheme.secondary)
                        }
                    }
                    if lines.count > 4 {
                        Button(expanded ? "Show less" : "Show all \(lines.count) seasons") { expanded.toggle() }
                            .font(.caption.weight(.medium))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CinemaTheme.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(CinemaTheme.amber.opacity(0.35)) }
            }
        }
        .padding(.horizontal, 16)
    }

    private var summary: String {
        var parts: [String] = []
        if !report.missingSeasons.isEmpty {
            parts.append(report.missingSeasons.count == 1 ? "1 season" : "\(report.missingSeasons.count) seasons")
        }
        let partial = report.missingEpisodes.filter { !report.missingSeasons.contains($0.key) }.values.reduce(0) { $0 + $1.count }
        if partial > 0 { parts.append(partial == 1 ? "1 episode" : "\(partial) episodes") }
        return "Missing " + parts.joined(separator: " and ") + " of \(report.airedCount) aired"
    }
}

struct SubtitleBadges: View {
    let subs: [SavedSubtitle]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "captions.bubble.fill").font(.caption2).foregroundStyle(CinemaTheme.secondary)
            ForEach(subs) { sub in
                Text(sub.language.uppercased())
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(CinemaTheme.blue)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitles: " + subs.map(\.languageName).joined(separator: ", "))
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(CinemaTheme.blue).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent watched")
    }
}

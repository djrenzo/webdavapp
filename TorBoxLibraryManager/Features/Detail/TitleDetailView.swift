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
                        fileRow(file, title: file.isMain ? "Main file" : file.name, subtitle: file.isMain ? "\(file.name) · \(file.sizeLabel)" : file.sizeLabel)
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
            ForEach(episodes) { file in
                episodeRow(file, season: season)
            }
            if !extras.isEmpty {
                Text("Extras").font(.headline).padding(.top, 8)
                ForEach(extras) { file in
                    fileRow(file, title: file.name, subtitle: file.number.needsSeason ? "Episode \(file.number.episode ?? 0) · season needed · \(file.sizeLabel)" : file.sizeLabel)
                }
            }
            if files.isEmpty {
                Text("No video files in this title’s folders.").foregroundStyle(CinemaTheme.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    private func episodeRow(_ file: GalleryFile, season: Int?) -> some View {
        let info = season.flatMap { metadata?.episodes[$0]?[file.number.episode ?? -1] }
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
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ file: GalleryFile, title: String, subtitle: String) -> some View {
        Button { playFile = file } label: {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(CinemaTheme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(subtitle).font(.caption).foregroundStyle(CinemaTheme.secondary).lineLimit(2)
                    if !file.subfolder.isEmpty {
                        Label(file.subfolder, systemImage: "folder").font(.caption2).foregroundStyle(CinemaTheme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(CinemaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

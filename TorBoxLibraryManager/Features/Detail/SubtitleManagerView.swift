import SwiftUI
import UIKit

/// What a subtitle sheet is about: a movie file or one episode.
struct SubtitleTargetRef: Identifiable {
    let file: GalleryFile
    var id: String { file.id }
}

/// Subtitles of one movie or episode: the saved ones (one per language), and an
/// OpenSubtitles search to add more.
struct SubtitleManagerView: View {
    let model: AppModel
    let titleID: String
    let fileID: String
    @Environment(\.dismiss) private var dismiss
    @State private var languages: Set<String> = []
    @State private var results: [SubtitleSearchResult] = []
    @State private var isSearching = false
    @State private var savingID: String?
    @State private var message: String?
    @State private var searched = false
    @State private var showLanguages = false

    private var item: GalleryTitle? { model.snapshot.titles.first { $0.id == titleID } }
    private var file: GalleryFile? { item?.folders.flatMap(\.files).first { $0.id == fileID } }
    private var folder: GalleryFolder? { file.flatMap { item?.folder(containing: $0) } }
    private var episode: EpisodeKey? { item?.isMovie == false ? file?.number.key : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let item, let file, let folder {
                    form(item, file, folder)
                } else {
                    ContentUnavailableView("This file is gone", systemImage: "questionmark.folder")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle(episode.map { "Subtitles · \($0)" } ?? "Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if languages.isEmpty { languages = Set(model.subtitleLanguages) } }
            .sheet(isPresented: $showLanguages) { LanguagePicker(selection: $languages) }
        }
        .preferredColorScheme(.dark)
    }

    private func form(_ item: GalleryTitle, _ file: GalleryFile, _ folder: GalleryFolder) -> some View {
        let saved = model.subtitles(for: file, in: item)
        let active = Set(SubtitleEntries.active(saved).map(\.url))
        return Form {
            Section {
                Text(file.name).font(.footnote).foregroundStyle(CinemaTheme.secondary).textSelection(.enabled)
            }
            .listRowBackground(CinemaTheme.surface)

            Section {
                if saved.isEmpty {
                    Text("No subtitles yet.").foregroundStyle(CinemaTheme.secondary)
                }
                ForEach(saved) { sub in
                    SavedSubtitleRow(subtitle: sub, isActive: active.contains(sub.url))
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await model.removeSubtitle(sub, folder: folder) } }
                        }
                        .contextMenu {
                            Button("Copy link", systemImage: "link") { UIPasteboard.general.string = sub.url }
                            Button("Remove", systemImage: "trash", role: .destructive) { Task { await model.removeSubtitle(sub, folder: folder) } }
                        }
                }
            } header: {
                Text("Saved")
            } footer: {
                Text("Saved with this folder’s match, so Kodi and Supabase get them on the next push. Swipe to remove.")
            }
            .listRowBackground(CinemaTheme.surface)

            Section {
                Button { showLanguages = true } label: {
                    LabeledContent("Languages", value: languages.sorted().map(SubtitleLanguages.name).joined(separator: ", "))
                }
                .foregroundStyle(CinemaTheme.text)
                Button {
                    Task { await search(item) }
                } label: {
                    HStack {
                        Label("Search OpenSubtitles", systemImage: "magnifyingglass")
                        if isSearching { Spacer(); ProgressView() }
                    }
                }
                .disabled(languages.isEmpty || isSearching)
            } header: {
                Text("Add")
            }
            .listRowBackground(CinemaTheme.surface)

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(CinemaTheme.amber) }
                    .listRowBackground(CinemaTheme.surface)
            }

            if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { result in
                        Button { Task { await choose(result, folder: folder) } } label: {
                            ResultRow(result: result, isSaving: savingID == result.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(result.url == nil || savingID != nil)
                    }
                }
                .listRowBackground(CinemaTheme.surface)
            } else if searched && !isSearching && message == nil {
                Section { Text("No subtitles found in these languages.").foregroundStyle(CinemaTheme.secondary) }
                    .listRowBackground(CinemaTheme.surface)
            }
        }
    }

    private func search(_ item: GalleryTitle) async {
        isSearching = true
        message = nil
        defer { isSearching = false; searched = true }
        model.subtitleLanguages = languages.sorted()
        do {
            let target = SubtitleTarget(tmdbID: item.tmdbID, imdbID: item.imdbID, episode: episode)
            results = try await OpenSubtitlesClient.fromKeychain().search(target, languages: languages.sorted())
            if Secrets.openSubtitlesKey() == nil {
                message = "Searching the free mirror only. Add an OpenSubtitles API key in Settings for release names, download counts and better results."
            }
        } catch {
            results = []
            message = error.localizedDescription
        }
    }

    private func choose(_ result: SubtitleSearchResult, folder: GalleryFolder) async {
        savingID = result.id
        defer { savingID = nil }
        do {
            try await model.addSubtitle(result, folder: folder, episode: episode)
            message = nil
            results.removeAll { $0.id == result.id }
        } catch {
            message = error.localizedDescription
        }
    }
}

struct SavedSubtitleRow: View {
    let subtitle: SavedSubtitle
    var isActive = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(subtitle.language.uppercased())
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(CinemaTheme.background)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(isActive ? CinemaTheme.blue : CinemaTheme.secondary, in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(subtitle.languageName).font(.subheadline.weight(.medium))
                    if subtitle.hearingImpaired { Image(systemName: "ear").font(.caption).accessibilityLabel("Hearing impaired") }
                    if !isActive { Text("replaced").font(.caption2).foregroundStyle(CinemaTheme.secondary) }
                }
                Text(subtitle.fileName).font(.caption).foregroundStyle(CinemaTheme.secondary).lineLimit(2)
                if let adjustments = subtitle.adjustments {
                    Label(adjustments, systemImage: "timer").font(.caption2).foregroundStyle(CinemaTheme.secondary)
                }
            }
        }
    }
}

private struct ResultRow: View {
    let result: SubtitleSearchResult
    let isSaving: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(result.language.uppercased())
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(CinemaTheme.blue)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.release ?? result.fileName).font(.subheadline).lineLimit(3)
                HStack(spacing: 8) {
                    if result.hearingImpaired { Label("HI", systemImage: "ear") }
                    if result.trusted { Label("Trusted", systemImage: "checkmark.seal") }
                    if let downloads = result.downloads { Label(downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle") }
                    if let fps = result.fps { Text(String(format: "%g fps", fps)) }
                }
                .font(.caption2)
                .foregroundStyle(CinemaTheme.secondary)
                if result.machineTranslated {
                    Text("Machine translated").font(.caption2).foregroundStyle(CinemaTheme.amber)
                }
                if result.url == nil {
                    Text("No permanent link — can’t be saved").font(.caption2).foregroundStyle(CinemaTheme.amber)
                }
            }
            Spacer(minLength: 0)
            if isSaving { ProgressView() } else if result.url != nil {
                Image(systemName: "plus.circle.fill").foregroundStyle(CinemaTheme.blue)
            }
        }
        .opacity(result.url == nil ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

struct LanguagePicker: View {
    @Binding var selection: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(SubtitleLanguages.all) { language in
                Button {
                    if selection.contains(language.code) { selection.remove(language.code) } else { selection.insert(language.code) }
                } label: {
                    HStack {
                        Text(language.name).foregroundStyle(CinemaTheme.text)
                        Spacer()
                        if selection.contains(language.code) { Image(systemName: "checkmark").foregroundStyle(CinemaTheme.blue) }
                    }
                }
                .listRowBackground(CinemaTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

/// Every saved subtitle of a title, per episode (shows) or per folder (movies).
struct SubtitleOverviewView: View {
    let model: AppModel
    let titleID: String
    @Environment(\.dismiss) private var dismiss

    private var item: GalleryTitle? { model.snapshot.titles.first { $0.id == titleID } }

    var body: some View {
        NavigationStack {
            List {
                if let item {
                    let groups = groups(item)
                    if groups.isEmpty {
                        Text("No subtitles saved for this title. Open a movie file or an episode to add some.")
                            .foregroundStyle(CinemaTheme.secondary)
                            .listRowBackground(CinemaTheme.surface)
                    }
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.subs, id: \.sub.url) { pair in
                                SavedSubtitleRow(subtitle: pair.sub)
                                    .swipeActions {
                                        Button("Remove", role: .destructive) { Task { await model.removeSubtitle(pair.sub, folder: pair.folder) } }
                                    }
                            }
                        }
                        .listRowBackground(CinemaTheme.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("All subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private struct SubGroup {
        let title: String
        let order: EpisodeKey
        var subs: [(sub: SavedSubtitle, folder: GalleryFolder)]
    }

    private func groups(_ item: GalleryTitle) -> [SubGroup] {
        var byKey: [String: SubGroup] = [:]
        for folder in item.folders {
            for sub in SubtitleEntries.saved(folder.entry) {
                let title: String
                let order: EpisodeKey
                if item.isMovie {
                    title = "\(folder.accountName) · \(folder.name)"
                    order = EpisodeKey(season: 0, episode: 0)
                } else if let episode = sub.episode {
                    title = episode.description
                    order = episode
                } else {
                    title = "Not linked to an episode"
                    order = EpisodeKey(season: 999, episode: 0)
                }
                byKey[title, default: SubGroup(title: title, order: order, subs: [])].subs.append((sub, folder))
            }
        }
        return byKey.values.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
    }
}

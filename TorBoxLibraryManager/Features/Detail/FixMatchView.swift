import SwiftUI

/// §9.3: search TMDB and write a manual match for one folder.
struct FixMatchView: View {
    let model: AppModel
    let folders: [GalleryFolder]
    @Environment(\.dismiss) private var dismiss
    @State private var folderID: String = ""
    @State private var query = ""
    @State private var mediaType = "tvshow"
    @State private var year = ""
    @State private var results: [ScoredResult] = []
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var message: String?

    private var folder: GalleryFolder? { folders.first { $0.id == folderID } ?? folders.first }

    var body: some View {
        NavigationStack {
            Form {
                if folders.count > 1 {
                    Section {
                        Picker("Folder", selection: $folderID) {
                            ForEach(folders) { folder in
                                Text("\(folder.accountName) · \(folder.name)").tag(folder.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    } footer: {
                        Text("The match is saved for this folder only.")
                    }
                    .listRowBackground(CinemaTheme.surface)
                } else if let folder {
                    Section("Folder") {
                        Text(folder.name).font(.footnote).textSelection(.enabled)
                    }
                    .listRowBackground(CinemaTheme.surface)
                }

                Section("Search TMDB") {
                    TextField("Title", text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Picker("Type", selection: $mediaType) {
                        Text("Movie").tag("movie")
                        Text("Show").tag("tvshow")
                    }
                    .pickerStyle(.segmented)
                    TextField("Year (optional)", text: $year)
                        .keyboardType(.numberPad)
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Text("Search")
                            if isSearching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
                .listRowBackground(CinemaTheme.surface)

                if let message {
                    Section { Text(message).foregroundStyle(CinemaTheme.amber) }
                        .listRowBackground(CinemaTheme.surface)
                }

                if !results.isEmpty {
                    Section("Results") {
                        ForEach(Array(results.enumerated()), id: \.offset) { pair in
                            Button { Task { await choose(pair.element) } } label: { resultRow(pair.element) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(CinemaTheme.surface)
                }

                Section {
                    Button("Not a movie or show", role: .destructive) { Task { await markIgnored() } }
                } footer: {
                    Text("Keeps this folder out of automatic identification.")
                }
                .listRowBackground(CinemaTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Fix match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .disabled(isSaving)
            .onAppear(perform: prefill)
            .onChange(of: folderID) { _, _ in prefill() }
        }
        .preferredColorScheme(.dark)
    }

    private func resultRow(_ result: ScoredResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PosterArtwork(
                url: TMDBClient.image(result.result["poster_path"]?.stringValue, size: "w185").flatMap(URL.init(string:)),
                title: result.displayTitle, isMovie: result.mediaType == "movie"
            )
            .frame(width: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(result.displayTitle).font(.subheadline.weight(.semibold))
                Text([result.year.map(String.init), result.mediaType == "movie" ? "Movie" : "Show"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(CinemaTheme.secondary)
                if let overview = Py.text(result.result["overview"]) {
                    Text(overview).font(.caption).foregroundStyle(CinemaTheme.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func prefill() {
        if folderID.isEmpty, let first = folders.first { folderID = first.id }
        guard let folder else { return }
        let parsed = ReleaseParser.parse(folder.name)
        query = Overrides.title(folder.entry) ?? parsed.title
        year = (Overrides.year(folder.entry) ?? parsed.year).map(String.init) ?? ""
        mediaType = Overrides.mediaType(folder.entry) ?? (parsed.tvHint ? "tvshow" : "movie")
        results = []
        message = nil
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        message = nil
        do {
            let tmdb = try TMDBClient.fromKeychain()
            let yearValue = Int(year.trimmingCharacters(in: .whitespaces))
            let found = try await tmdb.search(type: mediaType, query: text, year: yearValue)
            results = found.map { result in
                let (total, similarity, resultYear) = Identifier.score(query: text, year: yearValue, result: result, mediaType: mediaType)
                return ScoredResult(total: total, similarity: similarity, year: resultYear, result: result, mediaType: mediaType)
            }
            if results.isEmpty { message = "No results. Try another title, type or year." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func choose(_ result: ScoredResult) async {
        guard let folder, let tmdb = try? TMDBClient.fromKeychain() else { return }
        isSaving = true
        defer { isSaving = false }
        let match = await Identifier.buildEntry(tmdb, result, source: "manual")
        let latest = await model.store.overrides[folder.name]
        await model.setOverride(folder.name, Overrides.manualEntry(from: match, existing: latest ?? folder.entry))
        dismiss()
    }

    private func markIgnored() async {
        guard let folder else { return }
        await model.setOverride(folder.name, ["title": .string(folder.name), "type": "movie", "source": "manual"])
        dismiss()
    }
}

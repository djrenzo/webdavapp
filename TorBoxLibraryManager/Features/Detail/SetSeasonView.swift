import SwiftUI

/// §9.4: season override for one folder, with a live numbering preview.
struct SetSeasonView: View {
    let model: AppModel
    let folders: [GalleryFolder]
    @Environment(\.dismiss) private var dismiss
    @State private var folderID = ""
    @State private var season = ""
    @State private var force = false
    @State private var isSaving = false

    private var folder: GalleryFolder? { folders.first { $0.id == folderID } ?? folders.first }
    private var seasonValue: Int? { Int(season.trimmingCharacters(in: .whitespaces)) }
    private var isValid: Bool { season.trimmingCharacters(in: .whitespaces).isEmpty || (seasonValue.map { (0...99).contains($0) } ?? false) }

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
                        Text("Seasons are set per folder.")
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
                Section {
                    HStack {
                        Text("Season")
                        Spacer()
                        TextField("Automatic", text: $season)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Replace season numbers in file names", isOn: $force)
                        .disabled(seasonValue == nil)
                } footer: {
                    Text(isValid ? "Without replacement, the season only applies to files whose names carry no season." : "Enter a season between 0 and 99, or leave it empty.")
                }
                .listRowBackground(CinemaTheme.surface)

                if let folder {
                    Section("Preview") {
                        ForEach(Array(preview(folder).enumerated()), id: \.offset) { pair in
                            let row = pair.element
                            HStack(alignment: .firstTextBaseline) {
                                Text(label(row.1))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(row.1.needsSeason ? CinemaTheme.amber : (row.1.isNumbered ? CinemaTheme.blue : CinemaTheme.secondary))
                                    .frame(width: 92, alignment: .leading)
                                Text(row.0.name).font(.caption).lineLimit(2)
                            }
                        }
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Set season")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!isValid || isSaving || folder == nil)
                }
            }
            .onAppear(perform: load)
            .onChange(of: folderID) { _, _ in load() }
        }
        .preferredColorScheme(.dark)
    }

    private func edited(_ entry: JSONObject) -> JSONObject {
        var entry = entry
        if let seasonValue {
            entry["season"] = .int(seasonValue)
            entry["force_season"] = .bool(force)
        } else {
            entry.removeValue(forKey: "season")
            entry.removeValue(forKey: "force_season")
        }
        return entry
    }

    private func preview(_ folder: GalleryFolder) -> [(GalleryFile, EpisodeNumber)] {
        let entry = edited(folder.entry)
        let inputs = folder.files.map { file in
            EpisodeNumbering.Input(name: file.name, decodedPath: folder.path + (file.subfolder.isEmpty ? "" : file.subfolder + "/") + file.name, size: file.size)
        }
        let outputs = EpisodeNumbering.number(rootName: folder.name, override: entry, files: inputs)
        return zip(folder.files, outputs.map(\.number)).sorted { lhs, rhs in
            (lhs.1.season ?? 999, lhs.1.episode ?? 999, lhs.0.name) < (rhs.1.season ?? 999, rhs.1.episode ?? 999, rhs.0.name)
        }
    }

    private func label(_ number: EpisodeNumber) -> String {
        if let season = number.season, let episode = number.episode { return "S\(season) · E\(episode)" }
        if let episode = number.episode { return "E\(episode) · no season" }
        return "Extra"
    }

    private func load() {
        if folderID.isEmpty, let first = folders.first { folderID = first.id }
        guard let folder else { return }
        season = Overrides.season(folder.entry).map(String.init) ?? ""
        force = Overrides.forceSeason(folder.entry)
    }

    private func save() async {
        guard let folder else { return }
        isSaving = true
        defer { isSaving = false }
        let latest = await model.store.overrides[folder.name] ?? folder.entry
        let entry = edited(latest)
        await model.setOverride(folder.name, entry.isEmpty ? nil : entry)
        dismiss()
    }
}

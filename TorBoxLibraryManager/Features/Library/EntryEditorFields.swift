import SwiftUI

struct EntryEditorFields: View {
    @Binding var draft: EntryDraft

    var body: some View {
        metadataSection
        folderSection
        if draft.mediaType != "movie" { seasonSection }
        filesSection
    }

    private var metadataSection: some View {
        Section("Identification") {
            TextField("Title", text: $draft.title)
                .accessibilityLabel("Title")
            Picker("Media type", selection: $draft.mediaType) {
                Text("Movie").tag("movie")
                Text("Show").tag("tvshow")
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Year")
                Spacer()
                TextField("Optional", text: $draft.year)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Year")
            }
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private var folderSection: some View {
        Section {
            TextField("Folder name", text: $draft.folderName, axis: .vertical)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityLabel("Folder name")
        } header: {
            Text("Folder name")
        } footer: {
            Text("Folder names are override keys. Renaming keeps all saved fields and updates the local sample paths.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private var seasonSection: some View {
        Section {
            HStack {
                Text("Season")
                Spacer()
                TextField("Automatic", text: $draft.season)
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Folder season")
            }
            Toggle("Replace season numbers in file names", isOn: $draft.forceSeason)
            numberingStatus
        } header: {
            Text("Season override")
        } footer: {
            Text("Without replacement, file and nearest-subfolder season markers win. Leave the field blank to use existing markers.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private var numberingStatus: some View {
        let count = draft.files.filter { draft.numbering(for: $0).needsSeason }.count
        let text = count > 0 ? "\(count) episodes need a season" : "Episode numbering ready"
        let symbol = count > 0 ? "exclamationmark.circle.fill" : "checkmark.circle"
        return Label(text, systemImage: symbol)
            .font(.footnote)
            .foregroundStyle(count > 0 ? CinemaTheme.amber : CinemaTheme.blue)
    }

    private var filesSection: some View {
        let mainID = draft.files.max { $0.size < $1.size }?.id
        return Section {
            ForEach($draft.files) { $file in
                FileLabelEditor(
                    file: $file, isMovie: draft.mediaType == "movie",
                    numbering: draft.numbering(for: file), isMain: file.id == mainID
                )
            }
        } header: {
            Text("File labels & live preview")
        } footer: {
            Text("These are editable sample records, not playable files. Numbering updates as you edit.")
        }
        .listRowBackground(CinemaTheme.surface)
    }
}

private struct FileLabelEditor: View {
    @Binding var file: FileDraft
    let isMovie: Bool
    let numbering: EpisodeNumber
    let isMain: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("File name", text: $file.name, axis: .vertical)
                .font(.subheadline)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityLabel("File name")
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "folder").foregroundStyle(CinemaTheme.secondary)
                TextField("Subfolder (optional)", text: $file.subfolder, axis: .vertical)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityLabel("Subfolder for \(file.name)")
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline) {
                previewLabel
                Spacer(minLength: 4)
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .foregroundStyle(CinemaTheme.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var previewLabel: some View {
        if isMovie {
            Label(isMain ? "Main file" : "Additional file", systemImage: isMain ? "film.fill" : "film")
                .foregroundStyle(isMain ? CinemaTheme.blue : CinemaTheme.secondary)
        } else {
            Label(numbering.label, systemImage: numbering.needsSeason ? "exclamationmark.circle.fill" : "tv")
                .foregroundStyle(numbering.needsSeason ? CinemaTheme.amber : CinemaTheme.blue)
        }
    }
}

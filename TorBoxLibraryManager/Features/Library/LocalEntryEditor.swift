import SwiftUI

struct LocalEntryEditor: View {
    let item: GalleryTitle
    let model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EntryDraft?
    @State private var originalDraft: EntryDraft?
    @State private var selectedFolder: FolderSnapshot?
    @State private var pendingFolder: FolderSnapshot?
    @State private var showDiscard = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let binding = Binding($draft) {
                    summary
                    if item.folders.count > 1 { folderSelector }
                    EntryEditorFields(draft: binding)
                } else {
                    Text("This folder couldn’t be opened. Close the editor and try again.")
                        .foregroundStyle(CinemaTheme.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Edit catalog entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
            .alert("Couldn’t save your changes", isPresented: errorBinding) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "Please try again.") }
            .confirmationDialog("Discard this folder’s unsaved edits?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard and switch folder", role: .destructive, action: switchToPendingFolder)
                Button("Keep editing", role: .cancel) { pendingFolder = nil }
            }
            .task { if draft == nil, let first = item.folders.first { openFolder(first) } }
        }
        .preferredColorScheme(.dark)
    }

    private var summary: some View {
        Section {
            HStack(spacing: 14) {
                PosterArtwork(url: item.posterURL, title: item.title, isMovie: item.isMovie)
                    .frame(width: 52).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.headline)
                    Text("\(item.folders.count) \(item.folders.count == 1 ? "folder" : "folders") · \(item.fileCount) sample files")
                        .font(.caption).foregroundStyle(CinemaTheme.secondary)
                    Label("Local demo entry", systemImage: "externaldrive")
                        .font(.caption).foregroundStyle(CinemaTheme.blue)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Edits are saved as manual matches. Subtitle picks and other saved override fields stay untouched.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    private var folderSelector: some View {
        Section {
            Menu {
                ForEach(item.folders) { folder in
                    Button { requestFolder(folder) } label: {
                        if folder.id == selectedFolder?.id {
                            Label("\(folder.accountName) · \(folder.name)", systemImage: "checkmark")
                        } else {
                            Text("\(folder.accountName) · \(folder.name)")
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Editing folder").foregroundStyle(CinemaTheme.secondary)
                        Spacer()
                        Text(selectedFolder?.accountName ?? "").foregroundStyle(CinemaTheme.blue)
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    Text(selectedFolder?.name ?? "Choose a folder")
                        .font(.subheadline).foregroundStyle(CinemaTheme.text)
                }
                .padding(.vertical, 3)
            }
        } footer: {
            Text("Edit one folder at a time. Titles stay grouped by their saved IDs; changing the media type creates a separate group.")
        }
        .listRowBackground(CinemaTheme.surface)
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
            Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                .fontWeight(.semibold)
                .disabled(draft == nil || isSaving)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    private func requestFolder(_ folder: FolderSnapshot) {
        guard folder.id != selectedFolder?.id else { return }
        if draft != originalDraft {
            pendingFolder = folder
            showDiscard = true
        } else { openFolder(folder) }
    }

    private func switchToPendingFolder() {
        if let pendingFolder { openFolder(pendingFolder) }
        pendingFolder = nil
    }

    private func openFolder(_ folder: FolderSnapshot) {
        do {
            let newDraft = try EntryDraft(folder: folder)
            selectedFolder = folder
            draft = newDraft
            originalDraft = newDraft
        } catch { errorMessage = error.localizedDescription }
    }

    private func save() async {
        guard let draft, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.save(draft)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

import SwiftUI

/// §9.5: folders with no identified override, grouped by account.
struct UnidentifiedView: View {
    let model: AppModel
    @State private var fixFolder: UnidentifiedFolder?

    private var groups: [(String, [UnidentifiedFolder])] {
        let grouped = Dictionary(grouping: model.snapshot.unidentified, by: \.accountName)
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.isRefreshing {
                    RefreshStatusView(model: model)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                if model.snapshot.unidentified.isEmpty {
                    ContentUnavailableView(
                        "Nothing to identify",
                        systemImage: "checkmark.seal",
                        description: Text("Every listed folder has a match. New folders show up here after a refresh if TMDB can’t match them.")
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(groups, id: \.0) { group in
                    Section("\(group.0) · \(group.1.count)") {
                        ForEach(group.1) { folder in
                            Button { fixFolder = folder } label: { row(folder) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(CinemaTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CinemaTheme.background)
            .navigationTitle("Unidentified")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Identify again") {
                        model.identifyAgain(model.snapshot.unidentified.map(\.name))
                    }
                    .disabled(model.isRefreshing || model.snapshot.unidentified.isEmpty)
                }
            }
            .sheet(item: $fixFolder) { folder in
                FixMatchView(model: model, folders: [GalleryFolder(
                    accountID: folder.accountID, accountName: folder.accountName, name: folder.name,
                    path: folder.path, entry: folder.entry, files: []
                )])
            }
        }
    }

    private func row(_ folder: UnidentifiedFolder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(folder.name).font(.subheadline).lineLimit(3)
            Text("Searched as “\(folder.parsedTitle)”").font(.caption).foregroundStyle(CinemaTheme.secondary)
            Text(folder.reason).font(.caption).foregroundStyle(CinemaTheme.amber)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

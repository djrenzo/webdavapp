import SwiftUI

@main struct TorBoxLibraryApp: App {
    var body: some Scene {
        WindowGroup {
            CatalogRootView()
                .preferredColorScheme(.dark)
                .tint(CinemaTheme.blue)
        }
    }
}

struct CatalogRootView: View {
    @State private var model: LibraryModel?
    @State private var startupError: String?

    var body: some View {
        Group {
            if let model {
                LibraryView(model: model)
            } else if let startupError {
                ContentUnavailableView {
                    Label("Can’t open the demo library", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("\(startupError)\nYour saved data has not been replaced.")
                } actions: {
                    Button("Try again") { Task { await openLibrary() } }
                }
            } else {
                ProgressView("Opening your library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(CinemaTheme.background)
        .foregroundStyle(CinemaTheme.text)
        .task { if model == nil { await openLibrary() } }
    }

    private func openLibrary() async {
        startupError = nil
        do {
            let store = try await CatalogStore.open()
            let library = LibraryModel(repository: store)
            await library.load()
            model = library
        } catch { startupError = error.localizedDescription }
    }
}

import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedTitle: GalleryTitle?
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        libraryStatus
                        LibraryControls(model: model)
                        gallery(width: proxy.size.width)
                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(CinemaTheme.background)
            .navigationTitle("Library")
            .toolbar { libraryToolbar }
            .toolbarBackground(CinemaTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(item: $selectedTitle) { LocalEntryEditor(item: $0, model: model) }
            .confirmationDialog("Reset the demo library?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Reset demo library", role: .destructive) { Task { await model.resetDemo() } }
            } message: {
                Text("Your local demo edits will be replaced with the original sample titles. No online catalog is affected.")
            }
            .alert("Couldn’t load the library", isPresented: errorBinding) {
                Button("OK") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "Please try again.") }
        }
    }

    private var libraryStatus: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("DEMO LIBRARY")
                .font(.caption2.weight(.semibold)).tracking(1.1)
                .foregroundStyle(CinemaTheme.blue)
            Circle().fill(CinemaTheme.secondary.opacity(0.5)).frame(width: 3, height: 3)
            Text("\(model.titles.count) titles · \(model.folderCount) folders")
                .font(.caption).foregroundStyle(CinemaTheme.secondary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func gallery(width: CGFloat) -> some View {
        if model.isLoading {
            ProgressView("Opening local library…").frame(maxWidth: .infinity).padding(.top, 60)
        } else if model.visibleTitles.isEmpty {
            emptyState
        } else {
            let count = columnCount(width: width)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 11, alignment: .top), count: count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(model.visibleTitles) { item in
                    Button { selectedTitle = item } label: { PosterCard(item: item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func columnCount(width: CGFloat) -> Int {
        if typeSize.isAccessibilitySize { return width < 600 ? 2 : 4 }
        if width < 600 { return 3 }
        return min(8, max(5, Int((width - 32) / 140)))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No titles found", systemImage: "magnifyingglass")
        } description: {
            Text("Try another title or folder name, or clear your filters.")
        } actions: {
            Button("Clear filters", action: model.clearFilters).buttonStyle(.bordered)
        }
        .padding(.top, 30)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let message = model.statusMessage {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(CinemaTheme.blue)
            }
            Text("Tap a poster to edit its catalog entry.")
            Text("Saved on this device. Not connected to Kodi or Supabase.")
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(CinemaTheme.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Reset demo library", systemImage: "arrow.counterclockwise", role: .destructive) {
                    showResetConfirmation = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(CinemaTheme.text)
                    .frame(width: 40, height: 40)
                    .background(CinemaTheme.surface, in: Circle())
            }
            .accessibilityLabel("Library options")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

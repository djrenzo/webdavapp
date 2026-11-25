import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RefreshStatusView(model: model)
                        banners
                        LibraryControls(model: model)
                        gallery(width: proxy.size.width)
                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.refresh() }
            }
            .background(CinemaTheme.background)
            .navigationTitle("Library")
            .toolbar { toolbar }
            .toolbarBackground(CinemaTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationDestination(for: String.self) { key in
                if let title = model.snapshot.titles.first(where: { $0.id == key }) {
                    TitleDetailView(model: model, titleID: title.id)
                } else {
                    ContentUnavailableView("Title not found", systemImage: "film")
                }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if !model.snapshot.conflicts.isEmpty {
            NavigationLink {
                ConflictReviewView(model: model)
            } label: {
                bannerLabel("\(model.snapshot.conflicts.count) overrides differ from Supabase — Review", symbol: "arrow.triangle.branch")
            }
            .buttonStyle(.plain)
        }
        if let notice = model.noticeMessage {
            HStack(alignment: .top) {
                Label(notice, systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(CinemaTheme.blue)
                Spacer()
                Button {
                    model.noticeMessage = nil
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .foregroundStyle(CinemaTheme.secondary)
                .accessibilityLabel("Dismiss")
            }
        }
        ForEach(model.lastWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(CinemaTheme.amber)
        }
    }

    private func bannerLabel(_ text: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol)
            Text(text).multilineTextAlignment(.leading)
            Spacer()
            Image(systemName: "chevron.right").font(.caption)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(CinemaTheme.background)
        .padding(12)
        .background(CinemaTheme.amber, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func gallery(width: CGFloat) -> some View {
        if !model.isLoaded {
            ProgressView("Opening library…").frame(maxWidth: .infinity).padding(.top, 60)
        } else if model.snapshot.titles.isEmpty {
            emptyLibrary
        } else if model.visibleTitles.isEmpty {
            ContentUnavailableView {
                Label("No titles found", systemImage: "magnifyingglass")
            } description: {
                Text("Try another title or folder name, or clear your filters.")
            } actions: {
                Button("Clear filters", action: model.clearFilters).buttonStyle(.bordered)
            }
            .padding(.top, 30)
        } else {
            let count = columnCount(width: width)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 11, alignment: .top), count: count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(model.visibleTitles) { item in
                    NavigationLink(value: item.id) {
                        PosterCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "film.stack")
        } description: {
            if model.snapshot.accounts.isEmpty {
                Text("Add a TorBox WebDAV account in the Accounts tab, then pull down here to list and identify it.")
            } else {
                Text("Pull down to list your accounts and identify their folders. Unmatched folders appear in the Unidentified tab.")
            }
        } actions: {
            if !model.snapshot.accounts.isEmpty {
                Button("Refresh now") { model.refresh() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRefreshing)
            }
        }
        .padding(.top, 30)
    }

    private func columnCount(width: CGFloat) -> Int {
        if typeSize.isAccessibilitySize { return width < 600 ? 2 : 4 }
        if width < 600 { return 3 }
        return min(8, max(5, Int((width - 32) / 140)))
    }

    private var footer: some View {
        Text("\(model.snapshot.titles.count) titles · \(model.snapshot.folderCount) folders · \(model.snapshot.unidentified.count) unidentified")
            .font(.caption)
            .foregroundStyle(CinemaTheme.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .accessibilityLabel("Refresh library")
        }
    }
}

/// Thin progress bar with the current pipeline step (§9.1) and a Cancel button.
struct RefreshStatusView: View {
    let model: AppModel

    var body: some View {
        if model.isRefreshing, let progress = model.progress {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progress.step.rawValue).font(.footnote.weight(.semibold))
                    Spacer()
                    Button("Cancel", role: .cancel) { model.cancelRefresh() }
                        .font(.footnote)
                }
                ProgressView(value: min(max(progress.fraction, 0), 1))
                    .tint(CinemaTheme.blue)
                if !progress.detail.isEmpty {
                    Text(progress.detail)
                        .font(.caption)
                        .foregroundStyle(CinemaTheme.secondary)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .background(CinemaTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

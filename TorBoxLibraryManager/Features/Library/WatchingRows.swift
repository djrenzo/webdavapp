import SwiftUI

/// Continue watching (paused on Trakt) and Keep going (next episode after the last one
/// watched), above the gallery. Only with Trakt connected.
struct WatchingRows: View {
    let model: AppModel
    let open: (String) -> Void
    @State private var selected: WatchingItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.continueWatching.isEmpty {
                row("Continue watching", items: model.continueWatching)
            }
            if !model.keepGoing.isEmpty {
                row("Keep going", items: model.keepGoing)
            }
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), titleVisibility: .visible, presenting: selected) { item in
            if let file = item.file {
                PlayButtons(model: model, file: file)
            }
            Button(item.title.isMovie ? "Open movie" : "Open show") { open(item.title.id) }
            if let episode = item.episode {
                Button("Mark \(episode) watched") { Task { await model.setWatched(show: item.title, episodes: [episode], true) } }
            } else {
                Button("Mark watched") { Task { await model.setWatched(movie: item.title, true) } }
            }
            if let id = item.playbackID {
                Button("Remove from Continue watching", role: .destructive) { Task { await model.removePlayback(id) } }
            }
        }
    }

    private var dialogTitle: String {
        guard let selected else { return "" }
        return [selected.title.title, selected.episode?.description, selected.episodeTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func row(_ title: String, items: [WatchingItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 11) {
                    ForEach(items) { item in
                        Button { selected = item } label: { card(item) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func card(_ item: WatchingItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            PosterArtwork(url: item.title.posterURL, title: item.title.title, isMovie: item.title.isMovie)
                .overlay(alignment: .bottom) {
                    if let progress = item.progress {
                        ProgressBar(fraction: progress / 100).padding(6)
                    }
                }
                .overlay {
                    if item.file != nil {
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(item.file == nil ? 0.5 : 1)
            Text(item.title.title).font(.caption.weight(.medium)).lineLimit(1)
            Text(item.label).font(.caption2).foregroundStyle(item.file == nil ? CinemaTheme.amber : CinemaTheme.secondary).lineLimit(1)
        }
        .frame(width: 104)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title.title, item.episode?.description, item.label].compactMap { $0 }.joined(separator: ", "))
    }
}

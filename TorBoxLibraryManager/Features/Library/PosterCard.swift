import SwiftUI

struct PosterCard: View {
    let item: GalleryTitle
    var report: CompletenessReport? = nil
    var watched = false
    @ScaledMetric(relativeTo: .subheadline) private var captionHeight = 34.0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PosterArtwork(url: item.posterURL, title: item.title, isMovie: item.isMovie)
                .overlay(alignment: .bottomLeading) { badges.padding(6) }
                .overlay(alignment: .topTrailing) { cornerBadge.padding(6) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    // Green: every aired episode is in the library.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(report?.isComplete == true ? CinemaTheme.green : .white.opacity(0.12),
                                      lineWidth: report?.isComplete == true ? 2.5 : 0.75)
                }
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(CinemaTheme.text)
                .lineLimit(2)
                .frame(minHeight: captionHeight, alignment: .topLeading)
            Text(item.year.map(String.init) ?? "Year unknown")
                .font(.caption)
                .foregroundStyle(CinemaTheme.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the title details")
    }

    private var accessibilityText: String {
        let year = item.year.map { ", \($0)" } ?? ""
        let accounts = item.accountIDs.count > 1 ? ", \(item.accountIDs.count) accounts" : ""
        let seasons = item.episodesNeedingSeason > 0 ? ", \(item.episodesNeedingSeason) episodes need a season" : ""
        var status = ""
        if let report {
            if report.isComplete { status = ", all episodes present" } else if report.missingCount > 0 { status = ", \(report.missingCount) episodes missing" }
        }
        let seen = watched ? ", watched" : ""
        return item.title + year + accounts + seasons + status + seen
    }

    @ViewBuilder private var cornerBadge: some View {
        if let report, report.missingCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("\(report.missingCount)")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(CinemaTheme.background)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(CinemaTheme.amber, in: Capsule())
        } else if watched {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.white, CinemaTheme.green)
        }
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: 4) {
            if item.accountIDs.count > 1 {
                posterBadge("\(item.accountIDs.count) accounts", symbol: nil, warning: false)
            }
            if item.episodesNeedingSeason > 0 {
                posterBadge("Season needed", symbol: "exclamationmark.circle.fill", warning: true)
            }
        }
    }

    private func posterBadge(_ text: String, symbol: String?, warning: Bool) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).foregroundStyle(CinemaTheme.amber) }
            Text(text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

struct PosterArtwork: View {
    let url: URL?
    let title: String
    let isMovie: Bool
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    artwork
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            .accessibilityHidden(true)
            .task(id: url) { await loadImage() }
    }

    @ViewBuilder private var artwork: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            fallback
        }
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(
                colors: [CinemaTheme.elevated, isMovie ? Color(red: 0.22, green: 0.17, blue: 0.13) : Color(red: 0.12, green: 0.19, blue: 0.3), CinemaTheme.background],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 12) {
                Image(systemName: isMovie ? "film" : "tv")
                    .font(.title).foregroundStyle(.white.opacity(0.35))
                Text(title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                if url == nil { Text("NO POSTER").font(.caption2).tracking(1.5).foregroundStyle(CinemaTheme.secondary) }
            }
            .foregroundStyle(CinemaTheme.text)
            .padding(10)
        }
    }

    private func loadImage() async {
        image = nil
        guard let url, let data = try? await PosterCache.shared.data(for: url), !Task.isCancelled else { return }
        image = UIImage(data: data)
    }
}

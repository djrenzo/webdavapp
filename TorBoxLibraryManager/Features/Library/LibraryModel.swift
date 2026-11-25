import Foundation
import Observation

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", movies = "Movies", shows = "Shows"
    var id: String { rawValue }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently added", title = "Title", year = "Year"
    var id: String { rawValue }
    var shortLabel: String { self == .recent ? "Recent" : rawValue }
}

@MainActor @Observable final class LibraryModel {
    var search = "" { didSet { updateVisibleTitles() } }
    var filter = LibraryFilter.all { didSet { updateVisibleTitles() } }
    var accountID: UUID? { didSet { updateVisibleTitles() } }
    var sort = LibrarySort.recent { didSet { updateVisibleTitles() } }
    private(set) var accounts: [AccountLabel] = []
    private(set) var titles: [GalleryTitle] = []
    private(set) var visibleTitles: [GalleryTitle] = []
    private(set) var folderCount = 0
    private(set) var isLoading = true
    var errorMessage: String?
    var statusMessage: String?
    @ObservationIgnored private let repository: any CatalogRepository

    init(repository: any CatalogRepository) {
        self.repository = repository
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do { apply(try await repository.load()) }
        catch { errorMessage = error.localizedDescription }
    }

    func save(_ draft: EntryDraft) async throws {
        let snapshot = try await repository.save(draft)
        apply(snapshot)
        statusMessage = "Changes saved on this device"
    }

    func resetDemo() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await repository.resetDemo()
            search = ""
            filter = .all
            accountID = nil
            sort = .recent
            apply(snapshot)
            statusMessage = "Demo library restored"
        } catch { errorMessage = error.localizedDescription }
    }

    func clearFilters() {
        search = ""
        filter = .all
        accountID = nil
    }

    private func apply(_ snapshot: CatalogSnapshot) {
        accounts = snapshot.accounts
        titles = snapshot.titles
        folderCount = snapshot.folderCount
        updateVisibleTitles()
    }

    private func updateVisibleTitles() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = titles.filter { item in
            let typeMatches = filter == .all || (filter == .movies ? item.isMovie : !item.isMovie)
            let accountMatches = accountID.map { item.accountIDs.contains($0) } ?? true
            let searchMatches = query.isEmpty || item.searchText.localizedStandardContains(query)
            return typeMatches && accountMatches && searchMatches
        }
        result.sort { lhs, rhs in
            switch sort {
            case .recent:
                if lhs.firstSeenAt != rhs.firstSeenAt { return lhs.firstSeenAt > rhs.firstSeenAt }
            case .year:
                if lhs.year != rhs.year { return (lhs.year ?? 0) > (rhs.year ?? 0) }
            case .title: break
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        visibleTitles = result
    }
}

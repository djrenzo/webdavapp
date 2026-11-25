import Foundation
import Observation
import UIKit

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All", movies = "Movies", shows = "Shows"
    var id: String { rawValue }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently added", title = "Title", year = "Year"
    var id: String { rawValue }
    var shortLabel: String { self == .recent ? "Recent" : rawValue }
}

struct StaleRequest: Identifiable {
    let id = UUID()
    let folders: [String]
}

struct PushSummary: Identifiable {
    let id = UUID()
    let stats: JSONObject
    let warnings: [String]
}

@MainActor @Observable final class AppModel {
    let store: CatalogStore
    private(set) var snapshot = CatalogSnapshot()
    private(set) var visibleTitles: [GalleryTitle] = []
    private(set) var isLoaded = false

    var search = "" { didSet { updateVisibleTitles() } }
    var filter = LibraryFilter.all { didSet { updateVisibleTitles() } }
    var accountFilter: UUID? { didSet { updateVisibleTitles() } }
    var sort = LibrarySort.recent { didSet { updateVisibleTitles() } }

    var settings = AppSettings.load()
    private(set) var role: SupabaseRole = .notConfigured
    private(set) var keepAliveWarning: String?

    private(set) var isRefreshing = false
    private(set) var progress: RefreshProgress?
    private(set) var lastWarnings: [String] = []
    private var refreshTask: Task<Void, Never>?

    var alertMessage: String?
    var noticeMessage: String?
    var staleRequest: StaleRequest?
    var pushSummary: PushSummary?
    private var staleContinuation: CheckedContinuation<Bool, Never>?

    init(store: CatalogStore) {
        self.store = store
        role = settings.supabaseConfig == nil ? .notConfigured : .signedOut
    }

    // MARK: Catalog

    func reload() async {
        snapshot = await store.snapshot()
        isLoaded = true
        updateVisibleTitles()
    }

    func clearFilters() {
        search = ""
        filter = .all
        accountFilter = nil
    }

    private func updateVisibleTitles() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = snapshot.titles.filter { item in
            let typeMatches = filter == .all || (filter == .movies ? item.isMovie : !item.isMovie)
            let accountMatches = accountFilter.map { item.accountIDs.contains($0) } ?? true
            let searchMatches = query.isEmpty || item.searchText.localizedStandardContains(query)
            return typeMatches && accountMatches && searchMatches
        }
        result.sort { lhs, rhs in
            switch sort {
            case .recent:
                if lhs.latestSeen != rhs.latestSeen { return lhs.latestSeen > rhs.latestSeen }
            case .year:
                if lhs.year != rhs.year { return (lhs.year ?? 0) > (rhs.year ?? 0) }
            case .title:
                break
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        visibleTitles = result
    }

    func account(_ id: UUID) -> Account? {
        snapshot.accounts.first { $0.id == id }
    }

    // MARK: Refresh pipeline

    func refresh(_ options: RefreshOptions = RefreshOptions()) {
        guard !isRefreshing else { return }
        if snapshot.accounts.isEmpty && options.list && settings.supabaseConfig == nil {
            alertMessage = "Add a TorBox WebDAV account in the Accounts tab first."
            return
        }
        isRefreshing = true
        lastWarnings = []
        progress = RefreshProgress(step: .signIn, detail: "Starting", fraction: 0)
        let store = store
        let settings = settings
        refreshTask = Task { [weak self] in
            let background = UIApplication.shared.beginBackgroundTask(withName: "Refresh")
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                let result = try await RefreshPipeline.run(
                    store: store, settings: settings, options: options,
                    report: { progress in await self?.setProgress(progress) },
                    changed: { await self?.reload() },
                    confirmStale: { folders in await self?.askStale(folders) ?? false }
                )
                self?.finish(result)
            } catch is CancellationError {
                self?.noticeMessage = "Refresh cancelled."
                self?.finish(nil)
            } catch {
                AppLog.write("Refresh failed: \(error.localizedDescription)")
                self?.alertMessage = error.localizedDescription
                self?.finish(nil)
            }
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        if staleContinuation != nil { answerStale(false) }
    }

    private func setProgress(_ value: RefreshProgress) {
        progress = value
    }

    private func finish(_ result: RefreshResult?) {
        isRefreshing = false
        progress = nil
        refreshTask = nil
        Task { await reload() }
        guard let result else { return }
        if result.role != .notConfigured { role = result.role }
        lastWarnings = result.warnings
        for warning in result.warnings { AppLog.write(warning) }
        if let stats = result.pushStats {
            pushSummary = PushSummary(stats: stats, warnings: result.warnings)
        } else {
            var parts: [String] = []
            if let fetch = result.fetch, fetch.added > 0 { parts.append("\(fetch.added) overrides fetched") }
            if result.listedAccounts > 0 { parts.append("\(result.listedAccounts) accounts listed") }
            if result.identified > 0 { parts.append("\(result.identified) identified") }
            if result.unmatched > 0 { parts.append("\(result.unmatched) unmatched") }
            noticeMessage = parts.isEmpty ? (result.warnings.first ?? "Library is up to date.") : parts.joined(separator: " · ")
        }
    }

    private func askStale(_ folders: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            staleContinuation = continuation
            staleRequest = StaleRequest(folders: folders)
        }
    }

    func answerStale(_ delete: Bool) {
        staleContinuation?.resume(returning: delete)
        staleContinuation = nil
        staleRequest = nil
    }

    func identifyAgain(_ names: [String]) {
        refresh(RefreshOptions(onlyFolders: Set(names), list: false, identify: true, push: nil))
    }

    func reidentifyAutomatic() {
        refresh(RefreshOptions(redoAuto: true, list: false, identify: true, push: nil))
    }

    func fetchNow() {
        guard settings.supabaseConfig != nil else {
            alertMessage = "Fill in the Supabase settings first."
            return
        }
        refresh(RefreshOptions(list: false, identify: false, push: nil))
    }

    func pushNow(_ mode: PushMode) {
        guard settings.supabaseConfig != nil else {
            alertMessage = "Fill in the Supabase settings first."
            return
        }
        refresh(RefreshOptions(list: true, identify: false, push: mode, pushDespiteConflicts: true))
    }

    // MARK: Supabase

    func saveSupabase(_ newSettings: AppSettings, password: String?) {
        settings = newSettings
        settings.save()
        if let password { Secrets.setSupabasePassword(password) }
        Secrets.setSupabaseSession(nil)
        role = settings.supabaseConfig == nil ? .notConfigured : .signedOut
        Task { await checkSupabase() }
    }

    /// Sign in and check membership. Also the keep-alive ping (§8.3).
    func checkSupabase() async {
        guard let config = settings.supabaseConfig else {
            role = .notConfigured
            return
        }
        let client = SupabaseClient(config: config)
        do {
            if try await client.isMember() {
                role = try await client.isAdmin() ? .admin : .reader
            } else {
                role = .notMember
            }
            keepAliveWarning = nil
        } catch {
            role = .signedOut
            keepAliveWarning = "Supabase check failed: \(error.localizedDescription)"
            AppLog.write(keepAliveWarning ?? "")
        }
    }

    func signOut() {
        Secrets.setSupabaseSession(nil)
        Secrets.setSupabasePassword(nil)
        role = settings.supabaseConfig == nil ? .notConfigured : .signedOut
        noticeMessage = "Signed out of Supabase."
    }

    // MARK: Accounts

    func saveAccount(_ account: Account, password: String?) async {
        do {
            if let password, !password.isEmpty { Secrets.setWebDAVPassword(password, account: account.id) }
            try await store.saveAccount(account)
            if account.remoteID == nil, let config = settings.supabaseConfig {
                // Best effort; otherwise the id is resolved on the next push.
                let client = SupabaseClient(config: config)
                if let ids = try? await Push.resolveAccountIDs(client, accounts: await store.accounts), !ids.isEmpty {
                    try await store.setRemoteIDs(ids)
                }
            }
            await reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func setAccountEnabled(_ account: Account, _ enabled: Bool) async {
        var updated = account
        updated.isEnabled = enabled
        await saveAccount(updated, password: nil)
    }

    func deleteAccount(_ account: Account) async {
        do {
            try await store.deleteAccount(account.id)
            if accountFilter == account.id { accountFilter = nil }
            await reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Overrides

    func setOverride(_ folderName: String, _ entry: JSONObject?) async {
        do {
            try await store.setOverride(folderName, entry)
            await reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func resolveConflicts(useRemote: Set<String>, keepLocal: Set<String>) async {
        do {
            try await store.resolveConflicts(useRemote: useRemote, keepLocal: keepLocal)
            await reload()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func exportOverrides() async -> URL? {
        do {
            return try await store.exportOverrides()
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    func importOverrides(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let summary = try await store.importOverrides(data)
            await reload()
            noticeMessage = "Imported: \(summary.added) added, \(summary.conflicts) differ (kept local, review in Settings)."
        } catch {
            alertMessage = "Couldn’t import overrides: \(error.localizedDescription)"
        }
    }

    func clearCache() async {
        do {
            try await store.clearListings()
            URLCache.shared.removeAllCachedResponses()
            await PosterCache.shared.clear()
            await reload()
            noticeMessage = "Local listings and poster cache cleared. Pull to refresh to list your accounts again."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: Playback (§10)

    func streamURL(for file: GalleryFile) -> String? {
        guard let credentials = account(file.accountID)?.credentials else { return nil }
        return WebDAV.authedURL(file.fullURL, username: credentials.username, password: credentials.password)
    }
}

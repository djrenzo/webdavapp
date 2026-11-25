import Foundation

struct RefreshProgress: Sendable, Equatable {
    enum Step: String, Sendable {
        case signIn = "Signing in to Supabase"
        case fetch = "Fetching overrides"
        case list = "Listing accounts"
        case identify = "Identifying folders"
        case push = "Pushing to Supabase"
        case done = "Done"
    }

    var step: Step
    var detail: String
    /// 0...1 within the step
    var fraction: Double
}

struct RefreshOptions: Sendable {
    /// Identify only these folders (nil: every pending folder).
    var onlyFolders: Set<String>?
    /// Re-identify automatic matches too (never manual ones).
    var redoAuto = false
    var list = true
    var identify = true
    /// nil: don't push. Pushing still requires an admin login.
    var push: PushMode? = .changedOnly
    /// Skip the automatic push when fetched overrides differ and need review.
    var pushDespiteConflicts = false
}

struct RefreshResult: Sendable {
    var role: SupabaseRole = .notConfigured
    var fetch: FetchSummary?
    var listedAccounts = 0
    var incompleteAccounts: [String] = []
    var identified = 0
    var unmatched = 0
    var pushStats: JSONObject?
    var warnings: [String] = []
}

enum SupabaseRole: String, Sendable {
    case notConfigured = "Not configured"
    case signedOut = "Not signed in"
    case notMember = "Not a member"
    case reader = "Reader"
    case admin = "Admin"
}

/// The refresh pipeline (§6): sign in → fetch → list → identify → (admin) push.
enum RefreshPipeline {
    typealias Report = @Sendable (RefreshProgress) async -> Void
    typealias Changed = @Sendable () async -> Void

    static func run(store: CatalogStore, settings: AppSettings, options: RefreshOptions,
                    report: @escaping Report, changed: @escaping Changed,
                    confirmStale: @escaping Push.ConfirmStale) async throws -> RefreshResult {
        var result = RefreshResult()
        var client: SupabaseClient?

        // 1. Sign in.
        if let config = settings.supabaseConfig {
            await report(RefreshProgress(step: .signIn, detail: config.email, fraction: 0))
            let candidate = SupabaseClient(config: config)
            do {
                try await candidate.login()
                if try await candidate.isMember() {
                    result.role = try await candidate.isAdmin() ? .admin : .reader
                    client = candidate
                } else {
                    result.role = .notMember
                    result.warnings.append("\(config.email) isn't listed in Supabase members; working locally.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.role = .signedOut
                result.warnings.append("Supabase: \(error.localizedDescription)")
                AppLog.write("Supabase sign-in failed: \(error.localizedDescription)")
            }
        }

        // 2. Fetch overrides.
        if let client {
            await report(RefreshProgress(step: .fetch, detail: "Reading overrides", fraction: 0))
            let rows = try await client.selectAll("overrides", select: "folder_name,raw", order: "folder_name")
            var remote: [String: JSONObject] = [:]
            for row in rows {
                if let name = row["folder_name"]?.stringValue, let raw = row["raw"]?.objectValue { remote[name] = raw }
            }
            if !remote.isEmpty {
                result.fetch = try await store.mergeRemote(remote)
                await changed()
            }
        }
        try Task.checkCancellation()

        // 3. List accounts.
        let accounts = await store.accounts.filter(\.isEnabled)
        if options.list {
            for (position, account) in accounts.enumerated() {
                guard let credentials = account.credentials else {
                    try await store.setAccountError(account.id, "No password saved")
                    result.warnings.append("\(account.name): no password saved")
                    continue
                }
                let label = "\(account.name) (\(position + 1)/\(accounts.count))"
                await report(RefreshProgress(step: .list, detail: label, fraction: 0))
                do {
                    let listing = try await listAccount(account, credentials: credentials) { done, total in
                        await report(RefreshProgress(step: .list, detail: "\(label) · \(done)/\(total) folders", fraction: Double(done) / Double(max(total, 1))))
                    }
                    try await store.saveListing(listing)
                    result.listedAccounts += 1
                    if !listing.complete { result.incompleteAccounts.append(account.name) }
                    await changed()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await store.setAccountError(account.id, error.localizedDescription)
                    result.incompleteAccounts.append(account.name)
                    result.warnings.append("\(account.name): \(error.localizedDescription)")
                }
            }
        }
        try Task.checkCancellation()

        // 4. Identify.
        if options.identify {
            if let tmdb = try? TMDBClient.fromKeychain() {
                let identified = try await identify(store: store, tmdb: tmdb, options: options, report: report, changed: changed)
                result.identified = identified.matched
                result.unmatched = identified.unmatched
            } else {
                result.warnings.append("No TMDB token: new folders weren't identified.")
            }
        }
        try Task.checkCancellation()

        // 6. Push (admins only).
        if let mode = options.push, let client, result.role == .admin {
            let conflicts = await store.state.conflicts
            if !conflicts.isEmpty && !options.pushDespiteConflicts {
                result.warnings.append("\(conflicts.count) overrides differ from Supabase. Review them, then push from Settings.")
            } else {
                result.pushStats = try await push(store: store, client: client, mode: mode, report: report, confirmStale: confirmStale)
                await changed()
            }
        }
        await report(RefreshProgress(step: .done, detail: "", fraction: 1))
        return result
    }

    static func listAccount(_ account: Account, credentials: WebDAVCredentials,
                            progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> AccountListing {
        let roots = try await WebDAV.rootFolders(credentials)
        let limiter = AsyncLimiter(4)
        let now = Date()
        var folders: [ListedFolder] = []
        var complete = true
        var done = 0
        try await withThrowingTaskGroup(of: (ListedFolder, Bool).self) { group in
            for root in roots {
                group.addTask {
                    try await limiter.run {
                        let path = WebDAV.folderPath(root)
                        let walked = await WebDAV.walk(credentials, path: path)
                        let files = walked.files.map {
                            ListedFile(name: $0.name, path: $0.path, fullURL: $0.fullURL, size: $0.size, firstSeenAt: now)
                        }
                        return (ListedFolder(name: root.name, path: path, files: files), walked.complete)
                    }
                }
            }
            for try await (folder, ok) in group {
                folders.append(folder)
                complete = complete && ok
                done += 1
                await progress(done, roots.count)
            }
        }
        try Task.checkCancellation()
        return AccountListing(accountID: account.id, folders: folders.sorted { $0.name < $1.name }, complete: complete, listedAt: now)
    }

    /// Folders that still need identifying (`pending_folders`), each with the account to
    /// read it from.
    static func pendingFolders(store: CatalogStore, options: RefreshOptions) async -> [(name: String, path: String, credentials: WebDAVCredentials?)] {
        let overrides = await store.overrides
        let accounts = await store.accounts.filter(\.isEnabled)
        let listings = await store.listings
        var seen = Set<String>()
        var pending: [(String, String, WebDAVCredentials?)] = []
        for account in accounts {
            guard let listing = listings[account.id] else { continue }
            let credentials = account.credentials
            for folder in listing.folders where !seen.contains(folder.name) {
                if let only = options.onlyFolders, !only.contains(folder.name) { continue }
                let entry = overrides[folder.name] ?? [:]
                if Overrides.isManual(entry) { continue }
                if Overrides.isIdentified(entry) && !options.redoAuto { continue }
                seen.insert(folder.name)
                pending.append((folder.name, folder.path, credentials))
            }
        }
        return pending
    }

    static func identify(store: CatalogStore, tmdb: TMDBClient, options: RefreshOptions,
                         report: @escaping Report, changed: @escaping Changed) async throws -> (matched: Int, unmatched: Int) {
        let pending = await pendingFolders(store: store, options: options)
        guard !pending.isEmpty else { return (0, 0) }
        var matched = 0, unmatched = 0, done = 0
        var sinceRefresh = 0
        let limiter = AsyncLimiter(4)
        try await withThrowingTaskGroup(of: (String, IdentifyOutcome).self) { group in
            for folder in pending {
                group.addTask {
                    try await limiter.run {
                        do {
                            let outcome = try await Identifier.identify(tmdb, credentials: folder.credentials, folderName: folder.name, folderPath: folder.path)
                            return (folder.name, outcome)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            return (folder.name, .unmatched(reason: "Search failed: \(error.localizedDescription)"))
                        }
                    }
                }
            }
            for try await (name, outcome) in group {
                done += 1
                switch outcome {
                case .matched(let entry):
                    if try await store.mergeAutomatic([name: entry]) > 0 { matched += 1 }
                    sinceRefresh += 1
                case .unmatched(let reason):
                    try await store.setUnidentifiedReason(name, reason)
                    unmatched += 1
                }
                await report(RefreshProgress(step: .identify, detail: "\(done)/\(pending.count) · \(name)", fraction: Double(done) / Double(pending.count)))
                // Saved as they come in, so the gallery fills live.
                if sinceRefresh >= 10 {
                    sinceRefresh = 0
                    await changed()
                }
            }
        }
        await changed()
        return (matched, unmatched)
    }

    static func push(store: CatalogStore, client: SupabaseClient, mode: PushMode,
                     report: @escaping Report, confirmStale: @escaping Push.ConfirmStale) async throws -> JSONObject {
        await report(RefreshProgress(step: .push, detail: "Resolving account ids", fraction: 0))
        let enabled = await store.accounts.filter(\.isEnabled)
        let assigned = try await Push.resolveAccountIDs(client, accounts: enabled)
        if !assigned.isEmpty { try await store.setRemoteIDs(assigned) }
        let accounts = await store.accounts.filter(\.isEnabled)
        let listings = await store.listings
        var items: [(account: Account, credentials: WebDAVCredentials, listing: AccountListing)] = []
        for account in accounts {
            guard account.remoteID != nil, let credentials = account.credentials, let listing = listings[account.id] else { continue }
            items.append((account, credentials, listing))
        }
        let input = Push.Input(
            overrides: await store.overrides, accounts: items, tombstones: await store.state.tombstones,
            mode: mode, tmdb: try? TMDBClient.fromKeychain()
        )
        let (stats, deleted) = try await Push.run(client, input: input, report: { detail, fraction in
            await report(RefreshProgress(step: .push, detail: detail, fraction: fraction))
        }, confirmStale: confirmStale)
        if !deleted.isEmpty { try await store.clearTombstones(deleted) }
        try await store.recordPush(stats: stats)
        return stats
    }
}

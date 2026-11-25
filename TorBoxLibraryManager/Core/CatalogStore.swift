import Foundation

struct FetchSummary: Sendable {
    var remote = 0
    var added = 0
    var conflicts = 0
    var localOnly = 0
}

/// The local catalog, kept as plain files in Application Support:
/// `overrides.json` (exactly the Kodi addon's format), `accounts.json`, `state.json` and one
/// listing file per account.
actor CatalogStore {
    let directory: URL
    private(set) var overrides: [String: JSONObject] = [:]
    private(set) var accounts: [Account] = []
    private(set) var listings: [UUID: AccountListing] = [:]
    private(set) var state = CatalogState()

    init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TorBoxLibrary", isDirectory: true)
        self.directory = base
        try FileManager.default.createDirectory(at: base.appendingPathComponent("listings", isDirectory: true), withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: base.appendingPathComponent("overrides.json")) {
            let object = try JSONCoding.decodeObject(data)
            overrides = object.compactMapValues(\.objectValue)
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("accounts.json")) {
            accounts = try JSONDecoder().decode([Account].self, from: data)
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("state.json")) {
            state = (try? JSONDecoder().decode(CatalogState.self, from: data)) ?? CatalogState()
        }
        for account in accounts {
            let url = base.appendingPathComponent("listings/\(account.id.uuidString).json")
            if let data = try? Data(contentsOf: url), let listing = try? JSONDecoder().decode(AccountListing.self, from: data) {
                listings[account.id] = listing
            }
        }
    }

    var overridesURL: URL { directory.appendingPathComponent("overrides.json") }
    var backupURL: URL { directory.appendingPathComponent("overrides.backup.json") }

    // MARK: Persistence

    private func saveOverrides() throws {
        let data = try JSONCoding.encode(.object(overrides.mapValues { .object($0) }), pretty: true)
        try data.write(to: overridesURL, options: .atomic)
    }

    private func saveAccounts() throws {
        try JSONEncoder().encode(accounts).write(to: directory.appendingPathComponent("accounts.json"), options: .atomic)
    }

    private func saveState() throws {
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }

    private func backupOverrides() {
        do {
            let data = try JSONCoding.encode(.object(overrides.mapValues { .object($0) }), pretty: true)
            try data.write(to: backupURL, options: .atomic)
        } catch {
            AppLog.write("Could not back up overrides: \(error.localizedDescription)")
        }
    }

    // MARK: Accounts

    func saveAccount(_ account: Account) throws {
        var account = account
        account.baseURL = WebDAV.normalizedBaseURL(account.baseURL)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        try saveAccounts()
    }

    func deleteAccount(_ id: UUID) throws {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        accounts.removeAll { $0.id == id }
        listings.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("listings/\(id.uuidString).json"))
        if let remoteID = account.remoteID, !state.tombstones.contains(remoteID) {
            state.tombstones.append(remoteID)
        }
        Secrets.setWebDAVPassword(nil, account: id)
        try saveAccounts()
        try saveState()
    }

    func setRemoteIDs(_ ids: [UUID: Int]) throws {
        for (id, remote) in ids {
            if let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].remoteID == nil {
                accounts[index].remoteID = remote
            }
        }
        try saveAccounts()
    }

    func clearTombstones(_ ids: [Int]) throws {
        state.tombstones.removeAll { ids.contains($0) }
        try saveState()
    }

    // MARK: Listings

    /// Store a fresh listing, keeping each file's first-seen time.
    func saveListing(_ listing: AccountListing) throws {
        var listing = listing
        if let previous = listings[listing.accountID] {
            var seen: [String: Date] = [:]
            for folder in previous.folders { for file in folder.files { seen[file.path] = file.firstSeenAt } }
            for f in listing.folders.indices {
                for i in listing.folders[f].files.indices {
                    if let date = seen[listing.folders[f].files[i].path] { listing.folders[f].files[i].firstSeenAt = date }
                }
            }
        }
        listings[listing.accountID] = listing
        let data = try JSONEncoder().encode(listing)
        try data.write(to: directory.appendingPathComponent("listings/\(listing.accountID.uuidString).json"), options: .atomic)
        if let index = accounts.firstIndex(where: { $0.id == listing.accountID }) {
            accounts[index].lastListedAt = listing.listedAt
            accounts[index].lastListingComplete = listing.complete
            accounts[index].fileCount = listing.folders.reduce(0) { $0 + $1.files.count }
            accounts[index].lastError = listing.complete ? nil : accounts[index].lastError
            try saveAccounts()
        }
    }

    func setAccountError(_ id: UUID, _ message: String?) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].lastError = message
        try saveAccounts()
    }

    func clearListings() throws {
        listings = [:]
        let folder = directory.appendingPathComponent("listings", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in accounts.indices {
            accounts[index].lastListedAt = nil
            accounts[index].fileCount = 0
        }
        state.unidentifiedReasons = [:]
        try saveAccounts()
        try saveState()
    }

    // MARK: Overrides

    func setOverride(_ folderName: String, _ entry: JSONObject?) throws {
        overrides[folderName] = entry
        state.unidentifiedReasons.removeValue(forKey: folderName)
        state.conflicts.removeAll { $0.folderName == folderName }
        try saveOverrides()
        try saveState()
    }

    /// `_merge_and_save`: write automatic matches, never over a manual entry.
    @discardableResult
    func mergeAutomatic(_ matches: [String: JSONObject]) throws -> Int {
        var written = 0
        for (name, match) in matches {
            guard let entry = Overrides.mergeAutomatic(match, over: overrides[name]) else { continue }
            overrides[name] = entry
            state.unidentifiedReasons.removeValue(forKey: name)
            written += 1
        }
        if written > 0 {
            try saveOverrides()
            try saveState()
        }
        return written
    }

    func setUnidentifiedReason(_ folderName: String, _ reason: String) throws {
        state.unidentifiedReasons[folderName] = reason
        try saveState()
    }

    /// §8.1: folders only in remote are added, local-only ones kept, differing ones become
    /// conflicts (local kept). One backup of the old overrides before any change.
    func mergeRemote(_ remote: [String: JSONObject]) throws -> FetchSummary {
        var summary = FetchSummary(remote: remote.count)
        var conflicts: [OverrideConflict] = []
        var additions: [String: JSONObject] = [:]
        for (name, entry) in remote {
            if let local = overrides[name] {
                if local != entry { conflicts.append(OverrideConflict(folderName: name, local: local, remote: entry)) }
            } else {
                additions[name] = entry
            }
        }
        summary.added = additions.count
        summary.conflicts = conflicts.count
        summary.localOnly = overrides.keys.filter { remote[$0] == nil }.count
        if !additions.isEmpty {
            backupOverrides()
            for (name, entry) in additions {
                overrides[name] = entry
                state.unidentifiedReasons.removeValue(forKey: name)
            }
            try saveOverrides()
        }
        state.conflicts = conflicts.sorted { $0.folderName < $1.folderName }
        state.lastFetchAt = Date()
        try saveState()
        return summary
    }

    /// Conflict review: take the remote version for the given folders, keep local for the rest.
    func resolveConflicts(useRemote names: Set<String>, keepLocal localNames: Set<String>) throws {
        let chosen = state.conflicts.filter { names.contains($0.folderName) }
        if !chosen.isEmpty {
            backupOverrides()
            for conflict in chosen { overrides[conflict.folderName] = conflict.remote }
            try saveOverrides()
        }
        state.conflicts.removeAll { names.contains($0.folderName) || localNames.contains($0.folderName) }
        try saveState()
    }

    func clearConflicts() throws {
        state.conflicts = []
        try saveState()
    }

    /// Import overrides.json: merges like Fetch.
    func importOverrides(_ data: Data) throws -> FetchSummary {
        let object = try JSONCoding.decodeObject(data)
        return try mergeRemote(object.compactMapValues(\.objectValue))
    }

    /// A copy of overrides.json for the share sheet (also writes the backup).
    func exportOverrides() throws -> URL {
        backupOverrides()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("overrides.json")
        let data = try JSONCoding.encode(.object(overrides.mapValues { .object($0) }), pretty: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    func recordPush(stats: JSONObject) throws {
        state.lastPushAt = Date()
        state.lastPushStats = stats
        state.conflicts = []
        try saveState()
    }

    // MARK: Snapshot

    func snapshot() -> CatalogSnapshot {
        CatalogBuilder.build(accounts: accounts, listings: listings, overrides: overrides, state: state)
    }
}

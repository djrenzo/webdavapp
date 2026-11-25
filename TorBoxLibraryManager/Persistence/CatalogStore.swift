import Foundation
import SwiftData

protocol CatalogRepository: Sendable {
    func load() async throws -> CatalogSnapshot
    func save(_ draft: EntryDraft) async throws -> CatalogSnapshot
    func resetDemo() async throws -> CatalogSnapshot
}

@ModelActor actor CatalogStore: CatalogRepository {
    static func open() async throws -> CatalogStore {
        try await Task.detached(priority: .userInitiated) {
            let schema = Schema([
                DemoAccount.self, DemoFolder.self, DemoMediaFile.self,
                DemoOverride.self, DemoSeedState.self
            ])
            // A separate named local store can never be mistaken for live data.
            let config = ModelConfiguration("TorBoxDemo", schema: schema, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            return CatalogStore(modelContainer: container)
        }.value
    }

    func load() throws -> CatalogSnapshot {
        do {
            try seedIfNeeded()
            let result = try snapshot()
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func save(_ draft: EntryDraft) throws -> CatalogSnapshot {
        do {
            try draft.validate()
            let folders = try modelContext.fetch(FetchDescriptor<DemoFolder>())
            guard let folder = folders.first(where: { $0.id == draft.folderID }) else {
                throw CatalogError.missingFolder
            }
            let overrides = try modelContext.fetch(FetchDescriptor<DemoOverride>())
            guard let stored = overrides.first(where: { $0.folderName == folder.name }) else {
                throw CatalogError.invalidJSON
            }
            let name = draft.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            if name != folder.name && (overrides.contains { $0.folderName == name } || folders.contains { $0.name == name }) {
                throw CatalogError.nameInUse
            }
            let raw = try OverrideJSON(raw: stored.raw).edited(using: draft)
            if name == folder.name {
                stored.raw = raw
            } else if folders.contains(where: { $0.id != folder.id && $0.name == folder.name }) {
                // The old folder-name override still belongs to another account.
                modelContext.insert(DemoOverride(folderName: name, raw: raw))
            } else {
                stored.folderName = name
                stored.raw = raw
            }
            folder.name = name
            folder.path = "/\(name)/"
            let files = try modelContext.fetch(FetchDescriptor<DemoMediaFile>())
            let edits = Dictionary(uniqueKeysWithValues: draft.files.map { ($0.id, $0) })
            for file in files where file.folderID == folder.id {
                guard let edit = edits[file.id] else { continue }
                file.name = edit.name.precomposedStringWithCanonicalMapping
                let directory = edit.subfolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .precomposedStringWithCanonicalMapping
                let prefix = directory.isEmpty ? "" : directory + "/"
                file.remotePath = folder.path + prefix + file.name
            }
            let result = try snapshot()
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func resetDemo() throws -> CatalogSnapshot {
        do {
            try modelContext.delete(model: DemoMediaFile.self)
            try modelContext.delete(model: DemoFolder.self)
            try modelContext.delete(model: DemoOverride.self)
            try modelContext.delete(model: DemoAccount.self)
            try modelContext.delete(model: DemoSeedState.self)
            try DemoSeed.insert(into: modelContext)
            let result = try snapshot()
            try modelContext.save()
            return result
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func seedIfNeeded() throws {
        let states = try modelContext.fetchCount(FetchDescriptor<DemoSeedState>())
        guard states == 0 else { return }
        let folderCount = try modelContext.fetchCount(FetchDescriptor<DemoFolder>())
        let overrideCount = try modelContext.fetchCount(FetchDescriptor<DemoOverride>())
        let accountCount = try modelContext.fetchCount(FetchDescriptor<DemoAccount>())
        let fileCount = try modelContext.fetchCount(FetchDescriptor<DemoMediaFile>())
        if folderCount == 0 && overrideCount == 0 && accountCount == 0 && fileCount == 0 {
            try DemoSeed.insert(into: modelContext)
        } else {
            // Existing records are always retained, even without a seed marker.
            modelContext.insert(DemoSeedState())
        }
    }

    private func snapshot() throws -> CatalogSnapshot {
        let accounts = try modelContext.fetch(FetchDescriptor<DemoAccount>())
        let labels = accounts.map { AccountLabel(id: $0.id, name: $0.name) }
            .sorted { $0.name > $1.name }
        let names = Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0.name) })
        let folders = try modelContext.fetch(FetchDescriptor<DemoFolder>())
        let overrides = try modelContext.fetch(FetchDescriptor<DemoOverride>())
        let rawByName = Dictionary(uniqueKeysWithValues: overrides.map { ($0.folderName, $0.raw) })
        let files = try modelContext.fetch(FetchDescriptor<DemoMediaFile>())
        let filesByFolder = Dictionary(grouping: files, by: \.folderID)
        var result: [FolderSnapshot] = []
        for folder in folders {
            guard let raw = rawByName[folder.name] else { throw CatalogError.invalidJSON }
            let entry = try OverrideJSON(raw: raw)
            let folderFiles = filesByFolder[folder.id] ?? []
            let largest = folderFiles.max {
                if $0.size != $1.size { return $0.size < $1.size }
                return $0.name > $1.name
            }?.id
            let fileValues = folderFiles.map { file -> FileSnapshot in
                let relative = file.remotePath.hasPrefix(folder.path)
                    ? String(file.remotePath.dropFirst(folder.path.count)) : file.name
                let directory = (relative as NSString).deletingLastPathComponent
                let numbering = entry.mediaType == "movie"
                    ? EpisodeNumber(season: nil, episode: nil)
                    : EpisodeNumbering.number(
                        name: file.name, subfolder: directory, rootName: folder.name,
                        season: entry.season, force: entry.forceSeason
                    )
                file.season = numbering.season
                file.episode = numbering.episode
                file.isMain = entry.mediaType == "movie" && file.id == largest
                return FileSnapshot(
                    id: file.id, name: file.name, subfolder: directory, size: file.size,
                    firstSeenAt: file.firstSeenAt, numbering: numbering, isMain: file.isMain
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            result.append(FolderSnapshot(
                id: folder.id, accountID: folder.accountID,
                accountName: names[folder.accountID] ?? "Demo account", name: folder.name,
                raw: raw, files: fileValues
            ))
        }
        return CatalogSnapshot(accounts: labels, titles: try TitleGrouper.group(result), folderCount: folders.count)
    }
}

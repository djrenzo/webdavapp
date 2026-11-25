import Foundation
import SwiftData

enum DemoSeed {
    static func insert(into context: ModelContext) throws {
        let home = DemoAccount(name: "Home")
        let archive = DemoAccount(name: "Archive")
        context.insert(home)
        context.insert(archive)
        let now = Date()

        let thronePoster = "1XS1oqL89opfnbLl8WnZY1O1uJx.jpg"
        try add(context, account: home, folder: "Game.Of.Thrones.S01.1080p.BluRay", title: "Game Of Thrones",
                type: "tvshow", year: 2011, id: "1399", poster: thronePoster, date: now,
                files: ["Game.of.Thrones.S01E01.mkv", "Game.of.Thrones.S01E02.mkv"])
        try add(context, account: home, folder: "Game.Of.Thrones.S02.1080p.BluRay", title: "Game of Thrones",
                type: "tvshow", year: 2011, id: "1399", poster: thronePoster, date: now.addingTimeInterval(-100),
                files: ["Game.of.Thrones.S02E01.mkv", "Game.of.Thrones.S02E02.mkv"])
        try add(context, account: archive, folder: "Game.Of.Thrones.Integral.MULTI.1080p", title: "Game of Thrones",
                type: "tvshow", year: 2011, id: "1399", poster: thronePoster, date: now.addingTimeInterval(-200),
                files: ["08 - Puines.mkv", "09 - The Rains of Castamere.mkv"],
                subfolder: "Game.Of.Thrones.Saison.3.MULTI", extra: [
                    "source": "manual", "tvdb_id": "121361", "imdb_id": "tt0944947",
                    "plot": "Seven noble families fight for control of the Seven Kingdoms.",
                    "kodi_metadata": ["collection": "Westeros", "edition": "Complete"],
                    "subs": [["url": "https://example.com/demo/Game.of.Thrones.S03E08.es.srt",
                              "fileName": "Game.of.Thrones.S03E08.es.srt", "language": "es",
                              "hi": false, "fps_from": 23.976, "fps_to": 25, "shift_ms": -500]]
                ])
        try add(context, account: home, folder: "Dune.2021.1080p.BluRay", title: "Dune",
                type: "movie", year: 2021, id: "438631", poster: "d5NXSklXo0qyIYkgV94XAgMIckC.jpg",
                date: now.addingTimeInterval(-1_000), files: ["Dune.2021.1080p.mkv", "Behind the scenes.mp4"])
        try add(context, account: home, folder: "The.Office.Complete.Series.1080p", title: "The Office",
                type: "tvshow", year: 2005, id: "2316", poster: "7DJKHzAi83BmQrWLrYYOqcoKfhR.jpg",
                date: now.addingTimeInterval(-2_000),
                files: ["The.Office.S01E01.mkv", "The.Office.S01E02.mkv", "The.Office.S01E03.mkv"])
        try add(context, account: archive, folder: "Frieren - Sousou no Frieren", title: "Frieren",
                type: "tvshow", year: 2023, id: "209867", poster: "dqZENchTd7lp5zht7BdlqM7RBhD.jpg",
                date: now.addingTimeInterval(-3_000), files: ["Frieren - E01 [BD].mkv", "Frieren - E02 [BD].mkv", "Frieren - E03 [BD].mkv"],
                extra: ["original_title": "Sousou no Frieren", "plot": "An elven mage discovers what a lifetime means, one journey at a time."])
        try add(context, account: home, folder: "Breaking.Bad.Collection.2008", title: "Breaking Bad",
                type: "tvshow", year: 2008, id: "1396", poster: "ztkUQFLlC19CCMYHW9o1zWhJRNq.jpg",
                date: now.addingTimeInterval(-4_000),
                files: ["Breaking.Bad.S01E01.mkv", "Breaking.Bad.S01E02.mkv", "Breaking.Bad.S01E03.mkv"])
        try add(context, account: archive, folder: "1917.2019.1080p.BluRay", title: "1917",
                type: "movie", year: 2019, id: "530915", poster: "iZf0KyrE25z1sage4SYFLCCrMi9.jpg",
                date: now.addingTimeInterval(-5_000), files: ["1917.2019.1080p.mkv"])
        try add(context, account: home, folder: "Interstellar.2014.1080p", title: "Interstellar",
                type: "movie", year: 2014, id: "157336", poster: "gEU2QniE6E77NI6lCU6MxlNBvIx.jpg",
                date: now.addingTimeInterval(-6_000), files: ["Interstellar.2014.mkv", "Making Interstellar.mp4"])
        try add(context, account: archive, folder: "The.Last.of.Us.S01.1080p", title: "The Last of Us",
                type: "tvshow", year: 2023, id: "100088", poster: "uKvVjHNqB5VmOrdxqAt2F7J78ED.jpg",
                date: now.addingTimeInterval(-7_000), files: ["The.Last.of.Us.S01E01.mkv", "The.Last.of.Us.S01E02.mkv"])
        try add(context, account: home, folder: "Spider-Man.No.Way.Home.2021", title: "Spider-Man: No Way Home",
                type: "movie", year: 2021, id: "634649", poster: "1g0dhYtq4irTY1GPXvft6k4YLjm.jpg",
                date: now.addingTimeInterval(-8_000), files: ["Spider-Man.No.Way.Home.mkv", "Deleted scenes.mp4"])
        try add(context, account: archive, folder: "The.Quiet.Atlas.2024", title: "The Quiet Atlas",
                type: "movie", year: 2024, id: nil, poster: nil,
                date: now.addingTimeInterval(-9_000), files: ["The Quiet Atlas.mp4"],
                extra: ["source": "manual", "plot": "A personal travel film. This demo entry has no poster.", "notes": ["personal_video": true]])
        context.insert(DemoSeedState())
    }

    private static func add(
        _ context: ModelContext, account: DemoAccount, folder name: String, title: String,
        type: String, year: Int, id: String?, poster: String?, date: Date,
        files: [String], subfolder: String = "", extra: [String: Any] = [:]
    ) throws {
        let folder = DemoFolder(accountID: account.id, name: name)
        context.insert(folder)
        var raw: [String: Any] = ["title": title, "type": type, "year": year, "source": "auto"]
        if let id { raw["tmdb_id"] = id }
        if let poster { raw["thumb"] = "https://image.tmdb.org/t/p/w500/\(poster)" }
        raw.merge(extra) { _, new in new }
        context.insert(DemoOverride(folderName: folder.name, raw: try OverrideJSON.encode(raw)))
        for (index, fileName) in files.enumerated() {
            let prefix = subfolder.isEmpty ? "" : "\(subfolder)/"
            let size: Int64 = type == "movie"
                ? (index == 0 ? 14_800_000_000 : 320_000_000)
                : Int64(2_100_000_000 + index * 75_000_000)
            context.insert(DemoMediaFile(
                folderID: folder.id, name: fileName, path: folder.path + prefix + fileName,
                size: size, firstSeenAt: date
            ))
        }
    }
}

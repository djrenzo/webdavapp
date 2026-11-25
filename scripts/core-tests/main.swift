import Foundation
@testable import Core

let golden = try! JSONCoding.decodeObject(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var failures = 0, checks = 0
@MainActor func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("FAIL:", message()) }
}
func optInt(_ v: JSONValue?) -> Int? { v.flatMap { $0.isNull ? nil : $0.pythonInt } }

for (name, expected) in golden["parse"]!.objectValue! {
    let e = expected.objectValue!
    let p = ReleaseParser.parse(name)
    check(p.title == e["title"]!.stringValue! && p.year == optInt(e["year"]) && p.tvHint == e["tv_hint"]!.boolValue!,
          "parse \(name): got \(p) expected \(e)")
}
for (name, expected) in golden["queries"]!.objectValue! {
    let q = ReleaseParser.queries(for: ReleaseParser.parse(name).title)
    let e = expected.arrayValue!.map { $0.stringValue! }
    check(q == e, "queries \(name): \(q) vs \(e)")
}
for (text, expected) in golden["normalize"]!.objectValue! {
    check(TextMatching.normalize(text) == expected.stringValue!, "normalize \(text): \(TextMatching.normalize(text)) vs \(expected)")
}
for item in golden["ratio"]!.arrayValue! {
    let a = item.arrayValue!
    let r = TextMatching.ratio(a[0].stringValue!, a[1].stringValue!)
    check(abs(r - a[2].numberValue!) < 1e-12, "ratio \(a[0]) \(a[1]): \(r) vs \(a[2])")
}
for (file, expected) in golden["episode"]!.objectValue! {
    let e = expected.arrayValue!
    let got = EpisodeNumbering.extractEpisodeInfo(file)
    check(got?.season == optInt(e[0]) && got?.episode == optInt(e[1]), "episode \(file): \(String(describing: got)) vs \(e)")
}
for (file, expected) in golden["bare"]!.objectValue! {
    check(EpisodeNumbering.extractBareEpisode(file) == optInt(expected), "bare \(file): \(String(describing: EpisodeNumbering.extractBareEpisode(file))) vs \(expected)")
}
for (name, expected) in golden["guess"]!.objectValue! {
    check(EpisodeNumbering.guessSeason(name) == optInt(expected), "guess \(name)")
}
let root = golden["root"]!.stringValue!
let items = golden["items"]!.arrayValue!.map { $0.objectValue! }
for item in golden["number"]!.arrayValue! {
    let o = item.objectValue!
    let inputs = items.map { EpisodeNumbering.Input(name: $0["name"]!.stringValue!, decodedPath: $0["path"]!.stringValue!, size: Int64($0["size"]!.pythonInt!)) }
    let got = EpisodeNumbering.number(rootName: root, override: o["override"]!.objectValue!, files: inputs)
    let exp = o["result"]!.arrayValue!.map { $0.arrayValue! }
    for (g, e) in zip(got, exp) {
        check(g.number.season == optInt(e[0]) && g.number.episode == optInt(e[1]) && g.isMain == e[2].boolValue!,
              "number \(o["override"]!): \(g) vs \(e)")
    }
}
for item in golden["keys"]!.arrayValue! {
    let a = item.arrayValue!
    check(Overrides.titleKey(a[0].objectValue!) == a[1].stringValue!, "key \(a[0]): \(Overrides.titleKey(a[0].objectValue!)) vs \(a[1])")
}
for item in golden["score"]!.arrayValue! {
    let a = item.arrayValue!
    let (total, sim, year) = Identifier.score(query: a[0].stringValue!, year: optInt(a[1]), result: a[3].objectValue!, mediaType: a[2].stringValue!)
    let e = a[4].arrayValue!
    check(abs(total - e[0].numberValue!) < 1e-9 && abs(sim - e[1].numberValue!) < 1e-9 && year == optInt(e[2]), "score \(a[0]) \(a[3]): \((total, sim, year)) vs \(e)")
}

// WebDAV parse fixture (TorBox-style response with a decomposed accent).
let xml = """
<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
<D:response><D:href>/Game.Of.Thrones.Integral.(S01%20a%CC%80%20S08)/</D:href><D:propstat><D:prop><D:displayname></D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
<D:response><D:href>https://webdav.torbox.app/Movie%20File.mkv</D:href><D:propstat><D:prop><D:displayname>Movie File.mkv</D:displayname><D:getcontentlength>12345</D:getcontentlength><D:resourcetype/></D:prop></D:propstat></D:response>
<D:response><D:href>/.hidden/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
</D:multistatus>
"""
let items2 = try! WebDAV.parse(Data(xml.utf8), baseURL: "https://webdav.torbox.app", currentPath: "/")
check(items2.count == 3, "propfind count \(items2.count)")
check(items2[0].name == "Game.Of.Thrones.Integral.(S01 a\u{300} S08)" && items2[0].isCollection, "propfind name \(items2[0])")
check(items2[0].name == "Game.Of.Thrones.Integral.(S01 à S08)", "canonical equivalence")
check(items2[1].fullURL == "https://webdav.torbox.app/Movie%20File.mkv" && items2[1].size == 12345 && !items2[1].isCollection, "file \(items2[1])")
check(WebDAV.folderPath(items2[0]) == "/Game.Of.Thrones.Integral.(S01 a\u{300} S08)/", "folder path")
check(WebDAV.encode("https://webdav.torbox.app/A B [x]/é%.mkv") == "https://webdav.torbox.app/A%20B%20%5Bx%5D/%C3%A9%25.mkv", "encode \(WebDAV.encode("https://webdav.torbox.app/A B [x]/é%.mkv"))")
check(WebDAV.authedURL("https://webdav.torbox.app/a%20b.mkv", username: "me@x.com", password: "p@ss:/w") == "https://me%40x.com:p%40ss%3A%2Fw@webdav.torbox.app/a%20b.mkv", "authed")
check(AppLog.redact("GET https://u:p@host/x Bearer abc.def") == "GET https://***:***@host/x <redacted>", "redact \(AppLog.redact("GET https://u:p@host/x Bearer abc.def"))")
check(SupabaseConfig.projectURL("https://abc.supabase.co/rest/v1/") == "https://abc.supabase.co", "project url")

// Overrides merge rules.
let manual: JSONObject = ["title": "X", "source": "manual"]
check(Overrides.mergeAutomatic(["title": "Y", "source": "auto"], over: manual) == nil, "manual protected")
let merged = Overrides.mergeAutomatic(["title": "Y", "source": "auto"], over: ["title": "Z", "source": "auto", "season": 3, "subs": .array([]), "force_season": .null])!
check(merged["season"] == 3 && merged["subs"] == .array([]) && merged["force_season"] == nil, "keep fields \(merged)")
check(JSONValue.int(25) == JSONValue.double(25.0), "numeric eq")
let roundTrip = try! JSONCoding.decodeObject(Data(#"{"a":1,"b":23.976,"c":true,"d":null,"e":{"x":[1,"y"]},"unknown":"kept"}"#.utf8))
check(roundTrip["b"] == .double(23.976) && roundTrip["c"] == true && roundTrip["d"] == .null && roundTrip["unknown"] == "kept", "json \(roundTrip)")

// TitleRowSet: manual wins, gaps filled, nulls dropped.
let rows = TitleRowSet(overrides: [
    "a": ["title": "Auto Title", "type": "tvshow", "tmdb_id": "1", "plot": "auto plot", "source": "auto"],
    "b": ["title": "Manual Title", "type": "tvshow", "tmdb_id": "1", "source": "manual"],
    "c": ["season": 2],
])
check(rows.rows["tvshow:tmdb:1"]?["title"] == "Manual Title" && rows.rows["tvshow:tmdb:1"]?["plot"] == "auto plot" && rows.rows["tvshow:tmdb:1"]?["year"] == nil, "rows \(rows.rows)")
check(rows.folderKeys["c"] == nil && rows.folderKeys.count == 2, "folder keys")
check(Push.nowISO().count == 27, "iso \(Push.nowISO())")

// Subtitles: the addon's `subs` format and how it attaches files to episodes.
let showEntry: JSONObject = ["title": "Game of Thrones", "type": "tvshow", "tmdb_id": "1399", "source": "auto", "subs": .array([
    .object(["url": "https://subs5.strem.io/x/file/1", "fileName": "Game of Thrones.S01E02.es.srt", "language": "es", "hi": false]),
    .object(["url": "https://subs5.strem.io/x/file/2", "fileName": "Game of Thrones.S01E02.en.srt", "language": "en", "hi": true, "fps_from": .double(23.976), "fps_to": 25, "shift_ms": -500]),
    .object(["url": "https://subs5.strem.io/x/file/3", "fileName": "Game of Thrones.S01E03.sp.srt", "language": "sp"]),
    .object(["url": "", "fileName": "broken.srt"]),
    .object(["url": "https://x/4", "fileName": "no-extension"]),
])]
let ep2 = SubtitleEntries.saved(showEntry, episode: EpisodeKey(season: 1, episode: 2))
check(ep2.map(\.language) == ["es", "en"] && ep2[1].hearingImpaired && ep2[1].adjustments == "23.976 → 25 fps · -500 ms", "subs for episode \(ep2)")
check(SubtitleEntries.saved(showEntry).count == 3, "valid subs only")
check(SubtitleLanguages.name("sp") == "Spanish" && SubtitleLanguages.find(legacy: "pob")?.code == "pt-BR", "languages")
check(SubtitleEntries.fileName(for: showEntry, episode: EpisodeKey(season: 1, episode: 2), language: "nl") == "Game of Thrones.S01E02.nl.srt", "episode file name")
let movieEntry: JSONObject = ["title": "Mission: Impossible?", "year": 1996, "type": "movie", "tmdb_id": "954"]
check(SubtitleEntries.fileName(for: movieEntry, episode: nil, language: "en") == "Mission - Impossible (1996) {tmdb-954}.en.srt", "movie file name \(SubtitleEntries.fileName(for: movieEntry, episode: nil, language: "en"))")
let replaced = SubtitleEntries.adding(["url": "https://new", "fileName": "Game of Thrones.S01E02.es.srt", "language": "es", "hi": false], to: showEntry)
let replacedSubs = SubtitleEntries.saved(replaced, episode: EpisodeKey(season: 1, episode: 2))
check(replacedSubs.map(\.url) == ["https://subs5.strem.io/x/file/2", "https://new"] && replaced["title"] == "Game of Thrones", "add replaces same language \(replacedSubs)")
let removed = SubtitleEntries.removing(url: "https://subs5.strem.io/x/file/2", from: replaced)
check(SubtitleEntries.saved(removed).map(\.url) == ["https://subs5.strem.io/x/file/3", "https://new"], "remove")
check(SubtitleEntries.active(ep2).count == 2, "active per language")

// Completeness: aired from TMDB details vs. files present.
let tvDetails = try! JSONCoding.decodeObject(Data(#"{"status":"Returning Series","last_episode_to_air":{"season_number":3,"episode_number":4},"seasons":[{"season_number":0,"episode_count":5},{"season_number":1,"episode_count":10},{"season_number":2,"episode_count":8},{"season_number":3,"episode_count":10},{"season_number":4,"episode_count":0}]}"#.utf8))
let aired = AiredEpisodes.from(details: tvDetails)
check(aired.seasons == [1: 10, 2: 8, 3: 4] && aired.keys.count == 22 && aired.keys.first == EpisodeKey(season: 1, episode: 1), "aired \(aired.seasons)")
var present = Set((1...10).map { EpisodeKey(season: 1, episode: $0) })
present.formUnion([1, 2, 3, 5, 6].map { EpisodeKey(season: 2, episode: $0) })
let report = CompletenessReport.make(aired: aired, present: present)
check(report.missingSeasons == [3] && report.missingEpisodes[2] == [4, 7, 8] && report.missingCount == 7 && !report.isComplete, "report \(report)")
check(report.lines.map(\.text) == ["E4, E7–E8", "all 4 episodes"], "lines \(report.lines.map(\.text))")
check(CompletenessReport.ranges([9, 1, 2, 3, 5]) == "E1–E3, E5, E9", "ranges")
present.formUnion([4, 7, 8].map { EpisodeKey(season: 2, episode: $0) })
present.formUnion((1...4).map { EpisodeKey(season: 3, episode: $0) })
check(CompletenessReport.make(aired: aired, present: present).isComplete, "complete")
check(!CompletenessReport.make(aired: AiredEpisodes(seasons: [:], status: nil, fetchedAt: Date()), present: present).isComplete, "nothing aired is not complete")

// Trakt parsing, bodies and Keep going.
let traktShows = try! JSONDecoder().decode(JSONValue.self, from: Data(#"[{"last_watched_at":"2026-11-20T20:00:00.000Z","show":{"title":"GoT","ids":{"trakt":1390,"tmdb":1399,"imdb":"tt0944947"}},"seasons":[{"number":1,"episodes":[{"number":1,"last_watched_at":"2026-11-01T20:00:00.000Z"},{"number":2,"last_watched_at":"2026-11-02T20:00:00Z"},{"number":4,"last_watched_at":"2026-11-20T20:00:00.000Z"},{"number":5,"last_watched_at":"2026-10-01T20:00:00.000Z"}]}]}]"#.utf8))
let traktPlayback = try! JSONDecoder().decode(JSONValue.self, from: Data(#"[{"id":7,"progress":42.5,"paused_at":"2026-11-21T10:00:00.000Z","type":"episode","episode":{"season":1,"number":6,"title":"A Golden Crown"},"show":{"title":"GoT","ids":{"tmdb":1399}}},{"id":8,"progress":10,"paused_at":"2026-11-22T10:00:00.000Z","type":"movie","movie":{"title":"Heat","ids":{"tmdb":949,"imdb":"tt0113277"}}}]"#.utf8))
let traktState = TraktParser.state(settings: ["user": .object(["username": "me"])], movies: [], shows: traktShows.arrayValue!, playback: traktPlayback.arrayValue!)
let got = traktState.show(tmdbID: "1399", imdbID: nil)!
check(traktState.username == "me" && got.episodes.count == 4 && got.lastEpisode?.key == EpisodeKey(season: 1, episode: 4), "trakt shows \(got)")
check(traktState.playback.map(\.id) == [8, 7] && traktState.playback[1].episode == EpisodeKey(season: 1, episode: 6) && traktState.playback[0].isMovie, "playback")
check(traktState.show(tmdbID: nil, imdbID: "TT0944947") != nil, "imdb fallback")
let order = (1...10).map { EpisodeKey(season: 1, episode: $0) } + [EpisodeKey(season: 2, episode: 1)]
let libraryEpisodes = Set([5, 6, 7].map { EpisodeKey(season: 1, episode: $0) })
// Last watched is E4 (most recent); E5 is already watched, so E6 is next and is in the library.
check(UpNext.pick(watched: got, order: order, present: libraryEpisodes) == UpNext.Pick(next: EpisodeKey(season: 1, episode: 6), last: EpisodeKey(season: 1, episode: 4), inLibrary: true), "up next")
check(UpNext.pick(watched: got, order: [], present: [EpisodeKey(season: 1, episode: 3)]) == nil, "nothing after last")
check(UpNext.pick(watched: got, order: order, present: [])?.inLibrary == false, "next not in library")
let body = TraktParser.showBody(TraktIDs(tmdb: 1399), episodes: [EpisodeKey(season: 1, episode: 2), EpisodeKey(season: 1, episode: 1), EpisodeKey(season: 2, episode: 1)], seasons: [2])
check(String(decoding: try! JSONCoding.encode(.object(body)), as: UTF8.self) == #"{"shows":[{"ids":{"tmdb":1399},"seasons":[{"number":2},{"episodes":[{"number":1},{"number":2}],"number":1}]}]}"#, "history body \(String(decoding: try! JSONCoding.encode(.object(body)), as: UTF8.self))")

// PKCE (RFC 7636 appendix B) and SHA-256.
check(TraktPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "pkce challenge")
check(SHA256.hash(Array("".utf8)).map { String(format: "%02x", $0) }.joined() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 empty")
check(SHA256.hash(Array(String(repeating: "a", count: 1000).utf8)).map { String(format: "%02x", $0) }.joined() == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3", "sha256 multi-block")
let pkce = TraktPKCE.make()
let authURL = TraktClient(clientID: "abc").authorizationURL(pkce).absoluteString
check(pkce.verifier.count == 64 && authURL.hasPrefix("https://trakt.tv/oauth/authorize?response_type=code&client_id=abc&redirect_uri=webdavify://trakt&state=") && authURL.contains("code_challenge_method=S256"), "authorize url \(authURL)")

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)

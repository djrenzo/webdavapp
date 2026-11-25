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

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)

# TorBox Library for iOS — App Specification

Status: draft v1 · 2026-11-25

## 1. Purpose

An iPhone/iPad app that does on a phone what the Kodi addon `plugin.video.torbox` does as **catalog admin**:

1. Keep any number of TorBox WebDAV accounts.
2. List every root folder and every video file on those accounts.
3. Pull the existing identifications ("overrides") from Supabase.
4. Auto-identify every folder that has no identification yet, against TMDB.
5. Show the whole library as a poster gallery, with fixes for wrong or missing matches.
6. Push everything back to Supabase in the same shape the Kodi addon pushes. The Kodi addon, and any future reader app, then see one shared catalog.

The Kodi addon stays in use. The two apps **share one Supabase database and must stay interoperable**. Section 3 lists the rules that keep them interoperable. Read it before writing any sync code.

### Out of scope for v1

| Kodi feature | Why it's left out |
|---|---|
| Library export (STRM/NFO files, `sources.xml`) | Kodi-only concept |
| Downloads to local storage | Not needed on a phone; revisit later |
| Local streaming proxy (reconnects on dropped TorBox servers) | Playback is handed to an external player (§10) |
| Phone-setup QR server | The app *is* on the phone |
| Subtitle search and FPS/shift editing | v2. v1 keeps existing `subs` entries untouched and pushes them (§3.4) |
| Top movies/series lists | Not part of the catalog |

## 2. Glossary

| Term | Meaning |
|---|---|
| Account | One TorBox WebDAV login: base URL, username, password, display name |
| Root folder | A collection directly under an account's WebDAV root. It is usually a torrent's release name, e.g. `[ OxTorrent.com ] Game.Of.Thrones.Integral.(S01 à S08).MULTI.1080p…` |
| Folder name | The decoded name of a root folder. It is the **primary key** of an override, across all accounts |
| Override | What a root folder is: the TMDB title, type, ids and poster. It is `auto` (made by the identifier) or `manual` (set by the user) |
| Title | One movie or show. Several folders can point at the same title, e.g. one folder per season |
| Media file | One video file anywhere under a root folder, numbered with season/episode for shows |
| Push | Upload the full local state to Supabase |
| Fetch | Merge Supabase's overrides into the local overrides |

## 3. Compatibility contract with the Kodi addon

These rules aren't up for redesign. Breaking any of them corrupts the shared catalog.

### 3.1 Override JSON (`overrides.raw`)

The Kodi addon stores one JSON object per folder name. Supabase keeps it untouched in `overrides.raw`, and Fetch restores it from there. The iOS app must read and write the same keys and **keep any key it doesn't know** (round-trip unknown keys).

```json
{
  "title": "Game of Thrones",
  "type": "tvshow",
  "year": 2011,
  "tmdb_id": "1399",
  "tvdb_id": "121361",
  "imdb_id": "tt0944947",
  "thumb": "https://image.tmdb.org/t/p/w500/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
  "plot": "Seven noble families fight for control…",
  "source": "auto",
  "season": 3,
  "force_season": false,
  "subs": [
    {
      "url": "https://…",
      "fileName": "Game of Thrones.S03E01.es.srt",
      "language": "es",
      "hi": false,
      "fps_from": 23.976,
      "fps_to": 25,
      "shift_ms": -500
    }
  ]
}
```

| Key | Type | Notes |
|---|---|---|
| `title` | string | Required for the entry to count as identified |
| `type` | `"movie"` \| `"tvshow"` | A missing value is treated as `tvshow` |
| `year` | int | Optional |
| `tmdb_id`, `tvdb_id`, `imdb_id` | **string** | Ids are strings, never numbers |
| `thumb` | string | Poster URL (TMDB `w500`) |
| `plot` | string | Optional |
| `source` | `"auto"` or absent | **Only exactly `"auto"` means automatic.** Absent or any other value (`"manual"`) means manual |
| `season` | int | Season override for the folder |
| `force_season` | bool | `true`: `season` replaces the season in every file name. `false`: `season` only applies to files without one |
| `subs` | array | Subtitle picks. Keep them as they are |

### 3.2 Manual overrides are never overwritten automatically

An entry is **manual** when it has a `title` and `source != "auto"`.

- Auto-identification **skips** manual entries.
- When the identifier writes an auto match over an existing entry, it carries over that entry's `subs`, `season` and `force_season`.

### 3.3 Title key

Folders are grouped into titles by this key, and it must be computed exactly like this. It is `titles.key` in Supabase.

```
media_type = entry.type ?? "tvshow"
if tmdb_id:  "{media_type}:tmdb:{tmdb_id}"
elif tvdb_id: "{media_type}:tvdb:{tvdb_id}"
elif imdb_id: "{media_type}:imdb:{imdb_id}"
else:         "{media_type}:title:{normalize(title)}:{year or ''}"
```

`normalize()` is defined in §7.4.

When several folders share a key, **manual entries win**. Their non-empty fields go in first, and auto entries only fill the gaps.

### 3.4 Episode numbering

Shows must be numbered exactly as in §7.5, so that `media_files.season_number/episode_number` match what Kodi exports.

### 3.5 Account ids (deviation from Kodi, needs care)

Kodi uses its settings slot `1…5` as `accounts.id` and as `media_files.account_id`. The iOS app supports any number of accounts, so it must not take a slot that Kodi uses:

- When an account is added, read `accounts`. If a row with the same `webdav_url` (trailing `/` stripped) **and** `username` exists, reuse its `id`, which lets Kodi and iOS share the account.
- Otherwise take `id = max(100, max(existing ids)) + 1`.
- Store the id with the account locally. It never changes.

> **Rule for both apps:** run *Fetch* before *Push*. Kodi's push deletes remote overrides that its local file doesn't have (it asks first). A Kodi box that hasn't fetched would offer to delete everything the iOS app added. The iOS app always fetches as part of its refresh pipeline (§6).

## 4. Platform and tech choices

| Area | Choice |
|---|---|
| Target | iOS/iPadOS 17+, SwiftUI, Swift 6 strict concurrency |
| Persistence | SwiftData for accounts, folders, files and overrides. Overrides are also kept as their raw JSON (`Data`) so unknown keys survive |
| Secrets | Keychain for WebDAV passwords, the Supabase password and the TMDB token |
| Networking | `URLSession` with async/await |
| WebDAV | Hand-written `PROPFIND` (`Depth: 1`) plus `XMLParser`. No dependency |
| Supabase | [`supabase-swift`](https://github.com/supabase/supabase-swift) for Auth (email/password, refresh) and PostgREST |
| Images | `AsyncImage` with a disk cache (`URLCache` with a 200 MB disk capacity), or Nuke if scrolling stutters |
| Concurrency limits | 4 parallel TMDB requests and 4 parallel WebDAV listings per account |

## 5. Data model (local)

```swift
@Model final class Account {
    @Attribute(.unique) var localID: UUID
    var remoteID: Int            // accounts.id in Supabase (§3.5)
    var name: String
    var baseURL: URL             // e.g. https://webdav.torbox.app, without trailing '/'
    var username: String         // password lives in the Keychain under localID
    var isEnabled: Bool
    var lastListedAt: Date?
    var lastListingComplete: Bool
}

@Model final class RootFolder {          // one per (account, folder name)
    var account: Account
    var name: String                     // decoded, NFC-normalized
    var path: String                     // decoded WebDAV path, ends with '/'
    var files: [MediaFile]
}

@Model final class MediaFile {
    var folder: RootFolder
    var name: String
    var remotePath: String               // decoded path
    var webdavURL: URL                   // as listed (percent-encoded)
    var size: Int64
    var season: Int?                     // numbering per §7.5
    var episode: Int?
    var isMain: Bool                     // movies: largest file
}

@Model final class Override {
    @Attribute(.unique) var folderName: String
    var raw: Data                        // the JSON object of §3.1, source of truth
    // decoded convenience fields (title, type, year, ids, thumb, source, season, forceSeason)
}
```

Overrides are keyed by folder name only, not by account, the same as in Kodi.

## 6. The refresh pipeline

One **Refresh** button (pull-to-refresh in the gallery) runs these steps in order, with a progress sheet showing the current step, counters and a Cancel button:

| # | Step | Details |
|---|---|---|
| 1 | Sign in to Supabase | Email/password. Check `rpc('is_member')` and `rpc('is_admin')`. If not admin, run steps 2–5 and skip step 6, so the app still works read-only |
| 2 | Fetch overrides | `select folder_name,raw from overrides order by folder_name`, paged 1000 at a time. Merge per §8.1 |
| 3 | List accounts | For every enabled account: root folders, then every video file under each root folder, recursively (§7.1). Record per account whether **every** subfolder could be listed (`complete`) |
| 4 | Auto-identify | Root folders with no identified override (§7.3). Manual entries are never touched. Auto matches are saved locally as they come in, so the gallery fills live |
| 5 | Number files | §7.5, for every file |
| 6 | Push | §8.2 (admins only). Offered as a separate **Push** action too |

If Supabase isn't configured, steps 1, 2 and 6 are skipped and the app works as a local cataloguer.

Settings has a **"Re-identify automatic matches"** action. It runs step 4 with `redoAuto = true`: auto entries are searched again, manual ones still aren't.

## 7. Algorithms

All of these are ports of the Python in `addons/plugin.video.torbox/`. Port the unit tests in §12 with them.

### 7.1 WebDAV listing

- `PROPFIND {baseURL}{path}`, with headers `Depth: 1`, Basic auth and `Content-Type: application/xml`. Use the standard body asking for `displayname`, `resourcetype` and `getcontentlength`.
- Parse each `d:response`:
  - `href` → path (URL path component).
  - Skip the entry whose decoded path equals the requested path.
  - `is_collection` = `resourcetype` contains `collection`.
  - `name` = `displayname`, or the last decoded path segment.
  - `size` = `getcontentlength`, or 0.
- **Root folders**: collections under `/` whose name doesn't start with `.`.
- **Files**: walk recursively. Keep files whose lowercase extension is in `.mkv .mp4 .avi .mov .m4v .ts .m2ts .wmv .flv .webm .ogv .divx .mpg .mpeg .m2v .vob` and whose name doesn't contain `sample` (case-insensitive). `.strm` is ignored on iOS.
- Normalize names to **NFC**. TorBox returns some names decomposed: `à` arrives as `a` plus a combining grave accent.
- An account where any PROPFIND fails is `complete = false`. Its files are still pushed, but its stale files aren't deleted (§8.2).

### 7.2 Release-name parsing

The input is a folder name. The output is `title` (search query only, never shown), `year?` and `tvHint`.

1. Strip a trailing video extension.
2. Strip leading `[...]` and `{...}` groups (`^\s*(?:\[[^\]]*\]\s*|\{[^}]*\}\s*)+`).
3. If the value has no space **or** has ≥ 2 dots, replace runs of `.` and `_` with a space. Collapse whitespace.
4. **TV marker** (case-insensitive, first match):
   `\bS\d{1,2}(?:[ ._-]?E\d{1,3})?\b | \b(?:Season|Temporada|Saison|Staffel)[ ._-]?\d{1,2}\b | \b\d{1,2}x\d{2,3}\b | \bComplete[ ._-](?:Series|Season)\b | \bE(?:P)?\d{2,3}\b`
   `tvHint` is true when it matches. When it doesn't start at position 0, its start becomes a cut point.
5. **Year**: the first `(?<!\d)(19\d{2}|20\d{2})(?!\d)` that isn't at position 0. A title like *1917* stays intact. It becomes `year` and a cut point.
6. **Quality tag**: the first match not at position 0 is a cut point. The tags are:
   `2160p 1080p 1080i 720p 576p 480p 4K UHD HD SD BluRay BDRip BRRip WEB-DL WEBRip WEB HDTV DVDRip DVDScr DVD PDTV SDTV HDCAM CAM TS x264 x265 H.264 H.265 HEVC AVC XviD DivX AAC* AC3 DTS DD* TrueHD Atmos EAC3 DDP* 10bit 8bit HDR HDR10 DV DoVi AMZN NF DSNP HMAX ATVP PCOK iP PROPER REPACK EXTENDED THEATRICAL UNRATED DIRECTORS.CUT MULTI FRENCH GERMAN SPANISH ITALIAN`
   They are matched as whole words, case-insensitive.
7. **Bracket**: the first `[`, `(` or `{` not at position 0 is a cut point.
8. `title` = the text before the earliest cut point, with trailing `space - – : ( [ {` trimmed.
9. Strip trailing **pack words**, repeatedly, case-insensitive:
   `Integral, Intégrale, Integrale, Complete, Completa, Completo, Collection, Colección, Coleccion, Box Set, Boxset, Full Series, Serie Completa, Series Completa`.
10. If the title ends up empty, use the whole cleaned value.

### 7.3 Identification

For each pending folder:

1. Parse the name (§7.2).
2. **Choose the type to search.**
   - If `tvHint` is true, search as a TV show.
   - Otherwise guess from a `Depth: 1` listing of the folder:
     - Any subfolder whose name starts with `S\d{1,2}` or `(Season|Saison|Temporada|Staffel)[ ._-]?\d{1,2}` means a TV show.
     - Count the videos whose name has a season+episode marker (§7.5 pattern A). If there are ≥ 2 of them, or there are ≥ 3 videos and at least 1 of them is marked, it's a TV show.
     - Otherwise, any video at all means a movie.
     - Otherwise search both types.
3. **Queries**: the title, then up to 3 parts of it split on ` - ` or `/` (e.g. *"Frieren - Sousou no Frieren"*). Duplicates are removed.
4. For each query and each type, call TMDB `/search/tv` or `/search/movie` with `query` and `include_adult=false`. Add `first_air_date_year` (TV) or `year` (movie) when a year is known. If that returns nothing, retry without the year. Look at the top 10 results.
5. **Score** each result:
   - `similarity` = max over `name`/`original_name` (or `title`/`original_title`) of the `SequenceMatcher` ratio between the normalized query and the normalized name.
   - For names with `:`, also try `0.95 ×` the ratio against the part before the colon.
   - Skip the result when `similarity < 0.7`.
   - Year bonus: same year `+0.10`, ±1 year `+0.05`, otherwise `−0.05` for TV and `−0.20` for movies. There is no bonus if either year is unknown.
   - `score = similarity + bonus`.
6. Keep the best result overall. Stop trying more queries once the best score is ≥ **0.8**. Below 0.8 the folder stays unidentified.
7. **Build the entry**: `title`, `type`, `tmdb_id` (string), `year` (from the release or first-air date), `thumb` (`https://image.tmdb.org/t/p/w500{poster_path}`), `plot`, `source: "auto"`. Then add `imdb_id` and `tvdb_id` (TV only) from `/{tv|movie}/{id}/external_ids`.
8. Merge per §3.2 and save.

`SequenceMatcher` is Python's `difflib` ratio: `2·M / (len(a)+len(b))`, where M is the number of characters in matching blocks found by the Ratcliff/Obershelp algorithm. Port it exactly; don't swap in Levenshtein. The 0.7 and 0.8 thresholds were tuned on this ratio.

TMDB auth: `Authorization: Bearer <v4 read access token>`, entered in Settings.

### 7.4 `normalize(text)`

1. Apply NFKD and drop combining marks.
2. Lowercase. Replace `&` with ` and `.
3. Replace every run of characters outside `[a-z0-9]` with one space, and trim.
4. Drop one leading article: `the a an el la los las le les der die das`.

### 7.5 Episode numbering (TV shows)

Patterns:

- **A** (season + episode): `[Ss](\d{1,2})[.\-_ ]?[Ee](\d{1,3})`, then `(\d{1,2})[xX](\d{2,3})`.
- **B** (bare episode):
  - First try `(?<![A-Za-z0-9])(?:Episode[ ._-]?|EP?)(\d{1,3})(?!\d)` (case-insensitive).
  - Otherwise a leading number, `^\s*(\d{1,3})(?:\s*[-–.]\s*|\s+|_)(?=\D)`, e.g. `08 - Puines.mkv`.
- **Season from a name**: `\b(?:S|(?:Season|Saison|Temporada|Staffel|Stagione)[ ._-]?)(\d{1,2})\b` (case-insensitive).

For each file in a folder whose override is a TV show (or which has no override):

1. If pattern A matches, use that season and episode. A `force_season` override replaces the season.
2. Otherwise, if pattern B matches, the episode comes from B. The season is the first of these that exists:
   - the forced season;
   - the **season of the nearest subfolder** between the root folder and the file (e.g. `…/Game.Of.Thrones.Saison.3.MULTI…/08 - Puines.mkv` gives season 3);
   - the override's `season`;
   - the season in the root folder name.
3. Otherwise the file is unnumbered and stays visible under the folder as an "extra".

Movies: every file is listed. `isMain` = the largest file.

Unlike Kodi's export, the app **never asks** for a season during refresh. Bare episodes with no season stay unnumbered, and the folder gets a badge "N episodes need a season" that opens the season editor (§9.4).

## 8. Supabase

The schema is fixed by `supabase/migrations/*.sql` in this repo: `members`, `accounts`, `titles`, `seasons`, `episodes`, `overrides`, `subtitles`, `media_files`, `sync_runs`, and the RPCs `is_member`, `is_admin`, `prune_orphan_titles`. Row-level security allows reads for members and writes for admins. The app needs:

- Supabase project URL. If a URL with a path is pasted, keep only `scheme://host`.
- Publishable (anon) key.
- Email and password of a user listed in `members`.

### 8.1 Fetch (merge remote into local)

- Remote = `{folder_name: raw}` for rows where `raw` is an object.
- Folders only in remote are **added**.
- Folders only local are **kept**.
- Folders in both but with different JSON are **conflicts**. The default is to keep local. A banner reads "N overrides differ from Supabase — Review". Review shows a list with a per-row choice (local/remote) and a "Use all remote" button.
- Before applying any change, snapshot the old overrides as `overrides.backup.json` in the app's container, keeping one backup.

### 8.2 Push

Do it exactly in this order. `runStarted` is an ISO-8601 UTC timestamp taken at the start, and every row written gets it.

1. **Guards.**
   - Refuse when there are no local overrides. Never mirror an empty set, because that would wipe the catalog.
   - Refuse when the user isn't an admin.
2. **Stale overrides.**
   - `remote_folders − local_folders`. If there are any, ask: *"N folders exist in Supabase but not on this device. Delete them from Supabase?"* Show up to 10 names.
   - Answering "No" keeps them, and step 9 then skips both deletes.
3. **Title rows**: one per title key (§3.3), from the overrides, with columns `key, media_type, title, year, tmdb_id, tvdb_id, imdb_id, plot, poster_url(=thumb)`. Leave **null columns out** of the row so the values already stored are kept.
4. **Seasons per title**: the set of season numbers among the numbered files.
5. **TMDB details** for titles that have a `tmdb_id` and meet any of these:
   - not in remote `titles`;
   - remote `tmdb_synced_at` is null;
   - their seasons aren't a subset of remote `episode_seasons`;
   - `tmdb_synced_at` is ≥ 30 days old;
   - the user chose **"Refresh every title"**.

   Fetch them with `GET /{tv|movie}/{id}?append_to_response=external_ids,season/1,season/2…`. That's at most 19 seasons per request, so chunk them. Then fill in the row:
   - `original_title`
   - `tagline`
   - `fanart_url` (backdrop `w1280`)
   - `genres` (names)
   - `rating` (`vote_average`, 2 decimals)
   - `premiered` (date)
   - `runtime` (movie `runtime`, or TV `episode_run_time[0]`)
   - `status`
   - `episode_seasons` = remote ∪ fetched
   - `tmdb_synced_at` = runStarted

   Also fill these only when the override left them empty: `poster_url` (`w500`), `plot`, `year`, `imdb_id`, `tvdb_id`.
6. **Insert** a `sync_runs` row `{started_at}` and keep its id.
7. **Upsert**, in this order:
   1. `accounts` (`id, name, webdav_url, username`), on `id`.
   2. `titles`, on `key`, returning `id,key`.
   3. `seasons`, on `title_id,season_number`, for TV titles fetched in step 5: all TMDB seasons, poster `w500`.
   4. `episodes`, on `title_id,season_number,episode_number`, for the fetched seasons: still image `w300`.
4. **Overrides and subtitles.** Overrides are upserted on `folder_name`, one row per local override:
   - `title_id`
   - `source` (`auto`/`manual`)
   - `media_type`, `title`, `year`, the ids, `thumb_url`, `plot`, `season`
   - `force_season` (only true when `season` is set)
   - `raw` (the full JSON)
   - `synced_at`

   Subtitles are upserted on `folder_name,url`, one per `subs` entry with `url` and `fileName`:
   - `season/episode` from pattern A on `fileName` (TV only)
   - `language` (`sp` → `es`)
   - `hearing_impaired = hi`
   - `fps_from`, `fps_to`, `shift_ms`
5. **Delete stale rows** (only when the user didn't answer "No" in step 2):
   - `overrides where synced_at < runStarted`
   - `subtitles where synced_at < runStarted`
6. **media_files**, upserted on `account_id,remote_path`, one per file:
   - `folder_name`, `title_id`, `remote_path` (decoded), `file_name`, `size_bytes`
   - `season_number`, `episode_number`, `is_main`
   - `webdav_url`
   - `stream_url` = `webdav_url` with `user:pass@` inserted (both percent-encoded)
   - `last_seen_at`

   Then, **only for accounts listed completely**, delete `media_files where account_id = X and last_seen_at < runStarted`.
7. **Removed accounts**: an account deleted on this device since the last push gets `delete from accounts where id = X`, which cascades to its files. Keep a local tombstone list until that succeeds.
8. **Finish.**
   - Run `rpc('prune_orphan_titles')`.
   - Update `sync_runs` with `finished_at` and `stats`. The stats keys are `tmdb_fetched, titles, seasons, episodes, overrides, subtitles, overrides_deleted, files, files_deleted, titles_pruned, unidentified_folders, incomplete_accounts`.
   - Show those stats in a summary sheet.

Batching: upserts go in chunks of 500 rows. Rows in one request must have the same key set, so group them by key set. Collapse duplicates on the conflict columns (last wins), because Postgres refuses to update one row twice in one statement.

Errors: if PostgREST mentions "schema cache", show *"The database is missing a migration — run the files in supabase/migrations"*.

### 8.3 Keep-alive

Free Supabase projects pause after 7 days idle. Register a `BGAppRefreshTask` that calls `rpc('is_member')` about once a day. Also call it on every app launch. Failures only show a small warning in Settings.

## 9. UI

Four tabs: **Library**, **Unidentified**, **Accounts**, **Settings**.

### 9.1 Library (gallery)

- An adaptive `LazyVGrid` of 2:3 posters: 3 columns on iPhone portrait, 5–8 on iPad. Each cell shows the poster, the title, the year, and a small badge when the title has folders on more than one account or folders still needing a season.
- **One cell per title** (title key), not per folder. A show whose seasons come from 3 folders shows once.
- Segmented control: *All · Movies · Shows*. Search field (title, original title, folder name). Sort by *Recently added* (newest `MediaFile` seen), *Title* or *Year*.
- Filter chips by account.
- When there's no poster, show a placeholder with the title text.
- Pull to refresh runs the pipeline (§6). A thin progress bar under the nav bar shows the current step while it runs.

### 9.2 Title detail

- Fanart header, poster, title, year, genres, rating, runtime/status, plot. These come from Supabase `titles` once pushed, and from TMDB on demand before that.
- **Movie**: a list of folders → files, with the main file first and its size shown. Tapping a file opens the play menu (§10).
- **Show**: a season picker built from the numbered files, then episode rows. Each row shows the TMDB still, the name and the air date (from `episodes` when available), followed by the file name and size in secondary text. Unnumbered files sit under "Extras".
- The ⋯ menu: **Fix match**, **Set season**, **Mark as manual** / **Reset to automatic**, **Show folders**.

### 9.3 Fix match

- A sheet with a search field prefilled with the parsed title, a *Movie/Show* toggle and a year field.
- Results come from the TMDB search, with poster, title, year and overview.
- Choosing a result writes the entry with **`"source": "manual"`**. It keeps `subs`, `season` and `force_season`, and fills in the external ids.
- A "Not a movie or show" choice instead writes `{"title": <folder name>, "type": "movie", "source": "manual"}`. That keeps the folder out of auto-identify.

### 9.4 Set season

- A number field and a "Replace season numbers in file names" toggle (`force_season`).
- The editor shows a live preview of how the files will be numbered.

### 9.5 Unidentified

- Lists the folders with no identified override, grouped by account.
- Each row shows the folder name, the parsed title, and the reason (no TMDB result / best score 0.74 for "X").
- Tapping a row opens Fix match. A toolbar button **Identify again** retries all of them.

### 9.6 Accounts

- A list of accounts showing name, URL host, username, file count, last listed time and a ⚠︎ when incomplete. **No limit** on how many.
- Add/edit form:
  - Fields: name, WebDAV URL (default `https://webdav.torbox.app`), username, password.
  - **Test connection** runs a `PROPFIND /` and reports success or the HTTP error.
  - On save the account gets its remote id (§3.5).
- Accounts can be switched off and on, and deleted with a swipe. Deleting asks for confirmation and queues the removal for the next push (§8.2 step 7).

### 9.7 Settings

- **TMDB**: the v4 read access token, with a **Test** button.
- **Supabase**:
  - project URL, publishable key, email, password;
  - status line: *Signed in as … · admin/reader · last push …*;
  - buttons **Fetch now**, **Push now** (with *Changed only / Refresh every title*), **Sign out**.
- **Identification**: *Re-identify automatic matches*.
- **Data**:
  - *Export overrides.json* (share sheet), which also makes a backup the Kodi addon can read;
  - *Import overrides.json*, which merges like Fetch;
  - *Clear local cache*.
- **Diagnostics**: the last 200 log lines, plus a share button.

## 10. Playback (v1)

- iOS's built-in `AVPlayer` can't play MKV/AC3/DTS, which covers most of the library. So v1 **hands playback off** to an external player.
- The play menu offers:
  - **Infuse**: `infuse://x-callback-url/play?url=<percent-encoded stream_url>`.
  - **VLC**: `vlc-x-callback://x-callback-url/stream?url=<…>`.
  - **Copy stream URL**.
- Both players' URL schemes go in `LSApplicationQueriesSchemes`. Only installed players appear in the menu.
- `stream_url` carries the WebDAV credentials in the URL. Build it on demand from the Keychain and never log it.

v2 option: an embedded player (VLCKit or KSPlayer) that also loads the folder's saved subtitles and applies their FPS/shift adjustments.

## 11. Non-functional requirements

- **Scale**: must stay smooth with 5,000 root folders and 100,000 files. Listing and identification run off the main actor. SwiftData writes are batched, about 200 per save.
- **Cancellation**: every pipeline step checks `Task.isCancelled`. A cancelled push leaves Supabase consistent, because each upsert is idempotent and deletes run only after all upserts succeeded.
- **Rate limits**: at most 4 TMDB requests in flight. On HTTP 429, wait for `Retry-After` and then retry.
- **Network**: WebDAV and TMDB requests time out after 30 s, Supabase requests after 60 s. On a Supabase 401, sign in again once and retry.
- **Background**: refresh can continue for about 30 s after the app is backgrounded (`beginBackgroundTask`). No background listing beyond that in v1.
- **Privacy**: there's no analytics. Credentials are stored only in the Keychain. Logs redact `user:pass@`.

## 12. Test fixtures (port as unit tests)

| Input | Expected |
|---|---|
| `[ OxTorrent.com ] Game.Of.Thrones.Integral.(S01 à S08).MULTI.1080p.BluRay.HDLight.AC3.x264` | title `Game Of Thrones`, tvHint true |
| `The.Office.Complete.Series.1080p` | title `The Office`, tvHint true |
| `Breaking Bad Collection (2008)` | title `Breaking Bad`, year 2008 |
| `Dune.2021.1080p` | title `Dune`, year 2021 |
| `1917.2019.1080p.BluRay` | title `1917`, year 2019 |
| `Integral.Man.2019` | title `Integral Man`, year 2019 (no pack word stripped) |
| `Frieren - Sousou no Frieren S01` | queries `Frieren - Sousou no Frieren`, `Frieren`, `Sousou no Frieren` |
| file `Show.S01E02.mkv` | S1 E2 |
| file `Show.1x05.mkv` | S1 E5 |
| file `08 - Puines.mkv` in `<root>/Game.Of.Thrones.Saison.3.MULTI…/` | S3 E8 |
| file `Show - E21 [BD].mkv` with override `season: 2` | S2 E21 |
| file `Show.S04E01.mkv` with `season: 3, force_season: true` | S3 E1 |
| file `1080p.mkv` | unnumbered |
| `normalize("The Lord of the Rings: The Two Towers")` | `lord of the rings the two towers` |
| `SequenceMatcher("game of thrones integral", "game of thrones").ratio()` | ≈ 0.769 (why the pack-word strip exists) |

Generate the expected values for these tests by running the Python functions in `addons/plugin.video.torbox`, so the two implementations can't drift apart.

## 13. Milestones

1. **Accounts + listing**: account CRUD, Keychain, PROPFIND, recursive walk, and a folder list view.
2. **Identify + gallery**: name parsing, TMDB, local overrides, the gallery, and the Unidentified tab.
3. **Supabase fetch**: auth, merge, and conflict review.
4. **Supabase push**: the full §8.2 flow with a stats summary, checked against a test project by pushing from iOS, fetching in Kodi, pushing from Kodi and comparing rows.
5. **Detail views + fix match + set season**.
6. **Playback handoff**, keep-alive, and polish.

## 14. Open questions

1. **Account id ranges**: is reusing ids for matching `webdav_url`+`username` and starting iOS-only ids at 101 acceptable? The cleaner fix is a migration that adds `unique (webdav_url, username)` to `accounts` and an identity id, with Kodi updated to look its id up the same way.
2. **Conflict default**: on Fetch, should remote win for `auto` entries and only manual ones ask? That would cut the review noise.
3. **Reader mode**: should non-admin users get a reduced app (gallery + play only, from Supabase without listing WebDAV)? That's essentially the planned "user addon" on iOS.
4. **Subtitles in v1**: are stored subtitles needed in the handoff? Infuse can take one subtitle URL via `&sub=`.

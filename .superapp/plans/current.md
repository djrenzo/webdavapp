---
title: TorBox Library — Midnight Cinema, Local-First Build
status: approved
updatedAt: 2026-11-25T18:14:49.288Z
approvedAt: 2026-11-25T18:14:49.288Z
proposal:
  messageId: chm_01m89ygjhnfzstvvrdv03dw5xs
  toolCallId: call_34cbcfc09ca154a38b2b55bf03938f39
---
**Outcome:** Build TorBox Library as a native catalog administrator that ultimately shares Kodi’s existing Supabase catalog without changing its compatibility contract. The first build delivers a working, locally saved Library gallery with editable sample data; live accounts, identification, sync and playback follow in the dependency-ordered roadmap below.

### Confirmed
- Product: **TorBox Library**, for iPhone and iPad, using SwiftUI, iOS/iPadOS 17+, Swift 6 strict concurrency, SwiftData and async `URLSession` networking.
- The complete v1 has four tabs: **Library, Unidentified, Accounts and Settings**, unlimited WebDAV accounts, TMDB identification, corrections, season editing, Supabase fetch/push and external-player handoff.
- Kodi interoperability is mandatory: folder-name override keys, raw JSON preservation, string IDs, manual-match protection, exact title keys, exact episode numbering and the existing Supabase schema are not redesign opportunities.
- WebDAV passwords, Supabase credentials/session secrets and the personal TMDB token belong in Keychain. No analytics; redact credentials from diagnostics.
- **Chosen design: Midnight Cinema**, matching the attached mockup:
  - Dark appearance. Implementation palette: background `#0D131B`, surface `#222934`, elevated surface `#303947`, blue tint `#5B87FF`, primary text `#F5F7FA`, secondary text `#949EAE`, warning amber `#FFB34D`.
  - Native SF Pro typography, a bold large Library navigation title, readable poster captions and smaller muted years/status text.
  - Poster-led, medium-dense composition: three columns on iPhone portrait, adaptive five–eight columns on iPad, 2:3 posters and approximately 10–12 pt gaps.
  - Continuous rounded poster corners around 12 pt, subtle outlines, capsule account filters/badges and native rounded search/segmented controls. Blue selected states and progress; amber season warnings.
  - Preserve the native tab-bar treatment shown in the reference when all four tab destinations are available. Use APIs compatible with iOS 17 rather than requiring newer OS-only effects.

### Assumptions and unresolved choices
- Retain the specified account-ID algorithm: reuse a matching URL/username row; otherwise allocate `max(100, max(existing IDs)) + 1`. No identity migration or Kodi change is included.
- Retain **local wins by default for every differing override**, with per-row review and “Use all remote”; automatic entries do not silently adopt remote versions.
- Retain the specified reader behavior: members without admin permission can list, identify and edit locally, but cannot push. A gallery-only reader product is not included.
- Preserve saved subtitles unchanged; do not add subtitle attachment to player handoff in v1.
- The referenced Kodi Python and SQL migration files have not been verified from this fresh-project context. They are required inputs before implementing compatibility-sensitive sync; do not invent database columns or claim Python-derived expected values have already been generated.
- The first build is deliberately local-only. Sample data is explicitly marked as a **Demo library**, remains separate from future live data and can never be pushed accidentally.

## Now

**One working loop:** browse the Library → search/filter/sort → edit a local catalog entry → see regrouping and badges update → retain changes across launches. This build has no backend, credentials or live service integration.

1. **Save the chosen design direction to project memory.** Record the attached Midnight Cinema reference, palette, typography, density and shapes in `.superapp/memory.md` during the build, together with the non-negotiable Kodi compatibility rules.
2. **Establish the local catalog foundation.** Under the app source folder, add SwiftData storage for demo folder/file records and overrides, plus lightweight demo-account labels. Keep raw override JSON as the source of truth; derive convenience fields without discarding unknown keys or nested data. Keep storage and services behind interfaces so live account/network services can be added without rewriting the gallery.
3. **Provide editable, persistent seed data.** Include representative movies and shows from the selected preview, multiple folders grouped into one title, a title spanning accounts, files with episode numbers, a season-needed example and a missing-poster example. Seed once, retain subsequent edits and provide an explicit demo reset action. Demo account references do not allocate real Supabase account IDs.
4. **Implement compatible title grouping.** Port `normalize()` exactly, apply the stated ID precedence and default missing `type` to `tvshow`. Group by the exact title key; apply manual entries’ non-empty metadata before automatic entries. Treat only exactly `source: "auto"` as automatic. Keep IDs as strings.
5. **Build the Library gallery.** Implement the selected three-column poster layout, All/Movies/Shows control, title/folder search, account chips and Recently added/Title/Year sorting. Persist a first-seen timestamp for file records so “Recently added” has a defined local meaning. Show multi-account and season-needed badges and a title-text poster fallback. Use public seeded poster URLs with a 200 MB disk-cache budget; no TMDB token is needed for this demo.
6. **Add a small local editor sheet.** Let the user edit title, movie/show type, year and folder season/force-season values, and adjust the sample folder/file labels needed to exercise the gallery. Update the existing JSON object rather than rebuilding it from a restricted model; preserve `subs` and unknown fields. A saved override edit is explicitly manual. This is a local editor, not the later TMDB Fix match workflow.
7. **Keep unfinished capabilities honest.** Refresh/Push and other remote actions are not simulated. Do not show fake network progress, fabricated sync success or inactive tab destinations. Add the remaining tabs and the full refresh treatment as their real flows arrive in Next.

**Implementation organization:** use `project.yml` for deployment/device configuration. Suggested responsibilities under the app source folder are `Models/CatalogModels`, `Persistence/CatalogStore`, `Services/OverrideJSON`, `Services/TitleGrouper`, `Features/Library/LibraryView` and `Features/Library/LocalEntryEditor`; these are proposed locations, not inspected repository findings. Use value-type, Sendable view data and a persistence actor boundary rather than sharing mutable SwiftData models across tasks.

**Not in this build:** real account CRUD, WebDAV requests, TMDB searches, Supabase authentication or sync, title/episode detail screens, external playback, background jobs and production-data import/export. Automated tests and validation workflows are not part of Now.

## Next

**Live integrations and the remaining v1, in dependency order.** Each item is a subsequent user-visible outcome, not part of the first build.

1. **Enable Cloud** — unlock secure live-integration/server support while keeping Kodi’s existing Supabase project as the sole shared catalog; do not create a second library or replace its schema.
2. **Connect the existing Supabase project safely** — accept the project URL/key and email/password, show member/admin status, support sign-out and local-only use when unconfigured; inspect the referenced SQL and Kodi sources before shared-database writes.
3. **Manage unlimited real accounts** — add/edit/test/enable/delete WebDAV logins, store passwords in Keychain, resolve permanent remote IDs and show connection/listing status; explain shared-account deletion and retain removal tombstones until acknowledged.
4. **Discover the complete WebDAV library** — list root folders and recursively collect eligible videos, with counts, timestamps and visible incomplete-account warnings instead of silently treating failed scans as complete.
5. **Fetch and import overrides without losing local work** — page remote overrides, preserve remote-only and local-only entries, make the single backup, review JSON conflicts and support compatible `overrides.json` import.
6. **Identify and refresh the live gallery** — add TMDB token/test settings, exact release parsing and matching, live saved matches, the Unidentified tab with reasons/retry, and re-identification that never overwrites manual entries.
7. **Inspect and correct titles** — add movie/show detail screens, metadata enrichment, season/episode rows, Extras, folder inspection, manual TMDB Fix match, “Not a movie or show,” manual/automatic controls and live-preview season editing.
8. **Establish Kodi parity before enabling production writes** — derive golden fixtures from the actual Python functions, cover raw JSON/merge/title/numbering behavior and verify an iOS → Kodi → iOS round trip against a separate test database.
9. **Push the shared catalog as an admin** — implement the full ordered Supabase export, metadata freshness rules, safe stale-row handling, account removals, pruning, cancellation recovery and final statistics; offer Changed only/Refresh every title.
10. **Complete the unified refresh flow** — connect sign-in → fetch → listing → identification → numbering → admin push, with pull-to-refresh, a thin gallery progress bar, step/counter sheet, cancellation and reader-mode write restrictions; standalone Push also fetches first.
11. **Open files in installed players** — show Infuse/VLC only when available, offer Copy stream URL, and construct authenticated URLs on demand without logging them.
12. **Finish data and diagnostics settings** — export Kodi-readable overrides with a backup, safely clear local cache, show the last 200 redacted log lines and share diagnostics without secrets.
13. **Add best-effort background support and scale polish** — launch/background membership checks, a short background refresh allowance, retry/timeouts and efficient scrolling/listing for 5,000 folders and 100,000 files.

### Implementation constraints for Next

**Accounts and WebDAV**
- Normalize the account base URL by removing trailing `/`; match accounts by that URL plus username. Once a real remote ID is assigned, it never changes. Local-only account setup needs a pending remote-identity state; never invent an ID that might collide with Kodi or another device.
- Hand-write `PROPFIND` and `XMLParser` handling, `Depth: 1`, Basic authentication and the requested property body. Preserve the listed encoded file URL separately from decoded paths; NFC-normalize names, skip the self response and hidden root collections, apply the exact video-extension list and exclude samples and `.strm`.
- Limit WebDAV listings to four in flight per account. Any listing failure makes that account incomplete. Keep useful observed files, but never delete its stale remote files based on a partial scan.

**Identification, correction and numbering**
- Port the release parser, TV heuristics, query splitting, year fallback, top-ten scoring and Python-compatible `SequenceMatcher` behavior, including its matching-block semantics; do not substitute edit distance. Retain the 0.7 similarity and 0.8 acceptance thresholds.
- Limit all TMDB traffic to four requests in flight and honor `Retry-After`. Fetch external IDs; preserve `subs`, `season`, `force_season` and unknown JSON when producing an automatic or manual match.
- Apply the exact file-numbering patterns and nearest-subfolder season precedence. Bare episodes without a season remain unnumbered and get the required badge rather than prompting during refresh. Movies keep all files and mark the largest as main.
- A title representing multiple folders needs a folder-selection step for folder-specific Fix match/Set season actions; default to the only folder when there is one. This is an implementation assumption, avoiding unintended edits to every season folder.

**Supabase fetch and push**
- Use `supabase-swift` Auth/PostgREST against the existing project, including `is_member`/`is_admin`, session refresh and one re-authentication/retry on 401. A nonmember cannot access remote data; local catalog access remains available.
- Fetch `folder_name,raw` in ordered pages of 1,000. Compare JSON objects semantically, not by byte ordering. Snapshot existing overrides to one `overrides.backup.json` before applying merge changes.
- Preserve the specified push phases and fields: guards and stale-folder consent; grouped title rows with null columns omitted; numbered season discovery and stale/missing TMDB enrichment; `sync_runs`; account/title/season/episode upserts; overrides and preserved subtitles; stale-row handling; media-file upserts and complete-account pruning; acknowledged account tombstones; orphan pruning and final stats.
- Use the single UTC `runStarted` timestamp in the applicable row timestamp fields. Enrich TMDB details in at-most-19-season chunks; retain the remote/fetched season union and override-first metadata rules. Keep subtitle language conversion, filename numbering and adjustment fields compatible.
- Batch writes at 500 rows, grouped by identical key sets; collapse duplicate conflict keys with last-wins semantics. Never mirror an empty override set. A “No” answer to stale override deletion skips both override and subtitle deletions.
- Show the exact migration guidance for PostgREST schema-cache errors. Emit the specified summary stats: `tmdb_fetched`, `titles`, `seasons`, `episodes`, `overrides`, `subtitles`, `overrides_deleted`, `files`, `files_deleted`, `titles_pruned`, `unidentified_folders`, `incomplete_accounts`.

**Operational behavior**
- WebDAV/TMDB timeouts are 30 seconds; Supabase is 60 seconds. Check cancellation throughout. Batch SwiftData writes around 200 records per save and keep parsing/listing/identification off the main actor.
- Cache title/episode enrichment separately from override raw JSON. Use lazy, indexed queries and precomputed gallery summaries rather than materializing all 100,000 files for each redraw.
- Register the background task and call `is_member` at launch. Background scheduling and the approximate 30-second continuation allowance are best-effort, not guarantees.
- Add installed-player query schemes through project configuration. Percent-encode credentials and nested player URL parameters correctly. Reader-visible, credential-bearing URLs require particular care as noted below.

### Material risks and gates
- **Deletion-order contradiction:** §8.2 places stale override/subtitle deletion before media-file upserts, while §11 says no deletes until all upserts succeed. Do not silently redesign this contract. Keep destructive sync disabled until the actual Kodi implementation and intended safety rule resolve the discrepancy. Multi-request PostgREST pushes are resumable/idempotent, not atomic; cancellation can leave a partially updated run.
- **Shared credential exposure:** the required remote `media_files.stream_url` contains WebDAV credentials. This conflicts with a literal “credentials stored only in Keychain” guarantee: database members who can read that column can obtain them. Confirm that shared access is intended before production push; changing it would require a coordinated Kodi/schema contract change. Never persist an additional local stream URL or include it in logs.
- **Account-ID races:** `max + 1` is not atomic across devices, and the stated schema has no confirmed URL/username uniqueness constraint. Recheck and reject collisions rather than upserting over another account; a fully atomic fix may require the separately discussed coordinated migration.
- **Missing reference sources:** the Python and migration files must be available before parity claims or live sync. Specification examples are provisional until derived from those sources.
- **Background keep-alive:** iOS does not guarantee daily execution, so this cannot promise that a free Supabase project never pauses.

## Later

- Embedded playback with VLCKit/KSPlayer, saved subtitle attachment and FPS/shift adjustment support.
- Subtitle search/editing and richer player-handoff subtitle support.
- A reduced, Supabase-only gallery/player app for readers.
- A coordinated account identity/uniqueness migration and corresponding Kodi update, if desired.
- Downloads and longer-running background library refresh.
- **Excluded from the catalog-admin v1:** STRM/NFO export, Kodi `sources.xml`, a local reconnecting streaming proxy, phone-setup QR server and top-movie/show lists.

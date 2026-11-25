# Project Memory

## Project

- TorBox Library is a native SwiftUI catalog administrator, ultimately interoperable with Kodi's `plugin.video.torbox` and its existing Supabase catalog.
- App source: `TorBoxLibraryManager/`. `project.yml` is authoritative; never edit generated project metadata.
- Approved scope is `.superapp/plans/current.md`: implement only Now until the user requests later milestones.
- Selected preview target is iPhone; preserve the existing iPhone device-family configuration. Wider gallery layouts remain adaptive.
- The user selected the attached **Midnight Cinema** mockup. Prefer native SF Pro, dark poster-led composition, not web dashboards.

## Decisions

- Midnight Cinema palette: background #0D131B, surface #222934, elevated #303947, blue #5B87FF, text #F5F7FA, muted #949EAE, amber #FFB34D.
- Three 2:3 poster columns in compact width, five–eight at wider widths, 10–12 pt gaps, continuous 12 pt corners, subtle outlines, capsule account filters and badges. Use native large Library title, search and segmented controls. Add native tabs only when their flows work.
- Now is a local-only **Demo library**, with an isolated named SwiftData store and no real account IDs, credentials or push path. Editable seeds initialize only when no records/seed marker exist. Reset is explicit and confirmed.
- Persist raw JSON overrides; edit the existing object without dropping nested subtitles or unknown keys. Saved local edits are manual. Send only value snapshots across the persistence actor boundary.
- Group folders by the exact Kodi title key, with type defaulting to tvshow, TMDB → TVDB → IMDb → normalized title/year precedence; IDs remain strings. Only exactly source=auto means automatic. Manual non-empty metadata wins.
- Normalization is NFKD, combining-mark removal, lowercasing, ampersand expansion, ASCII alphanumeric runs and one leading article removal.
- Folder-specific editing uses a folder selector for grouped titles and asks before discarding unsaved edits when switching folders. Season previews use the specified numbering precedence; movies retain all files and the largest is main.
- Folder-name overrides are shared across accounts. Renaming one of several same-name folders copies its raw override to the new key and keeps the old key for remaining folders; collisions are rejected rather than merged silently.
- First-seen file timestamps define the demo's Recently added sort. Public TMDB posters use a 200 MB URLCache budget. Poster failures fall back to a title card.
- No fake refresh progress, live-service success, disabled destinations, or remote controls in the local-only build.

## Pitfalls

- The fresh starter does not contain the referenced Kodi Python or SQL migrations. They are mandatory before parity claims or compatibility-sensitive sync implementation.
- Shared account ID allocation uses URL+username matching, else max(100, max IDs)+1; concurrent clients can race. Do not invent permanent IDs for local/demo accounts.
- Supabase conflicts default to local; unknown JSON and subtitles survive every merge/edit. Never seed over unreadable or saved data.
- Spec push deletion ordering conflicts with the no-delete-before-all-upserts safety statement. Resolve against actual Kodi behavior before destructive sync.
- Remote credential-bearing stream_url exposes WebDAV credentials to database readers; production writes require resolving intended shared access. No stream URLs or credentials in logs/local demo data.
- iOS daily keep-alive/background scheduling is best-effort, never guaranteed.

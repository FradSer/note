# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
swift build
swift build -c release

# Run without installing
.build/debug/note --help
.build/debug/note notes list
.build/debug/note notes list --json        # all read/write commands support --json
.build/debug/note folders list

# Install
swift build -c release
cp .build/release/note /usr/local/bin/

# Format (Biome is for JS; Swift uses swift-format)
swift format --in-place --recursive Sources Package.swift

# Tests
swift test
swift test --filter NoteModelsTests
swift test --filter NoteMarkdownConverterTests

# Sync CLI
.build/debug/note sync                       # full bidirectional sync (pull, then push)
.build/debug/note sync status
.build/debug/note sync config --api-url <URL> --api-token <TOKEN> --device-id <ID>
.build/debug/note sync push [--type notes|folders|all]
.build/debug/note sync pull [--type notes|folders|all]

# Preferences (category -> folder routing)
.build/debug/note prefs add ideas Ideas      # map a category to a folder
.build/debug/note prefs list [--json]
.build/debug/note prefs get ideas            # show folder for a category (incl. env)
.build/debug/note prefs remove ideas
.build/debug/note notes create --title "X" --category ideas   # resolves folder via prefs

# Worker development (Cloudflare) -- run from skills/apple-notes/references/worker/
pnpm install
pnpm run dev                                 # local dev
pnpm run deploy
pnpm run db:migrate                          # local D1 migration
pnpm run db:migrate:remote                   # remote D1 migration
pnpm test                                    # worker tests (vitest-pool-workers)
pnpm run typecheck
```

## Architecture

Pure Swift CLI for managing Apple Notes, with Cloudflare D1 cloud sync. It is the
notes-focused counterpart to the `event` CLI (Reminders/Calendar) and is designed
to be complementary -- separate worker, separate D1 database, separate config.

### Target Structure

| Target | Type | Purpose |
|--------|------|---------|
| `NoteModels` | Library | Domain models (`Note`, `NoteFolder`), formatters, sync models/DTOs, HTML<->Markdown converter |
| `NoteSync` | Library | `D1SyncClient`, encryption, SQLite store, `LinuxSyncService`, Cloudflare direct-access services |
| `NoteCommands` | Library | Shared sync subcommands (`config`, `status`) |
| `note` | Executable | The CLI; AppleScript-backed `NotesService`/`FolderService`, macOS `SyncService`, commands |
| `skills/apple-notes/references/worker/` | TypeScript | Cloudflare Worker API (Hono + D1), bundled in the skill |

Dependencies flow inward: Commands -> Services -> AppleScript/D1. The `note`
executable requires the `-parse-as-library` compiler flag (set in Package.swift)
for ArgumentParser `@main`.

### Key Architectural Decisions

**No public Notes framework**: Apple exposes no public API for Notes, so every
macOS operation shells out to `osascript`. `NotesScriptRunner` runs AppleScript on
stdin and passes all user content (folder names, titles, bodies, IDs) as `argv`
arguments -- never string-interpolated into the script -- so note content
containing quotes or backslashes can never corrupt or inject into the script (the
fragility documented in `antoniorodr/memo`, which this tool's AppleScript is
modeled on).

**Body format**: Apple Notes stores bodies as HTML; everything here uses Markdown.
`NoteMarkdownConverter` converts HTML -> Markdown on read and Markdown -> HTML on
write. A note's title is the first line of its body, matching Apple Notes. The
converter handles the common subset (headings, bold/italic, lists, links,
entities); see Known Limitations.

**End-to-end encryption**: note bodies are encrypted with AES-GCM
(`swift-crypto`) before they reach Cloudflare D1 and decrypted on pull, so the
Worker only ever stores ciphertext. The key comes from `NOTE_ENCRYPTION_KEY`
(base64, 32 bytes). Titles and folder names stay plaintext so notes remain
listable without the key. Encryption is applied inside the sync push/pull closures
(`SyncService`, `LinuxSyncService`) and the direct-access `CloudflareNoteService`.

**Output formatting**: commands return domain models that `OutputFormatter`
implementations render (Markdown default, JSON via `--json`).

**Search**: the CLI provides only keyword search (`note notes search` --
case-insensitive substring over title + body, returning full notes). Semantic /
fuzzy search is intentionally **not** built into the CLI: it is an agent-side
keyword-retrieval workflow documented in the `apple-notes` skill (the calling LLM
expands the query into bilingual terms, runs several searches, reads candidates,
and reasons -- like Claude Code's code search). There is **no embedding / vector /
cloud-index code by design** -- it keeps D1 end-to-end encrypted and the corpus is
small. If on-device semantic search is ever wanted, the deferred option is a
**local** multilingual model with vectors as a local-only derived cache (never
synced) -- explicitly not a cloud embedding service that would see note plaintext.

### Sync Architecture

`SyncService` (macOS) and `LinuxSyncService` (other platforms) implement
`SyncServiceProtocol` and orchestrate push/pull/delete between the local store and
Cloudflare D1 via `D1SyncClient` (AsyncHTTPClient). Pull order: folders -> notes
(dependency order). Bare `note sync` runs `FullSync` (the `defaultSubcommand`):
pull then push in a single locked session.

**Config storage**: `SyncConfigStore.load()` reads from environment variables
first (`NOTE_SYNC_API_URL`, `NOTE_SYNC_API_TOKEN`, optional `NOTE_SYNC_DEVICE_ID`
defaulting to the hostname), falling back to `~/.config/note-sync/config.json`.
Setting exactly one of the two required env vars is an error. Sync state lives in
`~/.config/note-sync/` behind an exclusive file lock (`.lock`): `cursors.json`,
`id-mapping.json` (local<->remote), `state.json` -- all mode `0o600`. API URL must
be HTTPS.

**Folder blacklist**: `SyncExclusionStore` (NoteSync) loads a set of excluded
folder names from `NOTE_SYNC_EXCLUDE_FOLDERS` (comma/newline-separated) unioned
with `~/.config/note-sync/exclude.json`; `FolderBlacklist` (NoteModels) matches
case-insensitively after trimming. Both `SyncService` and `LinuxSyncService` load
it once at init and apply it on both directions:
- **Push** filters blacklisted notes/folders out of the snapshot, so the engine's
  deletion-candidate path purges any copy already on D1, exactly once (after the
  purge the remote id leaves `knownRemoteIds`, so it does not re-fire). On Linux,
  `pushLocalOnly`'s `removeRecord` callback is guarded so the purge **never
  hard-deletes the local SQLite row** of a blacklisted note (`pushSnapshot` on
  macOS has no such callback, so Apple Notes is unaffected).
- **Pull** drops blacklisted items at the boundary via `FolderBlacklist.filteringPull`
  inside the `pull:` closure (before decrypt), preserving the cursor/`hasMore`. The
  engine therefore never sees them: it cannot create them locally, delete a local
  copy via a tombstone, or record them as known remote ids (which would later make
  them deletion candidates and purge them from other devices). This is why the
  filter lives in the closure, not in `applyUpsert`/`applyDelete` — those run after
  the engine has already recorded state. Since an Apple Notes move creates a new id
  (a note's folder is immutable per id), server-folder filtering is equivalent to
  local-folder protection, so no separate `protectedIds` set is needed.

Moving a note out of an excluded folder makes it resume syncing on the next push;
moving one in purges it from D1. **Purge propagates**: because it soft-deletes the
cloud copy, any other device that syncs and has not excluded the same folder will
delete its local copy on the next pull — so set the same blacklist on every device.
Manage with `note sync exclude {list,add,remove}`; `note sync status` shows the
effective set.

**Conflict resolution**: last-write-wins. A pull never overwrites a local copy
modified more recently than the server's version; that copy is pushed on the next
sync. The Worker's pull cursor is keyed on a monotonic per-table `seq` so a stored
cursor can never be stranded above a future write.

**Worker** (`skills/apple-notes/references/worker/`): Hono on Cloudflare Workers with D1, the
entity-agnostic runtime from `apple-sync-kit` (the kit ships no business schema). Endpoints at
`/api/v1/{entity}/{operation}` where entity is `notes`, `note_folders`, or `note_preferences`.
Push (POST batch upsert, last-write-wins), pull (GET with `(seq, id)` cursor pagination; a `device`
query param excludes a device's own writes), delete (soft-delete). Auth via `API_TOKEN` Bearer
secret. **note owns its own schema** under `skills/apple-notes/references/migrations/`
(`0001_note_notes_initial_schema`, `0002_note_notes_seq_cursor`,
`0003_note_preferences_initial_schema`, `0004_note_preferences_seq_cursor`); the deployment's
`wrangler.toml` points `migrations_dir` there. Preferences sync as a single row (id `default`,
whole-map LWW, plaintext). A daily cron purges records soft-deleted over 30 days ago.

### Platform Behaviour

- **macOS**: reads/writes Apple Notes directly via AppleScript. Requires
  Automation access to Notes (System Settings > Privacy & Security > Automation).
- **Other platforms**: no Apple Notes, so `note` works against a local SQLite
  database at `~/.local/share/note-sync/local.db`. Run `note sync` to populate it
  from D1, then use the same commands on that data.

## Known Limitations

- **AppleScript date precision**: note modification dates are read in local time
  and converted to UTC via `time to GMT`; historical dates across a DST boundary
  may be off by an hour, which only affects last-write-wins tie-breaking.
- **HTML<->Markdown fidelity**: Apple Notes' `set body` strips `<a href>` anchors,
  so `markdownToHTML` writes links as `label (url)` plain text -- the URL survives
  and Notes auto-links it, but you cannot write a labeled hyperlink whose anchor
  text differs from its URL. Markdown headings (`#`/`##`/`###`) are written as
  `<h1>`/`<h2>`/`<h3>` and render as bold, larger text -- but **AppleScript
  `set body` cannot apply Apple Notes' native paragraph styles** (Title / Heading /
  Subheading). The importer normalizes every `<h*>` (and any font-sized span) to a
  BODY paragraph; the Format menu shows "Body". This was verified directly in the
  Notes UI. Only Apple's file-import / paste path honors `<h*>` as a real style;
  the scripting path does not. Headings still round-trip back to `#`/`##`/`###`
  because the reader detects the 24/18/16px sizing Notes serializes them with, and
  it unwraps `<span>`/`<font>` styling and merges adjacent bold runs so mixed
  CJK/Latin headings don't produce stray `****` markers. List items gain blank
  lines between them; tables and inline images are not preserved (`set body` strips
  inline images -- the same limitation memo documents). Plain text, bold/italic,
  URLs, and bullet lists round-trip cleanly.
- **Moves create a new ID**: Apple Notes has no move verb, so `note move` copies
  the note to the destination folder and deletes the original (the note gets a new
  `x-coredata://` ID), matching memo's approach.
- **Listing cost**: `notes list`/`search` fetch every note body in one AppleScript
  call; on large libraries this takes a few seconds.

## Code Style

Configured via `.swift-format`: 2-space indentation, 100-character line length,
file-scoped declaration privacy. Run
`swift format --in-place --recursive Sources Package.swift`.

## Critical Constraints

- **macOS 14.0+** for the executable's Swift concurrency APIs.
- **Automation permission**: first run triggers the Automation prompt for Notes.
- **Encryption key**: `note sync` for notes requires `NOTE_ENCRYPTION_KEY` on
  every device; without it, folder sync still works but note sync throws a helpful
  error. Generate with `openssl rand -base64 32`.

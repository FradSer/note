---
name: apple-notes
description: Use this skill whenever the user wants to manage their Apple Notes using the `note` CLI tool. It covers listing, reading, creating, editing, moving, searching, and deleting notes and folders, and end-to-end-encrypted syncing to a Cloudflare backend. Works on macOS (via AppleScript) and on Linux (via a local SQLite database synced from the Cloudflare backend). Complements the `apple-events` skill (Reminders/Calendar).
argument-hint: "[what to capture or look up — empty to capture from context]"
---

# Apple Notes CLI (`note`)

Use the `note` CLI to manage Apple Notes directly from the terminal. You can list, read, create, edit, move, search, and delete notes, organize them into folders, and sync data across devices. It is the notes-focused companion to the `event` CLI (Reminders/Calendar) — same architecture, separate backend.

## Invocation & Arguments

Treat `$ARGUMENTS` as a free-form natural-language instruction and map it to the appropriate `note` command(s) documented below. Examples:

- `/apple-notes save a note titled "Trip plan" with my packing list` -> `note notes create ...`
- `/apple-notes what's in my Side Project Ideas note?` -> find the id via `note notes search`/`list`, then `note notes show --id <ID>`
- `/apple-notes move "Trip plan" to the Archive folder` -> resolve the id, then `note notes move ...`

### When no arguments are given

If `$ARGUMENTS` is empty, do **not** default to listing. Instead, infer intent from the current conversation:

1. **Scan the recent conversation** for something the user might want captured as a note — an idea, a snippet, a list, a draft, reference material, or a decision worth keeping.
2. **Confirm with the `AskUserQuestion` tool before creating anything.** Present the inferred title, body, and target folder so the user can confirm, adjust, or decline. Never create in the no-args path without explicit confirmation.
3. If **nothing captureable** is found, use `AskUserQuestion` to ask what the user would like to save rather than guessing.

## Setup & Constraints

`note` runs on macOS and Linux, with platform-specific storage backends. All note/folder commands below behave identically on both; only the underlying store differs.

- **macOS** — reads and writes Apple Notes directly via AppleScript (Apple exposes no public Notes framework).
  - Requires the Notes app to be accessible. The first run triggers an Automation permission prompt; the user must allow the terminal to control Notes under System Settings > Privacy & Security > Automation.
  - A note's **title is the first line of its body**, matching Apple Notes. Bodies are Markdown here and converted to/from Apple Notes' HTML automatically.
- **Linux** (and other non-Apple platforms) — there is no Apple Notes, so `note` reads and writes a local SQLite database at `~/.local/share/note-sync/local.db`. Run `note sync` first to populate it from the Cloudflare D1 backend (see [Cloud Sync](#cloud-sync)), then use the same commands to manage that local data.

## General Usage

All read/write commands support the `--json` flag to output results in JSON format, which is easier to parse (e.g. to grab a note `id` before a follow-up `show`/`edit`/`move`/`delete`).

## Notes Management

### List & Search Notes
- List all notes: `note notes list`
- Filter by folder: `note notes list --folder "Ideas"`
- Show one note with its full body: `note notes show --id <ID>`
- Search by keyword in title and body: `note notes search --keyword "invoice"` (also accepts `--folder`)

To act on a specific note, first resolve its `id` with `note notes list --json` or `note notes search --keyword "..." --json`, then pass that id to `show`/`edit`/`move`/`delete`.

### Fuzzy / semantic search (agentic retrieval)

`note` has no semantic index by design — for a conceptual or fuzzy query (e.g. "我那条关于冥想的想法", "what did I write about relaxing", "the note about AI glasses interaction"), do agentic retrieval instead of relying on a single keyword:

1. **Expand the query into terms in BOTH Chinese and English** — synonyms, translations, related concepts. e.g. relax -> `放松`, `冥想`, `meditation`, `正念`, `mindfulness`, `calm`.
2. **Run `note notes search --keyword <term> --json` for several of those terms.** Each matches a case-insensitive substring of the title or body in any language, so different terms surface different notes. The `--json` output already includes the full body.
3. For a small library, `note notes list --json` returns every note (with bodies) — skimming all titles, then reading the candidates, is often fastest.
4. **Union + dedupe** the candidate `id`s; read the most promising bodies (already present in the `--json` output, or via `note notes show --id <ID>`).
5. **Reason over the bodies** to pick the real match(es); answer citing note titles/ids. If nothing matches, broaden the terms or `list` and skim.

Notes:
- This is local keyword retrieval plus your own reasoning — **no embeddings, no vector index, no extra network calls**. Privacy is identical to any other `note` command: D1 stays end-to-end encrypted, and only the notes you actually read enter context.
- Bodies often hold secrets (backup codes, API keys). Read only the notes relevant to the query; do not dump whole secret folders into context.

### Create Notes
- Basic: `note notes create --title "Shopping"`
- With a body (Markdown): `note notes create --title "Shopping" --body=$'- milk\n- eggs' --folder "Ideas"`
- From a file: `note notes create --title "Meeting" --body-file ./notes.md --folder "Work"`

> **Leading-`-` gotcha:** a Markdown body that begins with `-` (a bullet) must be passed as `--body=- milk` (the `=` form) or via `--body-file`, because the argument parser treats a leading `-` as an option flag. Prefer `--body-file` for any multi-line or list body.

### Edit Notes
- Change the title: `note notes edit --id <ID> --title "New title"`
- Replace the whole body: `note notes edit --id <ID> --body-file ./updated.md` (or `--body=...`)
- `--title` and `--body` can be combined; at least one is required.

### Move Notes
- Move to another folder (created if missing): `note notes move --id <ID> --folder "Archive"`
- Apple Notes has no move verb, so this copies the note to the destination and deletes the original — **the note gets a new `id`** (the command output / `--json` reports it).

### Delete Notes
- Delete by id: `note notes delete --id <ID>`

## Folder Management

- List folders: `note folders list`
- Create a folder: `note folders create --name "Work"`
- Delete a folder by name: `note folders delete --name "Work"` (also deletes the notes inside it)

## Preferences (category-to-folder routing)

Map a free-form category (e.g. "ideas", "work", "invoice") to the Apple Notes folder a note in that category should land in, so the caller doesn't have to spell the folder each time. Persisted in `~/.config/note-sync/preferences.json` (mode `0o600`, alongside the sync config and exclude list). Preferences also **sync to D1** as the `note_preferences` entity on `note sync` — the whole map is one row (id `default`), plaintext (folder names only), last-write-wins at map granularity. The `NOTE_PREFERENCES_FOLDERS` env var is a local per-shell override and is never synced; only the file contents are.

- Map a category: `note prefs add ideas Ideas` (re-mapping updates in place)
- List mappings: `note prefs list` (`--json` for machine-readable output)
- Show the folder for one category: `note prefs get ideas` (`--json`)
- Remove a mapping: `note prefs remove ideas`
- Create a note via category: `note notes create --title "Side project X" --body-file ./idea.md --category ideas` — resolves `ideas` -> `Ideas` and creates the note there. `--folder` wins if both are given; an unknown `--category` throws a clear error rather than silently landing in the default folder.

Category keys match case-insensitively and are trimmed on lookup; folder values are used verbatim (Apple Notes folders are case-sensitive on creation). The `NOTE_PREFERENCES_FOLDERS` environment variable (`cat1:Folder1,cat2:Folder2`) layers overrides on top at read time — useful for per-shell or per-machine routing without touching the file.

**Agentic usage.** When the user says something like "save this idea" without naming a folder, infer the category from the content (an insight/idea -> `ideas`, a task for a project -> the project name, a meeting write-up -> `meetings`, etc.), check `note prefs list` to see what categories are configured, and prefer `--category` over `--folder` so the user's routing table stays the single source of truth. If the inferred category isn't mapped, ask which folder to use (and offer to `note prefs add` it for next time) rather than guessing.

## Cloud Sync

Sync notes and folders across devices through a Cloudflare D1 backend. Note **bodies are end-to-end encrypted** before they leave the device; titles and folder names stay plaintext so notes remain listable without the key.

- Run a full bidirectional sync (pull, then push): `note sync` (equivalently `note sync run`)
- Check configuration and sync state: `note sync status`
- Configure the backend connection: `note sync config --api-url <URL> --api-token <TOKEN> [--device-id <ID>]` (writes `~/.config/note-sync/config.json`; env vars take precedence when set)
- Advanced one-directional sync: `note sync push` / `note sync pull` (both accept `--type notes|folders|all`)
- Exclude sensitive folders from sync: `note sync exclude add <folder>` / `note sync exclude list` / `note sync exclude remove <folder>`

On macOS, sync bridges Apple Notes and D1. On Linux, sync bridges the local SQLite database and D1 — so on a fresh Linux machine, `note sync` (or `note sync pull`) is the first step before any data is available to the other commands.

**Excluding sensitive folders (blacklist).** To keep certain notes entirely off the cloud, blacklist their folder by name: `note sync exclude add Private`. Notes in an excluded folder (and the folder itself) are never pushed to D1; any copy already on the server is purged on the next push, while the local copy on the excluding device is always kept. Matching is case-insensitive on the folder name. The blacklist is the union of `~/.config/note-sync/exclude.json` (managed by the `exclude` subcommand) and the `NOTE_SYNC_EXCLUDE_FOLDERS` environment variable (comma- or newline-separated); `note sync status` shows the effective set. Move a note out of an excluded folder to resume syncing it; move one in to purge it from the cloud. **Set the same blacklist on every device** — purging soft-deletes the cloud copy, so a device that hasn't excluded the folder will delete its local copy on the next pull.

**What syncs.** Note bodies are end-to-end encrypted and travel as ciphertext in the sync payload; titles and folder names stay plaintext so notes remain listable without the key. Both survive a cross-device sync.

Sync requires three things on every device: the `NOTE_SYNC_API_URL` and `NOTE_SYNC_API_TOKEN` environment variables (device id defaults to the hostname), **and** the shared `NOTE_ENCRYPTION_KEY` (base64, 32 bytes). Without the encryption key, folder sync still works but note sync fails with a clear error. For one-time Worker deployment and per-device setup, see [`references/cloud-sync.md`](references/cloud-sync.md). The canonical Worker is shared with the `event` CLI: deploy it once serving all five tables (`migrations/all`) and point both CLIs at the same URL and token. The Worker source is not bundled here — `./references/fetch-worker.sh` fetches it on demand into a gitignored `references/worker/`.

**D1-direct subcommands** bypass local storage and read/write the cloud backend directly (decrypting/encrypting bodies transparently): `note sync notes list` / `note sync notes show --id <ID>` / `note sync notes create`, and `note sync folders list`. Use these to inspect or seed the cloud store without touching Apple Notes or the local SQLite DB.

## Limitations & Notes

- **Title = first line of body**: when you `show` a note, the body's first line is the title; this is how Apple Notes models notes.
- **HTML <-> Markdown fidelity**: plain text, bold/italic, bullet lists, and URLs round-trip cleanly. Headings (`#`/`##`/`###`) render as bold/larger text but are **Body** paragraphs — AppleScript `set body` cannot apply Apple Notes' native Title/Heading/Subheading styles (it normalizes any `<h*>` to Body); they still round-trip back to `#`/`##`/`###`. Links are written as `label (url)` plain text (Apple Notes strips `<a href>` on write, so a labeled hyperlink isn't possible, but the URL survives and Notes auto-links it). List items gain blank lines between them; tables and inline images are not preserved (Apple Notes' `set body` strips inline images).
- **Listing cost**: `note notes list` / `search` fetch every note body in one AppleScript call, so on large libraries they take a few seconds.
- **Folders span accounts**: if you use both iCloud and "On My Mac", a default `Notes` folder can appear once per account; `folders list` shows each.
- **Sync conflicts**: last-write-wins on the note modification timestamp. A pull never overwrites a local copy modified more recently than the server's version.
- **Encryption key custody**: `NOTE_ENCRYPTION_KEY` is never written to disk by `note`. Generate it once with `openssl rand -base64 32`, set the same value on every device, and keep a backup — lose it and encrypted bodies are unrecoverable.
- **Security**: note bodies often hold secrets (backup codes, API keys). They are encrypted in transit and at rest in D1, but are plaintext in the local store (Apple Notes or `~/.local/share/note-sync/local.db`). Avoid printing full bodies into shared logs. Bodies are encrypted but **titles and folder names are plaintext on D1** — for notes that must never leave the device at all, put them in a folder and blacklist it with `note sync exclude` (see [Cloud Sync](#cloud-sync)).

# note ![Swift](https://img.shields.io/badge/Swift-6.2+-F05138) ![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-lightgrey)

[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**English** | [简体中文](README.zh-CN.md)

A pure Swift CLI for managing Apple Notes. On macOS it reads and writes Apple
Notes directly through AppleScript; on Linux it works against a local SQLite store
kept in sync with a Cloudflare D1 backend. Note bodies are end-to-end encrypted
before they leave your device.

`note` is the notes-focused companion to [`event`](https://github.com/FradSer/event)
(Apple Reminders & Calendar) — same architecture, separate backend, designed to be
used side by side.

## Features

- Create, read, edit, move, delete, and search notes
- Organize notes into folders
- Markdown bodies (Apple Notes' HTML is converted to/from Markdown)
- End-to-end encrypted bodies — Cloudflare only ever sees ciphertext
- Markdown (default) and JSON output
- Cloud sync across devices with Cloudflare D1 via `note sync`
- Runs on macOS (AppleScript) and Linux (local SQLite + sync)

## Requirements

- Swift 6.2 or later (built with the Swift 6 language mode)
- **macOS** 14.0 or later — reads and writes Apple Notes directly via AppleScript
- **Linux** — no Apple Notes, so `note` works against a local SQLite database at
  `~/.local/share/note-sync/local.db`. Run `note sync` to populate it from
  Cloudflare D1, then use the same commands on that data.

## Installation

### Homebrew (recommended)

```bash
brew tap FradSer/brew
brew install note
```

### Build from source

```bash
git clone https://github.com/FradSer/note.git
cd note
swift build -c release
cp .build/release/note /usr/local/bin/
```

Tagged releases are built and published automatically by GitHub Actions
(`.github/workflows/release.yml`): pushing a `v*` tag cross-builds macOS
(arm64/amd64) and Linux (amd64/arm64) binaries, attaches them to the GitHub
release, and updates the Homebrew formula.

### First Run — Grant Permission (macOS)

On first run the tool asks for Automation access to Notes. If the prompt does not
appear, enable it manually:

- System Settings > Privacy & Security > Automation > your terminal > Notes

## Usage

### Notes

```bash
# List notes (optionally within a folder)
note notes list
note notes list --folder "Ideas"

# Show a single note with its body
note notes show --id <NOTE_ID>

# Create a note (body is Markdown; title becomes the first line)
note notes create --title "Shopping" --body $'- milk\n- eggs' --folder "Ideas"
note notes create --title "Meeting" --body-file ./notes.md

# Edit a note's title and/or body (--body replaces the whole body)
note notes edit --id <NOTE_ID> --title "New title"
note notes edit --id <NOTE_ID> --body-file ./updated.md

# Move a note to another folder (created if missing)
note notes move --id <NOTE_ID> --folder "Archive"

# Search notes by keyword (title + body)
note notes search --keyword "invoice"

# Delete a note
note notes delete --id <NOTE_ID>
```

> Tip: a Markdown body that begins with `-` (a bullet) must be passed as
> `--body=- milk` or via `--body-file`, because argument parsers treat a leading
> `-` as an option.

### Folders

```bash
note folders list
note folders create --name "Work"
note folders delete --name "Work"     # also deletes the folder's notes
```

### Sync (Cloudflare D1)

`note sync` keeps notes and folders in sync across devices through a Cloudflare
Worker backed by D1. Note bodies are encrypted with a key only your devices hold.

#### 1. Deploy the Worker (one-time)

```bash
cd skills/apple-notes/references/worker
pnpm install
pnpm exec wrangler login
cp wrangler.toml.example wrangler.toml      # copy the config template
pnpm exec wrangler d1 create note-sync      # copy the database_id into wrangler.toml
pnpm run db:migrate:remote                  # create the D1 tables
openssl rand -hex 32 | pnpm exec wrangler secret put API_TOKEN   # set the shared API token
pnpm run deploy                             # prints https://<worker>.workers.dev
```

#### 2. Configure each device

```bash
export NOTE_SYNC_API_URL=https://<your-worker>.workers.dev
export NOTE_SYNC_API_TOKEN=<the API_TOKEN from step 1>
# NOTE_SYNC_DEVICE_ID is optional; defaults to the machine hostname

# Generate the encryption key ONCE, then set the SAME value on every device:
openssl rand -base64 32
export NOTE_ENCRYPTION_KEY=<that base64 value>

note sync status        # verify configuration (shows whether the key is set)
```

Environment variables take precedence. If unset, `note` falls back to a config
file written by `note sync config --api-url <URL> --api-token <TOKEN>`
(`--device-id` optional). The config file at `~/.config/note-sync/config.json`
stores the API token at mode `0o600`. **The encryption key is never written to
disk by `note` — it lives only in `NOTE_ENCRYPTION_KEY`.** Lose it and encrypted
bodies are unrecoverable.

#### 3. Sync

```bash
note sync                       # full bidirectional sync (pull, then push)
note sync push                  # one-directional
note sync pull
note sync --type folders        # restrict to one entity type
```

Conflicts resolve by last-write-wins: a pull never overwrites a local copy
modified more recently than the server's version, and that copy is pushed on the
next sync.

#### Direct D1 access (advanced)

Read or write the cloud copy without a local store (e.g. from a throwaway device):

```bash
note sync notes list
note sync notes show --id <ID>
note sync folders list
```

## Architecture

```
NoteModels  ─ domain models, formatters, sync models, HTML<->Markdown converter
NoteSync    ─ D1 HTTP client, AES-GCM encryption, SQLite store, Linux sync
NoteCommands─ shared sync subcommands
note        ─ CLI: AppleScript NotesService/FolderService, macOS SyncService
skills/apple-notes/ ─ ready-to-use agent skill (SKILL.md) bundling the Worker
```

See [CLAUDE.md](CLAUDE.md) for the full architecture, sync algorithm, and known
limitations.

## License

MIT

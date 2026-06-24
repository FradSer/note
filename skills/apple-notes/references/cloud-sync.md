# Cloud Sync Setup (`note sync`)

`note sync` syncs notes and folders across devices through a Cloudflare Worker
backed by D1. Note **bodies are end-to-end encrypted** before they leave the
device — the Worker only ever stores ciphertext. This is a one-time setup;
afterward you just run `note sync`.

The Worker source is a snapshot of the canonical Worker in the `apple-sync-kit`
repo, synced into this skill at `references/worker/`. The same canonical Worker
also backs the `event` CLI — only the `ENTITIES` var and migration set differ.
This snapshot is pre-configured for `note` (`ENTITIES="notes,note_folders"`,
`migrations_dir="migrations/notes"`); a `note`-only user never needs the `event`
side. To refresh the snapshot after a canonical update, run
`./references/worker/sync-from-kit.sh`.

The local side of the sync depends on the platform: macOS bridges Apple Notes
(via AppleScript) and D1, while Linux (and other non-Apple platforms) bridges a
local SQLite database at `~/.local/share/note-sync/local.db` and D1. On Linux,
`note sync` is the first step on a fresh machine — it populates that local
database before the `note notes` / `note folders` commands have anything to show.

## 1. Deploy the Worker (one-time)

Run these from the bundled worker directory (`references/worker/`):

```bash
pnpm install
pnpm exec wrangler login
pnpm exec wrangler d1 create note-sync    # copy the database_id into wrangler.toml
pnpm run db:migrate:remote                # create the D1 tables (notes set)
openssl rand -hex 32 | pnpm exec wrangler secret put API_TOKEN   # auto-generate and set a strong shared API token
pnpm run deploy                           # prints https://<worker>.workers.dev
```

`wrangler.toml` is checked in with `ENTITIES="notes,note_folders"` and
`migrations_dir="migrations/notes"` already set; only `database_id` needs
filling in after `d1 create`.

Upgrading an existing deployment: the pull cursor is keyed on a monotonic `seq`
column added by migration `0002_notes_seq_cursor`. After pulling new changes,
re-run `pnpm run db:migrate:remote` then `pnpm run deploy`. Devices still holding
an older timestamp cursor self-heal on their next pull (they restart once and
re-converge), so no client action is needed.

## 2. Configure each device

Set the connection env vars **and** the shared encryption key — add them to
`~/.zshrc` (or `~/.bashrc`) so they persist across shells:

```bash
export NOTE_SYNC_API_URL=https://<your-worker>.workers.dev
export NOTE_SYNC_API_TOKEN=<the API_TOKEN from step 1>
# NOTE_SYNC_DEVICE_ID is optional; defaults to the machine hostname

# Generate the encryption key ONCE, then set the SAME value on every device:
openssl rand -base64 32
export NOTE_ENCRYPTION_KEY=<that base64 value>
```

Verify with `note sync status` — it should report `Config source: environment
variables` and `Encryption key (NOTE_ENCRYPTION_KEY): set`. If the connection
env vars are unset, `note` falls back to a config file written by
`note sync config --api-url <URL> --api-token <TOKEN> --device-id <ID>`. The
encryption key is **never** written to disk by `note`; it lives only in
`NOTE_ENCRYPTION_KEY`.

### Headless / systemd services

Shell profiles (`~/.bashrc`, `~/.zshrc`) only affect interactive shells. If
`note` runs inside a systemd-managed service (e.g. an agent gateway), the
service process inherits **none** of those exports. See
[Systemd Deployment](references/docs/systemd-deployment.md) for the full setup
(env file + systemd drop-in).

## 3. Sync

```bash
note sync   # full bidirectional sync: pull, then push
```

Run it on each device. The device id (hostname by default) keeps devices
distinct, and a device never pulls back its own writes. On Linux, run this first
on a new machine to populate the local SQLite database before reading data with
the other `note` commands.

## 4. Exclude sensitive folders (optional)

Some folders should never leave the device — note bodies are encrypted on D1, but
titles and folder names are stored plaintext, so a "Private" folder's note titles
would otherwise be visible server-side. Blacklist such folders by name:

```bash
note sync exclude add Private        # persists to ~/.config/note-sync/exclude.json
note sync exclude list               # show the effective blacklist
note sync exclude remove Private
note sync status                     # "Excluded folders:" lists the effective set
```

The effective blacklist is the union of `exclude.json` and the
`NOTE_SYNC_EXCLUDE_FOLDERS` environment variable (comma- or newline-separated),
matched case-insensitively. On every sync:

- notes in an excluded folder (and the folder itself) are filtered out of push, so
  they are never uploaded;
- any copy already on D1 is purged (soft-deleted) on the next push — once;
- on the device that holds the blacklist, the local copy is always kept: pulled
  items in an excluded folder are dropped before the sync engine sees them, so they
  are never re-created and the purge tombstone never deletes the local copy.

Move a note out of an excluded folder and it resumes syncing on the next push;
move one in and it is purged from the cloud.

**Set the same blacklist on every device.** Exclusion is enforced locally per
device, and purging soft-deletes the cloud copy — so any *other* device that syncs
and has not excluded the same folder will delete its local copy when it pulls the
tombstone. Keeping the blacklist identical across devices avoids surprising
deletions.

## Notes

- **End-to-end encryption**: note bodies are sealed with AES-GCM using
  `NOTE_ENCRYPTION_KEY` before push and opened on pull, so D1 only stores
  ciphertext. Titles and folder names stay plaintext so notes remain listable.
  Without the key, folder sync still works but note sync fails with a clear
  error. Keep a backup of the key — losing it makes encrypted bodies
  unrecoverable.
- The pull cursor is keyed on a monotonic per-table `seq` (assigned by the
  Worker as `MAX(seq)+1` on every write), not on a wall-clock timestamp, so a
  change can never be stranded by a cursor that sits above it.
- Conflicts resolve by last-write-wins: a pull never overwrites a local copy
  modified more recently than the server's version. When the local store
  provides no modification or creation timestamp, the local copy is left
  unchanged until the next push.
- A move creates a new note id (Apple Notes has no move verb), so a moved note
  syncs as a delete of the old id plus a create of the new one.
- A daily cron on the Worker purges records soft-deleted over 30 days ago.
- Entities: the Worker exposes `notes` and `note_folders`. Auth is a Bearer
  token (`API_TOKEN`). Endpoints live at `/api/v1/{entity}/{push|pull}` and
  `DELETE /api/v1/{entity}/{id}`.

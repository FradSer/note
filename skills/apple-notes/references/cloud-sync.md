# Cloud Sync Setup (`note sync`)

`note sync` syncs notes and folders across devices through a Cloudflare Worker
backed by D1. Note **bodies are end-to-end encrypted** before they leave the
device — the Worker only ever stores ciphertext. This is a one-time setup;
afterward you just run `note sync`.

The Worker is the canonical one in the `apple-sync-kit` repo; the same Worker
also backs the `event` CLI. The recommended setup is **one shared Worker + one
D1 serving every table** for both CLIs, pointed at the same URL and token. The
kit ships only the entity-agnostic runtime — **note owns its own table schemas
and migrations** under `references/migrations/` (`notes`, `note_folders`,
`note_preferences`). When you need to deploy, `./references/fetch-worker.sh`
pulls the Worker runtime into a gitignored `references/worker/` scratch
directory.

The local side of the sync depends on the platform: macOS bridges Apple Notes
(via AppleScript) and D1, while Linux (and other non-Apple platforms) bridges a
local SQLite database at `~/.local/share/note-sync/local.db` and D1. On Linux,
`note sync` is the first step on a fresh machine — it populates that local
database before the `note notes` / `note folders` commands have anything to show.

## 1. Deploy the Worker (one-time)

**Already running the shared Worker for `event`?** Skip this section — just set
`NOTE_SYNC_API_URL` / `NOTE_SYNC_API_TOKEN` to that Worker's URL and token in
step 2.

Otherwise fetch the canonical Worker and deploy it once for both CLIs:

```bash
./references/fetch-worker.sh              # pulls the Worker runtime into references/worker/
cd references/worker && pnpm install
pnpm exec wrangler login
pnpm exec wrangler d1 create apple-sync   # copy the database_id into wrangler.toml
cp wrangler.toml.example wrangler.toml
# In wrangler.toml set:
#   ENTITIES        = "notes,note_folders,note_preferences"
#   migrations_dir  = "../migrations"          # <- note's own schemas (references/migrations/)
#   database_id     = <from the create output>
pnpm run db:migrate:remote                # creates note's three tables
openssl rand -hex 32 | pnpm exec wrangler secret put API_TOKEN   # auto-generate and set a strong shared API token
pnpm run deploy                           # prints https://<worker>.workers.dev
```

The `migrations_dir` points at note's `references/migrations/` (relative to the
`references/worker/` scratch dir, that's `../migrations`). The kit no longer
ships business migrations — note owns all three of its tables.

**Shared note + event D1.** If `event` also uses this Worker, merge event's
migrations into the same `migrations_dir` (namespaced filenames like
`0001_note_*`, `0001_event_*` avoid collisions in D1's `d1_migrations` table)
and add event's entities to `ENTITIES`. See the kit Worker's `README.md` for the
merge convention; the `event` repo documents its own migration set.

Upgrading an existing deployment: after pulling new changes, re-run
`pnpm run db:migrate:remote` then `pnpm run deploy`. New migration files (e.g.
`0003_note_preferences_*`) create their tables; existing `0001`/`0002` files are
`CREATE TABLE IF NOT EXISTS` / `ALTER ADD COLUMN`-safe, so re-applying them is a
no-op against already-migrated tables. Devices still holding an older timestamp
cursor self-heal on their next pull (they restart once and re-converge), so no
client action is needed for the cursor column.

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

When sharing one Worker with `event`, `NOTE_SYNC_API_URL` / `EVENT_SYNC_API_URL`
point at the same URL and `NOTE_SYNC_API_TOKEN` / `EVENT_SYNC_API_TOKEN` hold the
same token. The encryption keys stay independent — `NOTE_ENCRYPTION_KEY` is
note-specific and the Worker only ever stores ciphertext.

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
- Entities: the Worker exposes `notes`, `note_folders`, and `note_preferences`.
  Auth is a Bearer token (`API_TOKEN`). Endpoints live at
  `/api/v1/{entity}/{push|pull}` and `DELETE /api/v1/{entity}/{id}`.

## Preferences sync

`note prefs` (category→folder routing, e.g. `ideas`->`Ideas`) also syncs. The
whole mapping is stored as a single D1 row (`id = "default"`) in
`note_preferences` and round-trips through `note sync` like any other entity.
Plaintext — it holds only folder names, the same sensitivity as `note_folders`.

- **Whole-map last-write-wins.** The entire `folders` map is replaced on each
  push. If two devices each add a different category concurrently, the later
  push wins and the other device's category is dropped on its next pull.
  Preferences are tiny and rarely edited on two devices at once, so this is
  accepted; if you edit on one device at a time you will never hit it.
- **Env overrides do not sync.** `NOTE_PREFERENCES_FOLDERS` is a per-shell
  override read only by the local `note prefs` commands; only the
  `preferences.json` file contents are pushed/pulled.
- **Local-newer check uses file mtime.** A local `prefs add` bumps the file's
  modification time, so a subsequent pull skips a remote row that is older than
  your local edit (and your edit is pushed on the next sync). Because the file
  mtime has sub-second resolution while the server timestamp is second-granularity,
  a no-op pull may report `Preferences: skipped 1` — harmless (the data matches
  and the cursor still advances).

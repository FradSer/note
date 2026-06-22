# Cloud Sync Setup (`note sync`)

`note sync` syncs notes and folders across devices through a Cloudflare Worker
backed by D1. Note **bodies are end-to-end encrypted** before they leave the
device — the Worker only ever stores ciphertext. This is a one-time setup;
afterward you just run `note sync`.

The Worker source is bundled with this skill at `references/worker/`.

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
cp wrangler.toml.example wrangler.toml    # copy the config template
pnpm exec wrangler d1 create note-sync    # copy the database_id into wrangler.toml
pnpm run db:migrate:remote                # create the D1 tables
openssl rand -hex 32 | pnpm exec wrangler secret put API_TOKEN   # auto-generate and set a strong shared API token
pnpm run deploy                           # prints https://<worker>.workers.dev
```

Upgrading an existing deployment: the pull cursor is keyed on a monotonic `seq`
column added by migration `0002_seq_cursor`. After pulling new changes, re-run
`pnpm run db:migrate:remote` then `pnpm run deploy`. Devices still holding an
older timestamp cursor self-heal on their next pull (they restart once and
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

## 3. Sync

```bash
note sync   # full bidirectional sync: pull, then push
```

Run it on each device. The device id (hostname by default) keeps devices
distinct, and a device never pulls back its own writes. On Linux, run this first
on a new machine to populate the local SQLite database before reading data with
the other `note` commands.

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

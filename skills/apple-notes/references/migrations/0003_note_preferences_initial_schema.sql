-- Migration 0003: note_preferences table.
--
-- Stores the user's category-to-folder routing preferences as a single row
-- (id = "default", data = {"folders": {...}}). Synced plaintext (folder names
-- only, same sensitivity as note_folders). Whole-map last-write-wins: the
-- entire folders map is replaced on each push.
CREATE TABLE IF NOT EXISTS note_preferences (
    id TEXT PRIMARY KEY,
    data TEXT NOT NULL,
    last_modified TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    source_device TEXT
);

CREATE INDEX IF NOT EXISTS idx_note_preferences_updated ON note_preferences (updated_at, id);

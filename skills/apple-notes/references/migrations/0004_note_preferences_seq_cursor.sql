-- Migration 0004: monotonic pull cursor for note_preferences.
-- Same rationale as 0002: a strictly increasing per-table `seq` so a stored
-- cursor can never sit above a future write.

ALTER TABLE note_preferences ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;
UPDATE note_preferences SET seq = rowid;

CREATE INDEX IF NOT EXISTS idx_note_preferences_seq ON note_preferences (seq, id);

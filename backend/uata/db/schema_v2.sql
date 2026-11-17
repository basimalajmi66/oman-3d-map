-- Schema version 2: chart images submitted for analysis (upload / share / screenshot).
-- Kept separate from the knowledge library: these are inputs to analyse, not knowledge to learn.

CREATE TABLE IF NOT EXISTS analysis_inputs (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id     INTEGER REFERENCES analysis_sessions(id) ON DELETE SET NULL,
    input_mode     TEXT NOT NULL CHECK (input_mode IN ('upload','share','screenshot','screen_region')),
    original_name  TEXT,
    sha256         TEXT NOT NULL,
    stored_path    TEXT NOT NULL,          -- relative to files/
    width          INTEGER NOT NULL CHECK (width > 0),
    height         INTEGER NOT NULL CHECK (height > 0),
    size_bytes     INTEGER NOT NULL,
    signal_id      INTEGER REFERENCES signals(id) ON DELETE SET NULL,  -- filled by the signal engine (Phase 8)
    created_at     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_inputs_created ON analysis_inputs(created_at);

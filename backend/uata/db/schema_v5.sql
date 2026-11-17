-- Schema version 5 (Phase 6): analysis of educational videos.
CREATE TABLE IF NOT EXISTS video_analyses (
    source_id          INTEGER PRIMARY KEY REFERENCES knowledge_sources(id) ON DELETE CASCADE,
    status             TEXT NOT NULL CHECK (status IN ('queued','processing','done','failed')),
    progress           REAL NOT NULL DEFAULT 0,
    error              TEXT,
    subtitles_text     TEXT,                 -- user-provided SRT/VTT (exact timestamps)
    transcript_source  TEXT,                 -- subtitles | speech_to_text | none
    analysis_json      TEXT,                 -- timeline, charts, rules, summary, strategy, warnings
    strategy_id        INTEGER REFERENCES strategies(id) ON DELETE SET NULL,
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL
);

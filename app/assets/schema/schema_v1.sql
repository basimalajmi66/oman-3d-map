-- Universal AI Trading Assistant — local database, schema version 1.
-- Everything is stored on the device. See docs/DATABASE.md for the rationale of each table.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------- settings
CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value_json  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

-- ---------------------------------------------------------------- knowledge
-- A *source* is something the user gave the system: a note, a file, a link, a video.
CREATE TABLE IF NOT EXISTS knowledge_sources (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    kind           TEXT NOT NULL CHECK (kind IN ('note','pdf','docx','xlsx','txt','image','video','url','other')),
    title          TEXT NOT NULL,
    original_name  TEXT,
    mime_type      TEXT,
    sha256         TEXT,
    stored_path    TEXT,              -- relative to the data dir's files/ folder
    url            TEXT,
    size_bytes     INTEGER,
    category       TEXT,
    tags_json      TEXT NOT NULL DEFAULT '[]',
    notes          TEXT,
    extraction_status TEXT NOT NULL DEFAULT 'pending'
                   CHECK (extraction_status IN ('pending','done','unsupported_yet','failed')),
    extracted_text TEXT,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_sources_sha256 ON knowledge_sources(sha256) WHERE sha256 IS NOT NULL;

-- A *knowledge item* is one piece of knowledge (rule, note, strategy fragment, example)
-- derived from a source. Items are never used by the analysis engine until approved.
CREATE TABLE IF NOT EXISTS knowledge_items (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id          INTEGER REFERENCES knowledge_sources(id) ON DELETE CASCADE,
    item_type          TEXT NOT NULL CHECK (item_type IN ('note','rule','strategy_fragment','example','definition')),
    title              TEXT NOT NULL,
    content            TEXT NOT NULL,
    category           TEXT,
    tags_json          TEXT NOT NULL DEFAULT '[]',
    status             TEXT NOT NULL DEFAULT 'pending_review'
                       CHECK (status IN ('pending_review','approved','rejected','archived')),
    video_timestamp_ms INTEGER,         -- exact position inside a video source, when applicable
    clarity            REAL CHECK (clarity IS NULL OR (clarity >= 0 AND clarity <= 1)),
    created_at         TEXT NOT NULL,
    updated_at         TEXT NOT NULL,
    decided_at         TEXT
);
CREATE INDEX IF NOT EXISTS ix_items_status ON knowledge_items(status);
CREATE INDEX IF NOT EXISTS ix_items_source ON knowledge_items(source_id);

-- Full-text index over items (external-content FTS5 table kept in sync by triggers).
CREATE VIRTUAL TABLE IF NOT EXISTS knowledge_items_fts USING fts5(
    title, content, category, content='knowledge_items', content_rowid='id', tokenize='unicode61'
);
CREATE TRIGGER IF NOT EXISTS trg_items_ai AFTER INSERT ON knowledge_items BEGIN
    INSERT INTO knowledge_items_fts(rowid, title, content, category)
    VALUES (new.id, new.title, new.content, coalesce(new.category,''));
END;
CREATE TRIGGER IF NOT EXISTS trg_items_ad AFTER DELETE ON knowledge_items BEGIN
    INSERT INTO knowledge_items_fts(knowledge_items_fts, rowid, title, content, category)
    VALUES ('delete', old.id, old.title, old.content, coalesce(old.category,''));
END;
CREATE TRIGGER IF NOT EXISTS trg_items_au AFTER UPDATE ON knowledge_items BEGIN
    INSERT INTO knowledge_items_fts(knowledge_items_fts, rowid, title, content, category)
    VALUES ('delete', old.id, old.title, old.content, coalesce(old.category,''));
    INSERT INTO knowledge_items_fts(rowid, title, content, category)
    VALUES (new.id, new.title, new.content, coalesce(new.category,''));
END;

CREATE TABLE IF NOT EXISTS knowledge_links (
    from_item_id  INTEGER NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
    to_item_id    INTEGER NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
    relation      TEXT NOT NULL CHECK (relation IN ('related','supports','contradicts','refines','example_of')),
    created_at    TEXT NOT NULL,
    PRIMARY KEY (from_item_id, to_item_id, relation),
    CHECK (from_item_id <> to_item_id)
);

-- Embeddings for local vector search (filled from Phase 5). Stored as float32 BLOBs.
CREATE TABLE IF NOT EXISTS knowledge_embeddings (
    item_id     INTEGER PRIMARY KEY REFERENCES knowledge_items(id) ON DELETE CASCADE,
    model       TEXT NOT NULL,
    dim         INTEGER NOT NULL,
    vector      BLOB NOT NULL,
    created_at  TEXT NOT NULL
);

-- What the system learned from a source, shown to the user for approval.
CREATE TABLE IF NOT EXISTS learning_reports (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id       INTEGER REFERENCES knowledge_sources(id) ON DELETE CASCADE,
    summary         TEXT NOT NULL,
    extracted_json  TEXT NOT NULL DEFAULT '{}',
    conflicts_json  TEXT NOT NULL DEFAULT '[]',
    status          TEXT NOT NULL DEFAULT 'pending_review'
                    CHECK (status IN ('pending_review','approved','rejected')),
    created_at      TEXT NOT NULL,
    decided_at      TEXT
);

-- ---------------------------------------------------------------- strategies
CREATE TABLE IF NOT EXISTS strategies (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    name                    TEXT NOT NULL UNIQUE,
    description             TEXT NOT NULL DEFAULT '',
    source_id               INTEGER REFERENCES knowledge_sources(id) ON DELETE SET NULL,
    entry_conditions_json   TEXT NOT NULL DEFAULT '[]',
    exit_conditions_json    TEXT NOT NULL DEFAULT '[]',
    no_entry_conditions_json TEXT NOT NULL DEFAULT '[]',
    timeframes_json         TEXT NOT NULL DEFAULT '[]',
    market_conditions_json  TEXT NOT NULL DEFAULT '[]',
    indicators_json         TEXT NOT NULL DEFAULT '[]',
    status                  TEXT NOT NULL DEFAULT 'draft'
                            CHECK (status IN ('draft','testing','approved','retired')),
    version                 INTEGER NOT NULL DEFAULT 1,
    created_at              TEXT NOT NULL,
    updated_at              TEXT NOT NULL,
    approved_at             TEXT
);

CREATE TABLE IF NOT EXISTS strategy_examples (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    strategy_id      INTEGER NOT NULL REFERENCES strategies(id) ON DELETE CASCADE,
    outcome          TEXT NOT NULL CHECK (outcome IN ('success','failure')),
    description      TEXT NOT NULL,
    image_source_id  INTEGER REFERENCES knowledge_sources(id) ON DELETE SET NULL,
    created_at       TEXT NOT NULL
);

-- Backtests are always tied to exactly one strategy so results never get mixed.
CREATE TABLE IF NOT EXISTS backtest_runs (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    strategy_id         INTEGER NOT NULL REFERENCES strategies(id) ON DELETE CASCADE,
    strategy_version    INTEGER NOT NULL,
    dataset             TEXT NOT NULL,
    params_json         TEXT NOT NULL DEFAULT '{}',
    in_sample_from      TEXT, in_sample_to  TEXT,
    out_sample_from     TEXT, out_sample_to TEXT,
    costs_json          TEXT NOT NULL DEFAULT '{}',
    metrics_json        TEXT NOT NULL DEFAULT '{}',
    created_at          TEXT NOT NULL
);

-- ---------------------------------------------------------------- live analysis
CREATE TABLE IF NOT EXISTS analysis_sessions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    input_mode   TEXT NOT NULL CHECK (input_mode IN ('upload','screenshot','screen_region','continuous_screen','price_feed')),
    asset        TEXT,
    timeframe_sec INTEGER NOT NULL,
    status       TEXT NOT NULL CHECK (status IN ('running','stopped')),
    stop_reason  TEXT,
    started_at   TEXT NOT NULL,
    stopped_at   TEXT
);

CREATE TABLE IF NOT EXISTS signals (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id            INTEGER REFERENCES analysis_sessions(id) ON DELETE SET NULL,
    created_at            TEXT NOT NULL,
    asset                 TEXT,
    timeframe_sec         INTEGER NOT NULL,
    signal                TEXT NOT NULL CHECK (signal IN ('BUY','SELL','WAIT')),
    confidence_score      REAL CHECK (confidence_score IS NULL OR (confidence_score >= 0 AND confidence_score <= 1)),
    confidence_calibrated INTEGER NOT NULL DEFAULT 0,   -- 1 only when backed by out-of-sample calibration
    duration_sec          INTEGER,
    strategy_id           INTEGER REFERENCES strategies(id) ON DELETE SET NULL,
    reasons_json          TEXT NOT NULL DEFAULT '[]',
    supporting_json       TEXT NOT NULL DEFAULT '[]',
    opposing_json         TEXT NOT NULL DEFAULT '[]',
    data_quality          REAL CHECK (data_quality IS NULL OR (data_quality >= 0 AND data_quality <= 1)),
    data_basis            TEXT NOT NULL CHECK (data_basis IN ('image_only','price_feed','image_and_feed')),
    engine_version        TEXT NOT NULL,
    CHECK (signal = 'WAIT' OR duration_sec IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_signals_created ON signals(created_at);

-- ---------------------------------------------------------------- results
CREATE TABLE IF NOT EXISTS trade_results (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    signal_id     INTEGER REFERENCES signals(id) ON DELETE SET NULL,
    account_type  TEXT NOT NULL CHECK (account_type IN ('simulation','demo','real')),
    asset         TEXT NOT NULL,
    timeframe_sec INTEGER NOT NULL,
    strategy_id   INTEGER REFERENCES strategies(id) ON DELETE SET NULL,
    signal_type   TEXT NOT NULL CHECK (signal_type IN ('BUY','SELL')),
    signal_time   TEXT NOT NULL,
    duration_sec  INTEGER NOT NULL,
    outcome       TEXT NOT NULL CHECK (outcome IN ('win','loss','draw','cancelled')),
    pnl           REAL,
    market_condition TEXT,
    notes         TEXT,
    created_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_results_account ON trade_results(account_type);

-- ---------------------------------------------------------------- audit / learning log
CREATE TABLE IF NOT EXISTS audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    at          TEXT NOT NULL,
    actor       TEXT NOT NULL CHECK (actor IN ('user','system')),
    action      TEXT NOT NULL,
    detail_json TEXT NOT NULL DEFAULT '{}'
);

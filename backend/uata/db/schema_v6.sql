-- Schema version 6 (Phase 7): historical datasets, testable strategy definitions, backtest links.
CREATE TABLE IF NOT EXISTS datasets (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT NOT NULL,
    asset          TEXT,
    timeframe_sec  INTEGER NOT NULL,
    rows           INTEGER NOT NULL,
    first_time     REAL, last_time REAL,
    has_volume     INTEGER NOT NULL DEFAULT 0,
    is_synthetic   INTEGER NOT NULL DEFAULT 0,      -- synthetic data can never qualify a strategy
    stored_path    TEXT NOT NULL,                   -- normalised CSV under files/datasets/
    created_at     TEXT NOT NULL
);
ALTER TABLE strategies ADD COLUMN definition_json TEXT;   -- testable conditions (see uata/strategy/conditions.py)
ALTER TABLE backtest_runs ADD COLUMN dataset_id INTEGER REFERENCES datasets(id) ON DELETE SET NULL;
ALTER TABLE backtest_runs ADD COLUMN qualifies INTEGER NOT NULL DEFAULT 0;
ALTER TABLE backtest_runs ADD COLUMN gate_reasons_json TEXT NOT NULL DEFAULT '[]';

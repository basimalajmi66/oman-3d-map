-- Schema version 7 (Phase 9): context needed to analyse results.
ALTER TABLE signals ADD COLUMN market_condition TEXT;          -- trending | ranging | volatile at signal time
ALTER TABLE trade_results ADD COLUMN confidence REAL;          -- copied from the signal (for calibration evidence)
ALTER TABLE trade_results ADD COLUMN data_quality REAL;        -- copied from the signal
CREATE INDEX IF NOT EXISTS ix_results_strategy ON trade_results(strategy_id);

-- Schema version 4 (Phase 5): where each piece of knowledge came from inside its source,
-- and the structured form of extracted rules.
ALTER TABLE knowledge_items ADD COLUMN location TEXT;      -- "p.3", "¶4-9", "Sheet1!r2-r40", "ocr"
ALTER TABLE knowledge_items ADD COLUMN rule_json TEXT;     -- {"actions":[...],"conditions":[...],"timeframes":[...]}
CREATE INDEX IF NOT EXISTS ix_reports_status ON learning_reports(status);

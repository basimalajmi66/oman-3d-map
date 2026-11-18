-- Schema version 3: store the chart reading (Phase 3) with each analysed image.
ALTER TABLE analysis_inputs ADD COLUMN reading_json TEXT;
ALTER TABLE analysis_inputs ADD COLUMN data_quality REAL;
ALTER TABLE analysis_inputs ADD COLUMN usable INTEGER;

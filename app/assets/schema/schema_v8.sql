-- Schema version 8: companion devices paired over the local network (opt-in).
-- Only a SHA-256 hash of each device token is stored; revoking a device is immediate.
CREATE TABLE IF NOT EXISTS companion_devices (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL,
    token_hash   TEXT NOT NULL UNIQUE,
    created_at   TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at   TEXT
);

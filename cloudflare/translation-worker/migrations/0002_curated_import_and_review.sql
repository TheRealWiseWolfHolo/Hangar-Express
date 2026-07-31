PRAGMA foreign_keys = ON;

ALTER TABLE translation_entries
    ADD COLUMN origin TEXT NOT NULL DEFAULT 'runtime'
    CHECK (origin IN ('runtime', 'curated', 'human'));

ALTER TABLE translation_entries
    ADD COLUMN source_dictionary_version INTEGER;

ALTER TABLE translation_entries
    ADD COLUMN source_dictionary_generated_at TEXT;

ALTER TABLE translation_entries
    ADD COLUMN updated_at TEXT;

ALTER TABLE translation_entries
    ADD COLUMN deferred_until TEXT;

CREATE INDEX translation_entries_deferred_review
    ON translation_entries(locale, status, deferred_until, first_seen_at);

CREATE TABLE curated_imports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    locale TEXT NOT NULL,
    dictionary_version INTEGER NOT NULL,
    generated_at TEXT,
    checksum TEXT NOT NULL,
    entry_count INTEGER NOT NULL,
    imported_at TEXT NOT NULL,
    UNIQUE(locale, dictionary_version, checksum)
);

CREATE TABLE dictionary_state (
    locale TEXT PRIMARY KEY,
    is_dirty INTEGER NOT NULL DEFAULT 0 CHECK (is_dirty IN (0, 1)),
    changed_at TEXT,
    changed_by TEXT
);

INSERT OR IGNORE INTO dictionary_state (locale, is_dirty)
VALUES ('zh-Hans', 0);

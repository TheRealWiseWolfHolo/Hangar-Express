PRAGMA foreign_keys = ON;

CREATE TABLE translation_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    locale TEXT NOT NULL,
    normalized_source TEXT NOT NULL,
    source_hash TEXT NOT NULL,
    source TEXT NOT NULL,
    kind TEXT NOT NULL,
    machine_translation TEXT,
    approved_translation TEXT,
    status TEXT NOT NULL
        CHECK (status IN ('generating', 'pending', 'approved', 'edited', 'rejected', 'failed')),
    model TEXT,
    model_version TEXT,
    prompt_version INTEGER NOT NULL DEFAULT 1,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    seen_count INTEGER NOT NULL DEFAULT 1,
    approved_at TEXT,
    approved_by TEXT,
    failure_reason TEXT,
    retry_after TEXT,
    UNIQUE(locale, normalized_source)
);

CREATE UNIQUE INDEX translation_entries_locale_hash
    ON translation_entries(locale, source_hash);

CREATE INDEX translation_entries_review_queue
    ON translation_entries(locale, status, first_seen_at);

CREATE INDEX translation_entries_kind
    ON translation_entries(locale, kind);

CREATE TABLE translation_aliases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    translation_entry_id INTEGER NOT NULL
        REFERENCES translation_entries(id) ON DELETE CASCADE,
    alias TEXT NOT NULL,
    normalized_alias TEXT NOT NULL,
    UNIQUE(translation_entry_id, normalized_alias)
);

CREATE TABLE translation_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    translation_entry_id INTEGER NOT NULL
        REFERENCES translation_entries(id) ON DELETE CASCADE,
    previous_status TEXT,
    new_status TEXT NOT NULL,
    previous_translation TEXT,
    new_translation TEXT,
    actor TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE dictionary_releases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    locale TEXT NOT NULL,
    version INTEGER NOT NULL,
    object_key TEXT NOT NULL,
    checksum TEXT NOT NULL,
    entry_count INTEGER NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('staged', 'current', 'superseded', 'failed')),
    created_at TEXT NOT NULL,
    published_at TEXT,
    UNIQUE(locale, version),
    UNIQUE(object_key)
);

CREATE UNIQUE INDEX dictionary_releases_current_locale
    ON dictionary_releases(locale)
    WHERE status = 'current';

CREATE TABLE daily_usage (
    usage_date TEXT PRIMARY KEY,
    ai_requests INTEGER NOT NULL DEFAULT 0,
    ai_characters INTEGER NOT NULL DEFAULT 0,
    ai_failures INTEGER NOT NULL DEFAULT 0,
    cache_hits INTEGER NOT NULL DEFAULT 0
);

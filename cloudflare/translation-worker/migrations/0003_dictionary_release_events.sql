PRAGMA foreign_keys = ON;

CREATE TABLE dictionary_release_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    locale TEXT NOT NULL,
    release_id INTEGER
        REFERENCES dictionary_releases(id) ON DELETE SET NULL,
    event TEXT NOT NULL
        CHECK (event IN ('staged', 'published', 'failed', 'rollback')),
    actor TEXT NOT NULL,
    detail TEXT,
    created_at TEXT NOT NULL
);

CREATE INDEX dictionary_release_events_locale_created
    ON dictionary_release_events(locale, created_at DESC, id DESC);

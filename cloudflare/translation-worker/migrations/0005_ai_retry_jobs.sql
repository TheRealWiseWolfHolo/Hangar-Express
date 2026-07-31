PRAGMA foreign_keys = ON;

CREATE TABLE ai_retry_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    locale TEXT NOT NULL,
    requested_by TEXT NOT NULL,
    total_entries INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

ALTER TABLE translation_entries
    ADD COLUMN retry_job_id INTEGER
        REFERENCES ai_retry_jobs(id) ON DELETE SET NULL;

CREATE INDEX translation_entries_ai_retry_queue
    ON translation_entries(locale, retry_job_id, status, retry_after, id);

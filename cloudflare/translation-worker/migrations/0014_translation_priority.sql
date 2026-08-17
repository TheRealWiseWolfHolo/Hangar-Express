PRAGMA foreign_keys = ON;

ALTER TABLE translation_entries
    ADD COLUMN priority TEXT NOT NULL DEFAULT 'high'
        CHECK (priority IN ('high', 'low'));

ALTER TABLE translation_entries
    ADD COLUMN priority_updated_at TEXT;

ALTER TABLE translation_entries
    ADD COLUMN priority_updated_by TEXT;

CREATE INDEX translation_entries_review_priority_queue
    ON translation_entries(locale, priority, status, id DESC);

DROP INDEX translation_entries_retry_failed_ready;

CREATE INDEX translation_entries_retry_failed_ready
    ON translation_entries(locale, priority, retry_after, id)
    WHERE retry_job_id IS NOT NULL
      AND status = 'failed';

DROP INDEX translation_entries_retry_generating_stale;

CREATE INDEX translation_entries_retry_generating_stale
    ON translation_entries(locale, priority, updated_at, id)
    WHERE retry_job_id IS NOT NULL
      AND status = 'generating';

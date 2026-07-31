PRAGMA foreign_keys = ON;

CREATE INDEX translation_entries_retry_failed_ready
    ON translation_entries(locale, retry_after, id)
    WHERE retry_job_id IS NOT NULL
      AND status = 'failed';

CREATE INDEX translation_entries_retry_generating_stale
    ON translation_entries(locale, updated_at, id)
    WHERE retry_job_id IS NOT NULL
      AND status = 'generating';

UPDATE translation_entries
SET status = 'failed',
    failure_reason = 'Retry lease recovered after claim acknowledgement bug.',
    retry_after = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE retry_job_id IS NOT NULL
  AND status = 'generating';

UPDATE ai_retry_jobs
SET remaining_entries = (
        SELECT COUNT(*)
        FROM translation_entries
        WHERE translation_entries.retry_job_id = ai_retry_jobs.id
          AND translation_entries.status IN ('failed', 'generating')
    ),
    processing_entries = (
        SELECT COUNT(*)
        FROM translation_entries
        WHERE translation_entries.retry_job_id = ai_retry_jobs.id
          AND translation_entries.status = 'generating'
    ),
    completed_entries = MAX(
        total_entries - (
            SELECT COUNT(*)
            FROM translation_entries
            WHERE translation_entries.retry_job_id = ai_retry_jobs.id
              AND translation_entries.status IN ('failed', 'generating')
        ),
        0
    );

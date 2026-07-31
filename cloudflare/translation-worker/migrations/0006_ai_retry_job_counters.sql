PRAGMA foreign_keys = ON;

ALTER TABLE ai_retry_jobs
    ADD COLUMN remaining_entries INTEGER NOT NULL DEFAULT 0;

ALTER TABLE ai_retry_jobs
    ADD COLUMN processing_entries INTEGER NOT NULL DEFAULT 0;

ALTER TABLE ai_retry_jobs
    ADD COLUMN completed_entries INTEGER NOT NULL DEFAULT 0;

UPDATE ai_retry_jobs
SET processing_entries = (
    SELECT COUNT(*)
    FROM translation_entries
    WHERE translation_entries.retry_job_id = ai_retry_jobs.id
      AND translation_entries.status = 'generating'
);

UPDATE ai_retry_jobs
SET remaining_entries = (
    SELECT COUNT(*)
    FROM translation_entries
    WHERE translation_entries.retry_job_id = ai_retry_jobs.id
      AND translation_entries.status IN ('failed', 'generating')
);

UPDATE ai_retry_jobs
SET completed_entries = MAX(total_entries - remaining_entries, 0);

CREATE TRIGGER ai_retry_job_started
AFTER UPDATE OF status ON translation_entries
WHEN OLD.status = 'failed'
 AND NEW.status = 'generating'
 AND NEW.retry_job_id IS NOT NULL
BEGIN
    UPDATE ai_retry_jobs
    SET processing_entries = processing_entries + 1
    WHERE id = NEW.retry_job_id;
END;

CREATE TRIGGER ai_retry_job_completed
AFTER UPDATE OF status ON translation_entries
WHEN OLD.status = 'generating'
 AND NEW.status IN ('pending', 'approved', 'edited')
 AND OLD.retry_job_id IS NOT NULL
BEGIN
    UPDATE ai_retry_jobs
    SET remaining_entries = MAX(remaining_entries - 1, 0),
        processing_entries = MAX(processing_entries - 1, 0),
        completed_entries = completed_entries + 1
    WHERE id = OLD.retry_job_id;
END;

CREATE TRIGGER ai_retry_job_failed
AFTER UPDATE OF status ON translation_entries
WHEN OLD.status = 'generating'
 AND NEW.status = 'failed'
 AND OLD.retry_job_id IS NOT NULL
BEGIN
    UPDATE ai_retry_jobs
    SET processing_entries = MAX(processing_entries - 1, 0)
    WHERE id = OLD.retry_job_id;
END;

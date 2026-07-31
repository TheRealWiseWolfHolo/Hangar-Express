CREATE INDEX ai_retry_jobs_latest
    ON ai_retry_jobs(locale, id DESC);

PRAGMA optimize;

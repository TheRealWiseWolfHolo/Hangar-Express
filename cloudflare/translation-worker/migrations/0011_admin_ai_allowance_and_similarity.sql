PRAGMA foreign_keys = ON;

CREATE TABLE ai_limit_resets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    usage_date TEXT NOT NULL,
    previous_ai_requests INTEGER NOT NULL,
    previous_ai_characters INTEGER NOT NULL,
    previous_ai_failures INTEGER NOT NULL,
    resumed_entries INTEGER NOT NULL,
    actor TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX ai_limit_resets_usage_date
    ON ai_limit_resets(usage_date, id DESC);

CREATE INDEX translation_entries_budget_deferred
    ON translation_entries(locale, failure_reason, retry_after, id)
    WHERE status = 'failed';

CREATE INDEX translation_entries_approved_kind_recent
    ON translation_entries(locale, kind, approved_at DESC, id DESC)
    WHERE status IN ('approved', 'edited')
      AND approved_translation IS NOT NULL;

CREATE VIRTUAL TABLE approved_translation_search USING fts5(
    entry_id UNINDEXED,
    normalized_source,
    source UNINDEXED,
    approved_translation UNINDEXED,
    kind UNINDEXED,
    tokenize = 'unicode61 remove_diacritics 2'
);

INSERT INTO approved_translation_search (
    entry_id,
    normalized_source,
    source,
    approved_translation,
    kind
)
SELECT
    id,
    normalized_source,
    source,
    approved_translation,
    kind
FROM translation_entries
WHERE status IN ('approved', 'edited')
  AND approved_translation IS NOT NULL;

CREATE TRIGGER approved_translation_search_insert
AFTER INSERT ON translation_entries
WHEN NEW.status IN ('approved', 'edited')
 AND NEW.approved_translation IS NOT NULL
BEGIN
    INSERT INTO approved_translation_search (
        entry_id,
        normalized_source,
        source,
        approved_translation,
        kind
    ) VALUES (
        NEW.id,
        NEW.normalized_source,
        NEW.source,
        NEW.approved_translation,
        NEW.kind
    );
END;

CREATE TRIGGER approved_translation_search_delete
AFTER DELETE ON translation_entries
BEGIN
    DELETE FROM approved_translation_search
    WHERE entry_id = OLD.id;
END;

CREATE TRIGGER approved_translation_search_update
AFTER UPDATE OF normalized_source, source, approved_translation, kind, status
ON translation_entries
BEGIN
    DELETE FROM approved_translation_search
    WHERE entry_id = OLD.id;

    INSERT INTO approved_translation_search (
        entry_id,
        normalized_source,
        source,
        approved_translation,
        kind
    )
    SELECT
        NEW.id,
        NEW.normalized_source,
        NEW.source,
        NEW.approved_translation,
        NEW.kind
    WHERE NEW.status IN ('approved', 'edited')
      AND NEW.approved_translation IS NOT NULL;
END;

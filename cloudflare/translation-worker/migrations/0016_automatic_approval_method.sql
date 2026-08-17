PRAGMA foreign_keys = ON;

ALTER TABLE translation_entries
    ADD COLUMN approval_method TEXT
        CHECK (approval_method IN ('automatic', 'human'));

CREATE INDEX translation_entries_automatic_approval_queue
    ON translation_entries(locale, status, id DESC)
    WHERE approval_method = 'automatic';

PRAGMA foreign_keys = ON;

ALTER TABLE dictionary_releases
    ADD COLUMN note TEXT;

CREATE INDEX translation_revisions_entry_created
    ON translation_revisions(translation_entry_id, created_at DESC, id DESC);

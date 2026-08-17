PRAGMA foreign_keys = ON;

ALTER TABLE translation_entries
    ADD COLUMN auto_approval_checked_at TEXT;

CREATE INDEX translation_entries_pending_automatic_approval
    ON translation_entries(locale, priority, id)
    WHERE status = 'pending'
      AND kind = 'upgrade'
      AND auto_approval_checked_at IS NULL;

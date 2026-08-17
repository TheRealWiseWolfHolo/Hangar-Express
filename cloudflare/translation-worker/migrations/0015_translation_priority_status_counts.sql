PRAGMA foreign_keys = ON;

CREATE TABLE translation_priority_status_counts (
    locale TEXT NOT NULL,
    priority TEXT NOT NULL CHECK (priority IN ('high', 'low')),
    status TEXT NOT NULL,
    entry_count INTEGER NOT NULL DEFAULT 0 CHECK (entry_count >= 0),
    PRIMARY KEY (locale, priority, status)
) WITHOUT ROWID;

INSERT INTO translation_priority_status_counts (
    locale, priority, status, entry_count
)
SELECT locale, priority, status, COUNT(*)
FROM translation_entries
GROUP BY locale, priority, status;

CREATE TRIGGER translation_priority_status_insert
AFTER INSERT ON translation_entries
BEGIN
    INSERT INTO translation_priority_status_counts (
        locale, priority, status, entry_count
    ) VALUES (NEW.locale, NEW.priority, NEW.status, 1)
    ON CONFLICT(locale, priority, status)
    DO UPDATE SET entry_count = entry_count + 1;
END;

CREATE TRIGGER translation_priority_status_delete
AFTER DELETE ON translation_entries
BEGIN
    UPDATE translation_priority_status_counts
    SET entry_count = MAX(entry_count - 1, 0)
    WHERE locale = OLD.locale
      AND priority = OLD.priority
      AND status = OLD.status;
END;

CREATE TRIGGER translation_priority_status_update
AFTER UPDATE OF locale, priority, status ON translation_entries
WHEN OLD.locale != NEW.locale
  OR OLD.priority != NEW.priority
  OR OLD.status != NEW.status
BEGIN
    UPDATE translation_priority_status_counts
    SET entry_count = MAX(entry_count - 1, 0)
    WHERE locale = OLD.locale
      AND priority = OLD.priority
      AND status = OLD.status;

    INSERT INTO translation_priority_status_counts (
        locale, priority, status, entry_count
    ) VALUES (NEW.locale, NEW.priority, NEW.status, 1)
    ON CONFLICT(locale, priority, status)
    DO UPDATE SET entry_count = entry_count + 1;
END;

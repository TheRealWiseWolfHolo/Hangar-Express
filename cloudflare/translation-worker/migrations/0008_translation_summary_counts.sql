PRAGMA foreign_keys = ON;

CREATE TABLE translation_summary_counts (
    locale TEXT NOT NULL,
    dimension TEXT NOT NULL CHECK (dimension IN ('status', 'kind')),
    value TEXT NOT NULL,
    entry_count INTEGER NOT NULL DEFAULT 0 CHECK (entry_count >= 0),
    PRIMARY KEY (locale, dimension, value)
) WITHOUT ROWID;

INSERT INTO translation_summary_counts (locale, dimension, value, entry_count)
SELECT locale, 'status', status, COUNT(*)
FROM translation_entries
GROUP BY locale, status;

INSERT INTO translation_summary_counts (locale, dimension, value, entry_count)
SELECT locale, 'kind', kind, COUNT(*)
FROM translation_entries
GROUP BY locale, kind;

CREATE TRIGGER translation_summary_insert
AFTER INSERT ON translation_entries
BEGIN
    INSERT INTO translation_summary_counts (
        locale, dimension, value, entry_count
    ) VALUES (NEW.locale, 'status', NEW.status, 1)
    ON CONFLICT(locale, dimension, value)
    DO UPDATE SET entry_count = entry_count + 1;

    INSERT INTO translation_summary_counts (
        locale, dimension, value, entry_count
    ) VALUES (NEW.locale, 'kind', NEW.kind, 1)
    ON CONFLICT(locale, dimension, value)
    DO UPDATE SET entry_count = entry_count + 1;
END;

CREATE TRIGGER translation_summary_delete
AFTER DELETE ON translation_entries
BEGIN
    UPDATE translation_summary_counts
    SET entry_count = MAX(entry_count - 1, 0)
    WHERE locale = OLD.locale
      AND dimension = 'status'
      AND value = OLD.status;

    UPDATE translation_summary_counts
    SET entry_count = MAX(entry_count - 1, 0)
    WHERE locale = OLD.locale
      AND dimension = 'kind'
      AND value = OLD.kind;
END;

CREATE TRIGGER translation_summary_status_update
AFTER UPDATE OF locale, status ON translation_entries
WHEN OLD.locale != NEW.locale OR OLD.status != NEW.status
BEGIN
    UPDATE translation_summary_counts
    SET entry_count = MAX(entry_count - 1, 0)
    WHERE locale = OLD.locale
      AND dimension = 'status'
      AND value = OLD.status;

    INSERT INTO translation_summary_counts (
        locale, dimension, value, entry_count
    ) VALUES (NEW.locale, 'status', NEW.status, 1)
    ON CONFLICT(locale, dimension, value)
    DO UPDATE SET entry_count = entry_count + 1;
END;

CREATE TRIGGER translation_summary_kind_update
AFTER UPDATE OF locale, kind ON translation_entries
WHEN OLD.locale != NEW.locale OR OLD.kind != NEW.kind
BEGIN
    UPDATE translation_summary_counts
    SET entry_count = MAX(entry_count - 1, 0)
    WHERE locale = OLD.locale
      AND dimension = 'kind'
      AND value = OLD.kind;

    INSERT INTO translation_summary_counts (
        locale, dimension, value, entry_count
    ) VALUES (NEW.locale, 'kind', NEW.kind, 1)
    ON CONFLICT(locale, dimension, value)
    DO UPDATE SET entry_count = entry_count + 1;
END;

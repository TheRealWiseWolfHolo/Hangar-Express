PRAGMA foreign_keys = ON;

INSERT INTO translation_revisions (
    translation_entry_id,
    previous_status,
    new_status,
    previous_translation,
    new_translation,
    actor,
    created_at
)
SELECT
    id,
    status,
    status,
    machine_translation,
    replace(machine_translation, '战争债券 版', '战争债券版'),
    'system-glossary-migration',
    '2026-07-28T15:15:00.000Z'
FROM translation_entries
WHERE locale = 'zh-Hans'
  AND lower(source) LIKE '%warbond edition%'
  AND machine_translation LIKE '%战争债券 版%';

UPDATE translation_entries
SET machine_translation = replace(
        machine_translation,
        '战争债券 版',
        '战争债券版'
    ),
    updated_at = '2026-07-28T15:15:00.000Z'
WHERE locale = 'zh-Hans'
  AND lower(source) LIKE '%warbond edition%'
  AND machine_translation LIKE '%战争债券 版%';

INSERT OR IGNORE INTO translation_entries (
    locale,
    normalized_source,
    source_hash,
    source,
    kind,
    approved_translation,
    status,
    first_seen_at,
    last_seen_at,
    approved_at,
    approved_by,
    origin,
    updated_at
) VALUES (
    'zh-Hans',
    'warbond edition',
    'f493ac0538e68ac4b691a03e4756e41b558a970fda237d7905e1079d16d48b18',
    'Warbond Edition',
    'keyword',
    '战争债券版',
    'approved',
    '2026-07-28T15:15:00.000Z',
    '2026-07-28T15:15:00.000Z',
    '2026-07-28T15:15:00.000Z',
    'system-glossary-migration',
    'curated',
    '2026-07-28T15:15:00.000Z'
);

UPDATE dictionary_state
SET is_dirty = 1,
    changed_at = '2026-07-28T15:15:00.000Z',
    changed_by = 'system-glossary-migration'
WHERE locale = 'zh-Hans';

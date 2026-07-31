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
    replace(machine_translation, 'Standard 版', '标准版'),
    'system-glossary-migration',
    '2026-07-28T21:47:40.000Z'
FROM translation_entries
WHERE locale = 'zh-Hans'
  AND lower(source) LIKE '%standard edition%'
  AND machine_translation LIKE '%Standard 版%';

UPDATE translation_entries
SET machine_translation = replace(
        machine_translation,
        'Standard 版',
        '标准版'
    ),
    updated_at = '2026-07-28T21:47:40.000Z'
WHERE locale = 'zh-Hans'
  AND lower(source) LIKE '%standard edition%'
  AND machine_translation LIKE '%Standard 版%';

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
    'standard edition',
    '3192a4e98432c994b7e2ce1bd7261e1605539e3a831396a880d6d8b20cd75199',
    'Standard Edition',
    'keyword',
    '标准版',
    'approved',
    '2026-07-28T21:47:40.000Z',
    '2026-07-28T21:47:40.000Z',
    '2026-07-28T21:47:40.000Z',
    'system-glossary-migration',
    'curated',
    '2026-07-28T21:47:40.000Z'
);

UPDATE dictionary_state
SET is_dirty = 1,
    changed_at = '2026-07-28T21:47:40.000Z',
    changed_by = 'system-glossary-migration'
WHERE locale = 'zh-Hans';

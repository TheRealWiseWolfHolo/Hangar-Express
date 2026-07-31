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
    substr(machine_translation, 1, instr(machine_translation, ' 两 ') - 1)
        || ' 到 '
        || substr(machine_translation, instr(machine_translation, ' 两 ') + 3),
    'system-glossary-migration',
    '2026-07-28T23:05:00.000Z'
FROM translation_entries
WHERE locale = 'zh-Hans'
  AND status = 'pending'
  AND normalized_source LIKE 'upgrade - % to %'
  AND machine_translation LIKE '% 两 %';

UPDATE translation_entries
SET machine_translation =
        substr(machine_translation, 1, instr(machine_translation, ' 两 ') - 1)
        || ' 到 '
        || substr(machine_translation, instr(machine_translation, ' 两 ') + 3),
    updated_at = '2026-07-28T23:05:00.000Z'
WHERE locale = 'zh-Hans'
  AND status = 'pending'
  AND normalized_source LIKE 'upgrade - % to %'
  AND machine_translation LIKE '% 两 %';

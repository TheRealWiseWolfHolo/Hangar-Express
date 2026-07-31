import { normalizedSource, sha256, trimmedAndCollapsedSource } from "./normalization.ts";

export interface CuratedDictionaryEntry {
  source: string;
  translation: string;
  kind: string;
  aliases: string[];
}

export interface CuratedDictionary {
  locale: string;
  version: number;
  generatedAt?: string;
  count: number;
  entries: CuratedDictionaryEntry[];
}

export interface ValidatedCuratedDictionary extends CuratedDictionary {
  checksum: string;
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function nonemptyString(value: unknown, field: string, maximum: number): string {
  if (typeof value !== "string") {
    throw new Error(`${field} must be a string.`);
  }
  const normalized = trimmedAndCollapsedSource(value);
  if (!normalized || normalized.length > maximum) {
    throw new Error(`${field} must contain 1–${maximum} characters.`);
  }
  return normalized;
}

function optionalTimestamp(value: unknown): string | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value !== "string" || Number.isNaN(Date.parse(value))) {
    throw new Error("generatedAt must be an ISO-8601 timestamp when present.");
  }
  return value;
}

export async function validateCuratedDictionary(
  value: unknown,
  expectedLocale = "zh-Hans",
): Promise<ValidatedCuratedDictionary> {
  const payload = record(value);
  if (!payload) {
    throw new Error("Dictionary payload must be an object.");
  }
  if (payload.locale !== expectedLocale) {
    throw new Error(`Dictionary locale must be ${expectedLocale}.`);
  }
  if (
    typeof payload.version !== "number" ||
    !Number.isSafeInteger(payload.version) ||
    payload.version <= 0
  ) {
    throw new Error("Dictionary version must be a positive integer.");
  }
  if (!Array.isArray(payload.entries) || payload.entries.length === 0) {
    throw new Error("Dictionary entries must be a nonempty array.");
  }
  if (
    typeof payload.count !== "number" ||
    !Number.isSafeInteger(payload.count) ||
    payload.count !== payload.entries.length
  ) {
    throw new Error("Dictionary count must match the number of entries.");
  }

  const occupiedKeys = new Map<string, string>();
  const entries: CuratedDictionaryEntry[] = [];

  for (const [index, rawEntry] of payload.entries.entries()) {
    const entry = record(rawEntry);
    if (!entry) {
      throw new Error(`entries[${index}] must be an object.`);
    }

    const source = nonemptyString(entry.source, `entries[${index}].source`, 300);
    const translation = nonemptyString(
      entry.translation,
      `entries[${index}].translation`,
      500,
    );
    const kind = nonemptyString(entry.kind, `entries[${index}].kind`, 64);
    if (!Array.isArray(entry.aliases)) {
      throw new Error(`entries[${index}].aliases must be an array.`);
    }

    const aliases = entry.aliases.map((alias, aliasIndex) =>
      nonemptyString(alias, `entries[${index}].aliases[${aliasIndex}]`, 300),
    );
    const keys = [source, ...aliases];
    const localKeys = new Set<string>();

    for (const keySource of keys) {
      const key = normalizedSource(keySource);
      if (localKeys.has(key)) {
        throw new Error(`Duplicate source or alias within entry: ${keySource}.`);
      }
      localKeys.add(key);

      const existing = occupiedKeys.get(key);
      if (existing) {
        throw new Error(
          `Duplicate normalized dictionary key "${keySource}" conflicts with "${existing}".`,
        );
      }
      occupiedKeys.set(key, source);
    }

    entries.push({ source, translation, kind, aliases });
  }

  const generatedAt = optionalTimestamp(payload.generatedAt);
  const canonicalPayload = JSON.stringify({
    locale: expectedLocale,
    version: payload.version,
    generatedAt,
    count: entries.length,
    entries,
  });

  return {
    locale: expectedLocale,
    version: payload.version,
    generatedAt,
    count: entries.length,
    entries,
    checksum: await sha256(canonicalPayload),
  };
}

function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function sqlNullableString(value: string | undefined): string {
  return value === undefined ? "NULL" : sqlString(value);
}

export async function buildCuratedImportSQL(
  dictionary: ValidatedCuratedDictionary,
  importedAt: Date,
): Promise<string> {
  const timestamp = importedAt.toISOString();
  const statements: string[] = [
    "PRAGMA foreign_keys = ON;",
    `INSERT OR IGNORE INTO curated_imports (
      locale, dictionary_version, generated_at, checksum, entry_count, imported_at
    ) VALUES (
      ${sqlString(dictionary.locale)},
      ${dictionary.version},
      ${sqlNullableString(dictionary.generatedAt)},
      ${sqlString(dictionary.checksum)},
      ${dictionary.count},
      ${sqlString(timestamp)}
    );`,
  ];

  for (const entry of dictionary.entries) {
    const normalized = normalizedSource(entry.source);
    const sourceHash = await sha256(`${dictionary.locale}\n${normalized}`);

    statements.push(
      `INSERT INTO translation_entries (
        locale, normalized_source, source_hash, source, kind,
        approved_translation, status, first_seen_at, last_seen_at,
        approved_at, approved_by, origin, source_dictionary_version,
        source_dictionary_generated_at, updated_at
      ) VALUES (
        ${sqlString(dictionary.locale)},
        ${sqlString(normalized)},
        ${sqlString(sourceHash)},
        ${sqlString(entry.source)},
        ${sqlString(entry.kind)},
        ${sqlString(entry.translation)},
        'approved',
        ${sqlString(timestamp)},
        ${sqlString(timestamp)},
        ${sqlString(timestamp)},
        'curated-import',
        'curated',
        ${dictionary.version},
        ${sqlNullableString(dictionary.generatedAt)},
        ${sqlString(timestamp)}
      )
      ON CONFLICT(locale, normalized_source) DO UPDATE SET
        source = excluded.source,
        source_hash = excluded.source_hash,
        kind = excluded.kind,
        approved_translation = excluded.approved_translation,
        status = 'approved',
        approved_at = excluded.approved_at,
        approved_by = excluded.approved_by,
        origin = 'curated',
        source_dictionary_version = excluded.source_dictionary_version,
        source_dictionary_generated_at = excluded.source_dictionary_generated_at,
        updated_at = excluded.updated_at,
        failure_reason = NULL,
        retry_after = NULL,
        deferred_until = NULL
      WHERE translation_entries.origin = 'curated'
         OR translation_entries.status IN ('generating', 'pending', 'failed');`,
      `DELETE FROM translation_aliases
       WHERE translation_entry_id = (
         SELECT id FROM translation_entries
         WHERE locale = ${sqlString(dictionary.locale)}
           AND normalized_source = ${sqlString(normalized)}
           AND origin = 'curated'
       );`,
    );

    for (const alias of entry.aliases) {
      statements.push(
        `INSERT OR IGNORE INTO translation_aliases (
          translation_entry_id, alias, normalized_alias
        )
        SELECT id, ${sqlString(alias)}, ${sqlString(normalizedSource(alias))}
        FROM translation_entries
        WHERE locale = ${sqlString(dictionary.locale)}
          AND normalized_source = ${sqlString(normalized)}
          AND origin = 'curated';`,
      );
    }
  }

  statements.push(
    `UPDATE dictionary_state
     SET is_dirty = 1,
         changed_at = ${sqlString(timestamp)},
         changed_by = 'curated-import'
     WHERE locale = ${sqlString(dictionary.locale)};`,
  );

  return `${statements.join("\n")}\n`;
}

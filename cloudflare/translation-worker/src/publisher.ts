import type { AdminIdentity } from "./access.ts";
import { supportedTargetLocale } from "./contracts.ts";
import {
  validateCuratedDictionary,
  type CuratedDictionaryEntry,
  type ValidatedCuratedDictionary,
} from "./dictionary.ts";
import {
  normalizedSource,
  sha256,
  sha256Digest,
  trimmedAndCollapsedSource,
} from "./normalization.ts";

interface PublishEntryRow {
  id: number;
  source: string;
  translation: string;
  kind: string;
}

interface PublishAliasRow {
  translation_entry_id: number;
  alias: string;
}

interface DictionaryStateRow {
  is_dirty: number;
  changed_at: string | null;
  changed_by: string | null;
}

interface DictionaryReleaseRow {
  id: number;
  locale: string;
  version: number;
  object_key: string;
  checksum: string;
  entry_count: number;
  status: string;
  created_at: string;
  published_at: string | null;
  note: string | null;
}

export interface ReleaseEntryDiff {
  type: "added" | "removed" | "changed";
  source: string;
  from: CuratedDictionaryEntry | null;
  to: CuratedDictionaryEntry | null;
}

export interface BuiltDictionaryRelease {
  locale: string;
  version: number;
  generatedAt: string;
  count: number;
  sourceCount: number;
  entries: CuratedDictionaryEntry[];
  body: string;
  checksum: string;
}

export interface StoredReleaseDescriptor {
  size: number;
  customMetadata?: Record<string, string>;
}

type MutationValidation =
  | { body: Record<string, unknown>; response?: never }
  | { body?: never; response: Response };

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function timestampMatches(column: string, parameter: string): string {
  return `(${column} = ${parameter} OR (${column} IS NULL AND ${parameter} IS NULL))`;
}

const maximumComparableReleaseBytes = 5 * 1024 * 1024;
const maximumReturnedReleaseChanges = 500;

export function verifyReleaseObjectMetadata(
  object: StoredReleaseDescriptor,
  expected: {
    locale: string;
    version: number;
    count: number;
    checksum: string;
  },
): void {
  if (object.size > maximumComparableReleaseBytes) {
    throw new Error(`Release v${expected.version} is too large to verify safely.`);
  }
  if (
    object.customMetadata?.checksum !== expected.checksum ||
    object.customMetadata?.locale !== expected.locale ||
    object.customMetadata?.version !== String(expected.version) ||
    object.customMetadata?.entryCount !== String(expected.count)
  ) {
    throw new Error(`Release v${expected.version} metadata does not match D1.`);
  }
}

export function validatePublishBody(
  body: Record<string, unknown>,
):
  | { expectedChangedAt: string | null; note: string | null }
  | string {
  const expectedChangedAt = body.expectedChangedAt;
  if (
    expectedChangedAt !== null &&
    (typeof expectedChangedAt !== "string" ||
      Number.isNaN(Date.parse(expectedChangedAt)))
  ) {
    return "expectedChangedAt must be an ISO-8601 timestamp or null.";
  }

  if (body.note !== undefined && body.note !== null && typeof body.note !== "string") {
    return "note must be a string when present.";
  }
  const note =
    typeof body.note === "string" ? trimmedAndCollapsedSource(body.note) : "";
  if (note.length > 240) {
    return "note must contain at most 240 characters.";
  }
  return {
    expectedChangedAt: expectedChangedAt as string | null,
    note: note || null,
  };
}

function comparableEntry(entry: CuratedDictionaryEntry): CuratedDictionaryEntry {
  return {
    source: entry.source,
    translation: entry.translation,
    kind: entry.kind,
    aliases: [...entry.aliases].sort((left, right) => left.localeCompare(right)),
  };
}

export function compareReleaseEntries(
  fromEntries: CuratedDictionaryEntry[],
  toEntries: CuratedDictionaryEntry[],
): ReleaseEntryDiff[] {
  const fromBySource = new Map(
    fromEntries.map((entry) => [normalizedSource(entry.source), comparableEntry(entry)]),
  );
  const toBySource = new Map(
    toEntries.map((entry) => [normalizedSource(entry.source), comparableEntry(entry)]),
  );
  const keys = [...new Set([...fromBySource.keys(), ...toBySource.keys()])].sort();
  const changes: ReleaseEntryDiff[] = [];

  for (const key of keys) {
    const from = fromBySource.get(key) ?? null;
    const to = toBySource.get(key) ?? null;
    if (!from && to) {
      changes.push({ type: "added", source: to.source, from: null, to });
    } else if (from && !to) {
      changes.push({ type: "removed", source: from.source, from, to: null });
    } else if (from && to && JSON.stringify(from) !== JSON.stringify(to)) {
      changes.push({ type: "changed", source: to.source, from, to });
    }
  }
  return changes;
}

async function validatedMutation(
  request: Request,
): Promise<MutationValidation> {
  const requestURL = new URL(request.url);
  if (request.headers.get("origin") !== requestURL.origin) {
    return { response: json({ error: "A same-origin request is required." }, 403) };
  }
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    return {
      response: json({ error: "Content-Type must be application/json." }, 415),
    };
  }
  try {
    const value: unknown = await request.json();
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return { response: json({ error: "Request body must be an object." }, 400) };
    }
    return { body: value as Record<string, unknown> };
  } catch {
    return { response: json({ error: "Request body must be valid JSON." }, 400) };
  }
}

export async function buildDictionaryRelease(
  version: number,
  generatedAt: Date,
  rows: PublishEntryRow[],
  aliasRows: PublishAliasRow[],
): Promise<BuiltDictionaryRelease> {
  if (!Number.isSafeInteger(version) || version <= 0) {
    throw new Error("Release version must be a positive integer.");
  }
  if (rows.length === 0) {
    throw new Error("A dictionary release must contain at least one entry.");
  }

  const aliasesByID = new Map<number, string[]>();
  const entryIDs = new Set(rows.map((row) => row.id));
  for (const row of aliasRows) {
    if (!entryIDs.has(row.translation_entry_id)) {
      throw new Error(`Alias references missing entry ${row.translation_entry_id}.`);
    }
    const aliases = aliasesByID.get(row.translation_entry_id) ?? [];
    aliases.push(row.alias);
    aliasesByID.set(row.translation_entry_id, aliases);
  }

  const timestamp = generatedAt.toISOString();
  const entries = rows.map((row) => ({
    source: row.source,
    translation: row.translation,
    kind: row.kind,
    aliases: aliasesByID.get(row.id) ?? [],
  }));
  const payload = {
    locale: supportedTargetLocale,
    version,
    generatedAt: timestamp,
    count: entries.length,
    sourceCount: entries.length,
    entries,
  };

  await validateCuratedDictionary(payload);
  const body = `${JSON.stringify(payload, null, 2)}\n`;
  return {
    ...payload,
    body,
    checksum: await sha256(body),
  };
}

export async function verifyDictionaryRelease(
  body: string,
  expected: {
    version: number;
    count: number;
    checksum: string;
  },
): Promise<void> {
  if (await sha256(body) !== expected.checksum) {
    throw new Error("Published dictionary checksum does not match.");
  }

  let raw: unknown;
  try {
    raw = JSON.parse(body);
  } catch {
    throw new Error("Published dictionary is not valid JSON.");
  }
  const validated = await validateCuratedDictionary(raw);
  const rawRecord = raw as Record<string, unknown>;
  if (
    validated.version !== expected.version ||
    validated.count !== expected.count ||
    rawRecord.sourceCount !== expected.count
  ) {
    throw new Error("Published dictionary metadata does not match the staged release.");
  }
}

async function dictionaryState(env: AdminEnv): Promise<DictionaryStateRow | null> {
  return env.DB
    .prepare(
      `SELECT is_dirty, changed_at, changed_by
       FROM dictionary_state
       WHERE locale = ?1`,
    )
    .bind(supportedTargetLocale)
    .first<DictionaryStateRow>();
}

async function failRelease(
  env: AdminEnv,
  version: number,
  identity: AdminIdentity,
  error: unknown,
): Promise<void> {
  const timestamp = new Date().toISOString();
  const reason = (
    error instanceof Error ? error.message : String(error)
  ).slice(0, 500);
  await env.DB.batch([
    env.DB
      .prepare(
        `UPDATE dictionary_releases
         SET status = 'failed'
         WHERE locale = ?1 AND version = ?2 AND status = 'staged'`,
      )
      .bind(supportedTargetLocale, version),
    env.DB
      .prepare(
        `INSERT INTO dictionary_release_events (
          locale, release_id, event, actor, detail, created_at
        )
        SELECT locale, id, 'failed', ?1, ?2, ?3
        FROM dictionary_releases
        WHERE locale = ?4 AND version = ?5`,
      )
      .bind(
        identity.email,
        JSON.stringify({ reason }),
        timestamp,
        supportedTargetLocale,
        version,
      ),
  ]);
}

async function publishDictionary(
  request: Request,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const mutation = await validatedMutation(request);
  if (mutation.response) {
    return mutation.response;
  }
  const validatedBody = validatePublishBody(mutation.body);
  if (typeof validatedBody === "string") {
    return json({ error: validatedBody }, 400);
  }
  const { expectedChangedAt, note } = validatedBody;

  const before = await dictionaryState(env);
  if (!before || before.is_dirty !== 1) {
    return json({ error: "There are no unpublished dictionary changes." }, 409);
  }
  if (before.changed_at !== expectedChangedAt) {
    return json(
      { error: "Dictionary changes were updated. Refresh before publishing." },
      409,
    );
  }

  const [entryRows, aliasRows] = await Promise.all([
    env.DB
      .prepare(
        `SELECT id, source, approved_translation AS translation, kind
         FROM translation_entries
         WHERE locale = ?1
           AND status IN ('approved', 'edited')
           AND approved_translation IS NOT NULL
         ORDER BY normalized_source, id`,
      )
      .bind(supportedTargetLocale)
      .all<PublishEntryRow>(),
    env.DB
      .prepare(
        `SELECT a.translation_entry_id, a.alias
         FROM translation_aliases a
         JOIN translation_entries e ON e.id = a.translation_entry_id
         WHERE e.locale = ?1
           AND e.status IN ('approved', 'edited')
           AND e.approved_translation IS NOT NULL
         ORDER BY e.normalized_source, a.normalized_alias, a.id`,
      )
      .bind(supportedTargetLocale)
      .all<PublishAliasRow>(),
  ]);
  const after = await dictionaryState(env);
  if (
    !after ||
    after.is_dirty !== 1 ||
    after.changed_at !== before.changed_at
  ) {
    return json(
      { error: "Dictionary changed while its release was being prepared." },
      409,
    );
  }

  const latest = await env.DB
    .prepare(
      `SELECT COALESCE(MAX(version), 0) AS version
       FROM dictionary_releases
       WHERE locale = ?1`,
    )
    .bind(supportedTargetLocale)
    .first<{ version: number }>();
  const version = (latest?.version ?? 0) + 1;
  const generatedAt = new Date();
  const built = await buildDictionaryRelease(
    version,
    generatedAt,
    entryRows.results ?? [],
    aliasRows.results ?? [],
  );
  const objectKey = `releases/${supportedTargetLocale}/v${version}.json`;
  const timestamp = generatedAt.toISOString();

  try {
    await env.DB.batch([
      env.DB
        .prepare(
          `INSERT INTO dictionary_releases (
            locale, version, object_key, checksum, entry_count,
            status, created_at, note
          ) VALUES (?1, ?2, ?3, ?4, ?5, 'staged', ?6, ?7)`,
        )
        .bind(
          supportedTargetLocale,
          version,
          objectKey,
          built.checksum,
          built.count,
          timestamp,
          note,
        ),
      env.DB
        .prepare(
          `INSERT INTO dictionary_release_events (
            locale, release_id, event, actor, detail, created_at
          )
          SELECT locale, id, 'staged', ?1, ?2, ?3
          FROM dictionary_releases
          WHERE locale = ?4 AND version = ?5`,
        )
        .bind(
          identity.email,
          JSON.stringify({
            checksum: built.checksum,
            entryCount: built.count,
            objectKey,
            note,
          }),
          timestamp,
          supportedTargetLocale,
          version,
        ),
    ]);
  } catch {
    return json(
      { error: "Another dictionary publication is already in progress." },
      409,
    );
  }

  try {
    const checksumBytes = await sha256Digest(built.body);
    const stored = await env.RELEASES.put(objectKey, built.body, {
      onlyIf: { etagDoesNotMatch: "*" },
      httpMetadata: {
        contentType: "application/json; charset=utf-8",
        contentLanguage: supportedTargetLocale,
        cacheControl: "public, max-age=31536000, immutable",
      },
      customMetadata: {
        checksum: built.checksum,
        locale: supportedTargetLocale,
        version: String(version),
        entryCount: String(built.count),
      },
      sha256: checksumBytes,
    });
    if (!stored) {
      throw new Error("The immutable R2 release key already exists.");
    }

    const readback = await env.RELEASES.get(objectKey);
    if (!readback) {
      throw new Error("The R2 release could not be read after writing.");
    }
    verifyReleaseObjectMetadata(readback, {
      locale: supportedTargetLocale,
      version,
      count: built.count,
      checksum: built.checksum,
    });
    const readbackBody = await readback.text();
    await verifyDictionaryRelease(readbackBody, {
      version,
      count: built.count,
      checksum: built.checksum,
    });

    const guard = timestampMatches("changed_at", "?1");
    const switched = await env.DB.batch([
      env.DB
        .prepare(
          `UPDATE dictionary_releases
           SET status = 'superseded'
           WHERE locale = ?2
             AND status = 'current'
             AND EXISTS (
               SELECT 1 FROM dictionary_state
               WHERE locale = ?2 AND is_dirty = 1 AND ${guard}
             )`,
        )
        .bind(before.changed_at, supportedTargetLocale),
      env.DB
        .prepare(
          `UPDATE dictionary_releases
           SET status = 'current', published_at = ?1
           WHERE locale = ?2
             AND version = ?3
             AND status = 'staged'
             AND EXISTS (
               SELECT 1 FROM dictionary_state
               WHERE locale = ?2
                 AND is_dirty = 1
                 AND ${timestampMatches("changed_at", "?4")}
             )`,
        )
        .bind(timestamp, supportedTargetLocale, version, before.changed_at),
      env.DB
        .prepare(
          `UPDATE dictionary_state
           SET is_dirty = 0, changed_at = ?1, changed_by = ?2
           WHERE locale = ?3
             AND is_dirty = 1
             AND ${timestampMatches("changed_at", "?4")}`,
        )
        .bind(timestamp, identity.email, supportedTargetLocale, before.changed_at),
      env.DB
        .prepare(
          `INSERT INTO dictionary_release_events (
            locale, release_id, event, actor, detail, created_at
          )
          SELECT locale, id, 'published', ?1, ?2, ?3
          FROM dictionary_releases
          WHERE locale = ?4 AND version = ?5 AND status = 'current'`,
        )
        .bind(
          identity.email,
          JSON.stringify({ checksum: built.checksum, entryCount: built.count }),
          timestamp,
          supportedTargetLocale,
          version,
        ),
    ]);

    if ((switched[1]?.meta.changes ?? 0) !== 1) {
      throw new Error("Dictionary changed before the release could be activated.");
    }

    return json({
      release: {
        version,
        checksum: built.checksum,
        entryCount: built.count,
        objectKey,
        publishedAt: timestamp,
      },
    }, 201);
  } catch (error) {
    await failRelease(env, version, identity, error);
    return json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Dictionary publication failed.",
      },
      409,
    );
  }
}

async function listReleases(env: AdminEnv): Promise<Response> {
  const releases = await env.DB
    .prepare(
      `SELECT id, locale, version, object_key, checksum, entry_count,
              status, created_at, published_at, note
       FROM dictionary_releases
       WHERE locale = ?1
       ORDER BY version DESC
       LIMIT 50`,
    )
    .bind(supportedTargetLocale)
    .all<DictionaryReleaseRow>();
  return json({ releases: releases.results ?? [] });
}

async function verifiedReleaseDictionary(
  release: DictionaryReleaseRow,
  env: AdminEnv,
): Promise<ValidatedCuratedDictionary> {
  const object = await env.RELEASES.get(release.object_key);
  if (!object) {
    throw new Error(`Release v${release.version} is missing from R2.`);
  }
  verifyReleaseObjectMetadata(object, {
    locale: supportedTargetLocale,
    version: release.version,
    count: release.entry_count,
    checksum: release.checksum,
  });
  const body = await object.text();
  await verifyDictionaryRelease(body, {
    version: release.version,
    count: release.entry_count,
    checksum: release.checksum,
  });
  return validateCuratedDictionary(JSON.parse(body));
}

async function compareReleases(
  fromVersion: number,
  toVersion: number,
  env: AdminEnv,
): Promise<Response> {
  if (fromVersion === toVersion) {
    return json({ error: "Choose two different releases to compare." }, 400);
  }
  const [fromRelease, toRelease] = await Promise.all([
    env.DB
      .prepare(
        `SELECT id, locale, version, object_key, checksum, entry_count,
                status, created_at, published_at, note
         FROM dictionary_releases
         WHERE locale = ?1
           AND version = ?2
           AND status IN ('current', 'superseded')`,
      )
      .bind(supportedTargetLocale, fromVersion)
      .first<DictionaryReleaseRow>(),
    env.DB
      .prepare(
        `SELECT id, locale, version, object_key, checksum, entry_count,
                status, created_at, published_at, note
         FROM dictionary_releases
         WHERE locale = ?1
           AND version = ?2
           AND status IN ('current', 'superseded')`,
      )
      .bind(supportedTargetLocale, toVersion)
      .first<DictionaryReleaseRow>(),
  ]);
  if (!fromRelease || !toRelease) {
    return json({ error: "Both releases must be verified release versions." }, 404);
  }

  try {
    const [fromDictionary, toDictionary] = await Promise.all([
      verifiedReleaseDictionary(fromRelease, env),
      verifiedReleaseDictionary(toRelease, env),
    ]);
    const changes = compareReleaseEntries(
      fromDictionary.entries,
      toDictionary.entries,
    );
    const counts = changes.reduce(
      (summary, change) => {
        summary[change.type] += 1;
        return summary;
      },
      { added: 0, removed: 0, changed: 0 },
    );
    return json({
      from: {
        version: fromRelease.version,
        checksum: fromRelease.checksum,
        entryCount: fromRelease.entry_count,
        note: fromRelease.note,
      },
      to: {
        version: toRelease.version,
        checksum: toRelease.checksum,
        entryCount: toRelease.entry_count,
        note: toRelease.note,
      },
      summary: {
        ...counts,
        total: changes.length,
      },
      changes: changes.slice(0, maximumReturnedReleaseChanges),
      truncated: changes.length > maximumReturnedReleaseChanges,
    });
  } catch (error) {
    return json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Release comparison failed verification.",
      },
      409,
    );
  }
}

async function rollbackRelease(
  request: Request,
  targetVersion: number,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const mutation = await validatedMutation(request);
  if (mutation.response) {
    return mutation.response;
  }
  const expectedCurrentVersion = mutation.body.expectedCurrentVersion;
  if (
    typeof expectedCurrentVersion !== "number" ||
    !Number.isSafeInteger(expectedCurrentVersion) ||
    expectedCurrentVersion <= 0
  ) {
    return json({ error: "expectedCurrentVersion must be a positive integer." }, 400);
  }
  if (targetVersion === expectedCurrentVersion) {
    return json({ error: "The target release is already current." }, 409);
  }

  const [current, target] = await Promise.all([
    env.DB
      .prepare(
        `SELECT id, locale, version, object_key, checksum, entry_count,
                status, created_at, published_at, note
         FROM dictionary_releases
         WHERE locale = ?1 AND status = 'current'`,
      )
      .bind(supportedTargetLocale)
      .first<DictionaryReleaseRow>(),
    env.DB
      .prepare(
        `SELECT id, locale, version, object_key, checksum, entry_count,
                status, created_at, published_at, note
         FROM dictionary_releases
         WHERE locale = ?1 AND version = ?2`,
      )
      .bind(supportedTargetLocale, targetVersion)
      .first<DictionaryReleaseRow>(),
  ]);
  if (!current || current.version !== expectedCurrentVersion) {
    return json({ error: "The current release changed. Refresh before rollback." }, 409);
  }
  if (!target || target.status !== "superseded") {
    return json({ error: "Only a verified superseded release can be restored." }, 409);
  }

  try {
    await verifiedReleaseDictionary(target, env);
  } catch (error) {
    return json(
      {
        error:
          error instanceof Error ? error.message : "Target release validation failed.",
      },
      409,
    );
  }

  const timestamp = new Date().toISOString();
  try {
    const results = await env.DB.batch([
      env.DB
        .prepare(
          `UPDATE dictionary_releases
           SET status = 'superseded'
           WHERE locale = ?1 AND version = ?2 AND status = 'current'`,
        )
        .bind(supportedTargetLocale, expectedCurrentVersion),
      env.DB
        .prepare(
          `UPDATE dictionary_releases
           SET status = 'current', published_at = ?1
           WHERE locale = ?2 AND version = ?3 AND status = 'superseded'`,
        )
        .bind(timestamp, supportedTargetLocale, targetVersion),
      env.DB
        .prepare(
          `UPDATE dictionary_state
           SET is_dirty = 1, changed_at = ?1, changed_by = ?2
           WHERE locale = ?3`,
        )
        .bind(timestamp, identity.email, supportedTargetLocale),
      env.DB
        .prepare(
          `INSERT INTO dictionary_release_events (
            locale, release_id, event, actor, detail, created_at
          )
          SELECT locale, id, 'rollback', ?1, ?2, ?3
          FROM dictionary_releases
          WHERE locale = ?4 AND version = ?5 AND status = 'current'`,
        )
        .bind(
          identity.email,
          JSON.stringify({ fromVersion: expectedCurrentVersion }),
          timestamp,
          supportedTargetLocale,
          targetVersion,
        ),
    ]);
    if (
      (results[0]?.meta.changes ?? 0) !== 1 ||
      (results[1]?.meta.changes ?? 0) !== 1
    ) {
      return json({ error: "The current release changed during rollback." }, 409);
    }
  } catch {
    return json({ error: "The current release changed during rollback." }, 409);
  }

  return json({
    release: {
      version: target.version,
      checksum: target.checksum,
      entryCount: target.entry_count,
      objectKey: target.object_key,
      publishedAt: timestamp,
    },
  });
}

export async function handleReleaseRequest(
  request: Request,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname === "/admin/api/releases") {
    if (request.method === "GET") {
      return listReleases(env);
    }
    return json({ error: "Method not allowed." }, 405);
  }
  if (
    url.pathname === "/admin/api/releases/publish" &&
    request.method === "POST"
  ) {
    return publishDictionary(request, identity, env);
  }

  const rollbackMatch = url.pathname.match(
    /^\/admin\/api\/releases\/(\d+)\/rollback$/u,
  );
  if (rollbackMatch && request.method === "POST") {
    return rollbackRelease(
      request,
      Number.parseInt(rollbackMatch[1], 10),
      identity,
      env,
    );
  }
  const compareMatch = url.pathname.match(
    /^\/admin\/api\/releases\/(\d+)\/compare\/(\d+)$/u,
  );
  if (compareMatch && request.method === "GET") {
    return compareReleases(
      Number.parseInt(compareMatch[1], 10),
      Number.parseInt(compareMatch[2], 10),
      env,
    );
  }
  if (url.pathname.startsWith("/admin/api/releases/")) {
    return json({ error: "Not found." }, 404);
  }
  return null;
}

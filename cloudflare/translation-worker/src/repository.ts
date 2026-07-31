import { normalizedSource, sha256 } from "./normalization.ts";
import type { ValidatedItem } from "./validation.ts";

export type StoredStatus =
  | "generating"
  | "pending"
  | "approved"
  | "edited"
  | "rejected"
  | "failed";

export interface StoredTranslation {
  id: number;
  source: string;
  normalized_source: string;
  kind: string;
  machine_translation: string | null;
  approved_translation: string | null;
  status: StoredStatus;
  retry_after: string | null;
  retry_job_id: number | null;
}

export interface TranslationClaim {
  normalizedSource: string;
  sourceHash: string;
  stored: StoredTranslation;
  ownsGeneration: boolean;
}

export interface ApprovedGlossaryTerm {
  source: string;
  translation: string;
}

export interface RetryTranslationClaim {
  id: number;
  source: string;
}

export interface TranslationQueueClaim {
  id: number;
  source: string;
}

interface RetryTranslationCandidate extends RetryTranslationClaim {
  status: "failed" | "generating";
}

interface ApprovedGlossaryRow {
  match_source: string;
  approved_translation: string;
}

export async function findApprovedGlossaryTerms(
  db: D1Database,
  locale: string,
  source: string,
  maximumTerms = 32,
): Promise<ApprovedGlossaryTerm[]> {
  const normalized = normalizedSource(source);
  const result = await db
    .prepare(
      `SELECT match_source, approved_translation
       FROM (
         SELECT source AS match_source,
                normalized_source AS normalized_match,
                approved_translation
         FROM translation_entries
         WHERE locale = ?1
           AND status IN ('approved', 'edited')
           AND approved_translation IS NOT NULL
         UNION ALL
         SELECT aliases.alias AS match_source,
                aliases.normalized_alias AS normalized_match,
                entries.approved_translation
         FROM translation_aliases AS aliases
         INNER JOIN translation_entries AS entries
           ON entries.id = aliases.translation_entry_id
         WHERE entries.locale = ?1
           AND entries.status IN ('approved', 'edited')
           AND entries.approved_translation IS NOT NULL
       )
       WHERE length(normalized_match) >= 2
         AND instr(?2, normalized_match) > 0
       ORDER BY length(normalized_match) DESC
       LIMIT ?3`,
    )
    .bind(locale, normalized, maximumTerms)
    .all<ApprovedGlossaryRow>();

  return result.results.map((row) => ({
    source: row.match_source,
    translation: row.approved_translation,
  }));
}

export async function findOrClaimTranslation(
  db: D1Database,
  locale: string,
  item: ValidatedItem,
  now: Date,
): Promise<TranslationClaim> {
  const normalized = normalizedSource(item.source);
  const sourceHash = await sha256(`${locale}\n${normalized}`);
  const timestamp = now.toISOString();
  const staleGenerationTimestamp = new Date(
    now.getTime() - 10 * 60 * 1000,
  ).toISOString();
  const seenCountRefreshTimestamp = new Date(
    now.getTime() - 60 * 60 * 1000,
  ).toISOString();

  const insert = await db
    .prepare(
      `INSERT OR IGNORE INTO translation_entries (
        locale, normalized_source, source_hash, source, kind, status,
        first_seen_at, last_seen_at, updated_at
      ) VALUES (?1, ?2, ?3, ?4, ?5, 'generating', ?6, ?6, ?6)`,
    )
    .bind(locale, normalized, sourceHash, item.source, item.kind, timestamp)
    .run();

  let ownsGeneration = (insert.meta?.changes ?? 0) > 0;

  if (!ownsGeneration) {
    await db
      .prepare(
        `UPDATE translation_entries
         SET last_seen_at = ?1, seen_count = seen_count + 1
         WHERE locale = ?2
           AND normalized_source = ?3
           AND last_seen_at <= ?4`,
      )
      .bind(timestamp, locale, normalized, seenCountRefreshTimestamp)
      .run();

    const reclaim = await db
      .prepare(
        `UPDATE translation_entries
         SET status = 'generating',
             machine_translation = NULL,
             model = NULL,
             model_version = NULL,
             failure_reason = NULL,
             retry_after = NULL,
             updated_at = ?1
         WHERE locale = ?2
           AND normalized_source = ?3
           AND retry_job_id IS NULL
           AND (
             (
               status = 'failed'
               AND (retry_after IS NULL OR retry_after <= ?1)
             )
             OR (
               status = 'generating'
               AND (updated_at IS NULL OR updated_at <= ?4)
             )
           )`,
      )
      .bind(timestamp, locale, normalized, staleGenerationTimestamp)
      .run();
    ownsGeneration = (reclaim.meta?.changes ?? 0) > 0;
  }

  const stored = await db
    .prepare(
      `SELECT id, source, normalized_source, kind, machine_translation,
              approved_translation, status, retry_after, retry_job_id
       FROM translation_entries
       WHERE locale = ?1 AND normalized_source = ?2`,
    )
    .bind(locale, normalized)
    .first<StoredTranslation>();

  if (!stored) {
    throw new Error("Translation claim could not be read after insertion.");
  }

  return {
    normalizedSource: normalized,
    sourceHash,
    stored,
    ownsGeneration,
  };
}

export async function enqueueTranslations(
  db: D1Database,
  locale: string,
  claims: TranslationQueueClaim[],
  now: Date,
): Promise<number[]> {
  if (claims.length === 0) {
    return [];
  }

  const timestamp = now.toISOString();
  const requestedBy = `mobile-upload:${crypto.randomUUID()}`;
  const job = await db
    .prepare(
      `INSERT INTO ai_retry_jobs (
         locale, requested_by, total_entries, remaining_entries,
         processing_entries, completed_entries, created_at
       ) VALUES (?1, ?2, ?3, ?3, 0, 0, ?4)
       RETURNING id`,
    )
    .bind(locale, requestedBy, claims.length, timestamp)
    .first<{ id: number }>();
  if (!job) {
    throw new Error("The translation queue job could not be created.");
  }

  const ids = claims.map((claim) => claim.id);
  const placeholders = ids.map(() => "?").join(", ");
  const queued = await db
    .prepare(
      `UPDATE translation_entries
       SET status = 'failed',
           failure_reason = 'Queued for background translation.',
           retry_after = ?,
           retry_job_id = ?,
           updated_at = ?
       WHERE id IN (${placeholders})
         AND locale = ?
         AND status = 'generating'
         AND retry_job_id IS NULL
       RETURNING id`,
    )
    .bind(timestamp, job.id, timestamp, ...ids, locale)
    .all<{ id: number }>();
  const queuedIDs = queued.results.map((row) => row.id);

  if (queuedIDs.length !== claims.length) {
    await db
      .prepare(
        `UPDATE ai_retry_jobs
         SET total_entries = ?1,
             remaining_entries = ?1
         WHERE id = ?2`,
      )
      .bind(queuedIDs.length, job.id)
      .run();
  }
  if (queuedIDs.length === 0) {
    await db
      .prepare(`DELETE FROM ai_retry_jobs WHERE id = ?1`)
      .bind(job.id)
      .run();
  }

  return queuedIDs;
}

export async function claimQueuedTranslationByID(
  db: D1Database,
  locale: string,
  id: number,
  now: Date,
): Promise<RetryTranslationClaim | null> {
  const timestamp = now.toISOString();
  return db
    .prepare(
      `UPDATE translation_entries
       SET status = 'generating',
           machine_translation = NULL,
           model = NULL,
           model_version = NULL,
           failure_reason = NULL,
           retry_after = NULL,
           updated_at = ?1
       WHERE id = ?2
         AND locale = ?3
         AND retry_job_id IS NOT NULL
         AND status = 'failed'
         AND (retry_after IS NULL OR retry_after <= ?1)
       RETURNING id, source`,
    )
    .bind(timestamp, id, locale)
    .first<RetryTranslationClaim>();
}

export async function claimNextRetryableTranslation(
  db: D1Database,
  locale: string,
  now: Date,
  maximumAttempts = 4,
): Promise<RetryTranslationClaim | null> {
  const timestamp = now.toISOString();
  const staleGenerationTimestamp = new Date(
    now.getTime() - 10 * 60 * 1000,
  ).toISOString();

  for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
    const failedCandidate = await db
      .prepare(
        `SELECT id, source, status
         FROM translation_entries
         WHERE locale = ?1
           AND retry_job_id IS NOT NULL
           AND status = 'failed'
           AND (retry_after IS NULL OR retry_after <= ?2)
         ORDER BY retry_after, id
         LIMIT 1`,
      )
      .bind(locale, timestamp)
      .first<RetryTranslationCandidate>();
    const candidate =
      failedCandidate ??
      await db
        .prepare(
          `SELECT id, source, status
           FROM translation_entries
           WHERE locale = ?1
             AND retry_job_id IS NOT NULL
             AND status = 'generating'
             AND (updated_at IS NULL OR updated_at <= ?2)
           ORDER BY updated_at, id
           LIMIT 1`,
        )
        .bind(locale, staleGenerationTimestamp)
        .first<RetryTranslationCandidate>();

    if (!candidate) {
      return null;
    }

    const claimed = await db
      .prepare(
        `UPDATE translation_entries
         SET status = 'generating',
             machine_translation = NULL,
             model = NULL,
             model_version = NULL,
             failure_reason = NULL,
             retry_after = NULL,
             updated_at = ?1
         WHERE id = ?2
           AND locale = ?3
           AND retry_job_id IS NOT NULL
           AND status = ?4
           AND (
             (
               ?4 = 'failed'
               AND (retry_after IS NULL OR retry_after <= ?1)
             )
             OR (
               ?4 = 'generating'
               AND (updated_at IS NULL OR updated_at <= ?5)
             )
           )
         RETURNING id`,
      )
      .bind(
        timestamp,
        candidate.id,
        locale,
        candidate.status,
        staleGenerationTimestamp,
      )
      .first<{ id: number }>();

    if (claimed?.id === candidate.id) {
      return { id: candidate.id, source: candidate.source };
    }
  }

  return null;
}

export async function reserveDailyBudget(
  db: D1Database,
  usageDate: string,
  characters: number,
  requestLimit: number,
  characterLimit: number,
  requests = 1,
): Promise<boolean> {
  const result = await db
    .prepare(
      `INSERT INTO daily_usage (usage_date, ai_requests, ai_characters)
       VALUES (?1, ?2, ?3)
       ON CONFLICT(usage_date) DO UPDATE SET
         ai_requests = ai_requests + excluded.ai_requests,
         ai_characters = ai_characters + excluded.ai_characters
       WHERE daily_usage.ai_requests + excluded.ai_requests <= ?4
         AND daily_usage.ai_characters + excluded.ai_characters <= ?5`,
    )
    .bind(usageDate, requests, characters, requestLimit, characterLimit)
    .run();

  return (result.meta?.changes ?? 0) > 0;
}

export async function completeTranslation(
  db: D1Database,
  id: number,
  translation: string,
  model: string,
  completedAt = new Date(),
): Promise<void> {
  const updated = await db
    .prepare(
      `UPDATE translation_entries
       SET machine_translation = ?1, status = 'pending', model = ?2,
           failure_reason = NULL, retry_after = NULL, updated_at = ?3
       WHERE id = ?4 AND status = 'generating'
       RETURNING id`,
    )
    .bind(translation, model, completedAt.toISOString(), id)
    .first<{ id: number }>();
  if (updated?.id !== id) {
    throw new Error("The translation generation lease is no longer active.");
  }
}

export async function failTranslation(
  db: D1Database,
  id: number,
  reason: string,
  retryAfter: Date,
  failedAt = new Date(),
  usageDate?: string,
): Promise<void> {
  const failedAtISO = failedAt.toISOString();
  const failureUpdate = db
    .prepare(
      `UPDATE translation_entries
       SET status = 'failed', failure_reason = ?1, retry_after = ?2,
           updated_at = ?3
       WHERE id = ?4 AND status = 'generating'
       RETURNING id`,
    )
    .bind(
      reason.slice(0, 500),
      retryAfter.toISOString(),
      failedAtISO,
      id,
    );

  if (!usageDate) {
    const updated = await failureUpdate.first<{ id: number }>();
    if (updated?.id !== id) {
      throw new Error("The translation generation lease is no longer active.");
    }
    return;
  }

  const results = await db.batch([
    failureUpdate,
    db
      .prepare(
        `UPDATE daily_usage
         SET ai_failures = ai_failures + 1
         WHERE usage_date = ?1
           AND EXISTS (
             SELECT 1
             FROM translation_entries
             WHERE id = ?2 AND status = 'failed' AND updated_at = ?3
           )`,
      )
      .bind(usageDate, id, failedAtISO),
  ]);

  const updated = results[0]?.results[0] as { id?: unknown } | undefined;
  if (updated?.id !== id) {
    throw new Error("The translation generation lease is no longer active.");
  }
}

import {
  authenticateAdminRequest,
  type AdminIdentity,
} from "./access.ts";
import { supportedTargetLocale } from "./contracts.ts";
import {
  normalizedSource,
  sha256,
  trimmedAndCollapsedSource,
} from "./normalization.ts";
import { buildMachineTranslationPlan } from "./machine-translation.ts";
import { handleReleaseRequest } from "./publisher.ts";

const allowedStatuses = new Set([
  "generating",
  "pending",
  "approved",
  "edited",
  "rejected",
  "failed",
  "auto-approved",
]);
const allowedPriorities = new Set(["high", "low"]);

type ReviewAction = "approve" | "edit" | "reject" | "defer";
type TranslationPriority = "high" | "low";
const maximumGlossaryMatches = 10_000;
const glossaryMatchBatchSize = 50;

interface ReviewBody {
  action: ReviewAction;
  translation?: string;
  deferUntil?: string;
  expectedUpdatedAt: string | null;
}

interface RestoreRevisionBody {
  expectedUpdatedAt: string | null;
}

interface PriorityBody {
  priority: TranslationPriority;
}

interface GlossaryEntryBody {
  source: string;
  translation: string;
}

interface PendingGlossaryMatch {
  id: number;
  source: string;
  normalized_source: string;
  machine_translation: string | null;
}

interface AdminTranslationRow {
  id: number;
  locale: string;
  source: string;
  normalized_source: string;
  kind: string;
  machine_translation: string | null;
  approved_translation: string | null;
  status: string;
  origin: string;
  seen_count: number;
  first_seen_at: string;
  last_seen_at: string;
  approved_at: string | null;
  approved_by: string | null;
  deferred_until: string | null;
  updated_at: string | null;
  priority: TranslationPriority;
  priority_updated_at: string | null;
  priority_updated_by: string | null;
  approval_method: "automatic" | "human" | null;
}

interface AdminRevisionRow {
  id: number;
  translation_entry_id: number;
  previous_status: string | null;
  new_status: string;
  previous_translation: string | null;
  new_translation: string | null;
  actor: string;
  created_at: string;
}

type ReviewBatchRow = AdminTranslationRow | AdminRevisionRow;

interface AIRetryStatusRow {
  id: number | null;
  requested_by: string | null;
  total_entries: number | null;
  remaining_entries: number | null;
  processing_entries: number | null;
  completed_entries: number | null;
  created_at: string | null;
  high_priority_entries: number | null;
  low_priority_entries: number | null;
  high_pending_review_entries: number | null;
  low_pending_review_entries: number | null;
  pending_processing_entries: number | null;
  active_processing_entries: number | null;
}

interface DailyAIUsageRow {
  usage_date: string;
  ai_requests: number;
  ai_characters: number;
  ai_failures: number;
}

interface SimilarApprovedRow {
  id: number;
  source: string;
  approved_translation: string;
  kind: string;
  reference_type: "text" | "same-kind";
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function positiveInteger(value: string | null, fallback: number, maximum: number): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isSafeInteger(parsed) && parsed > 0
    ? Math.min(parsed, maximum)
    : fallback;
}

function utcUsageDate(now: Date): string {
  return now.toISOString().slice(0, 10);
}

function nextUTCUsageReset(now: Date): string {
  const nextReset = new Date(now);
  nextReset.setUTCDate(nextReset.getUTCDate() + 1);
  nextReset.setUTCHours(0, 0, 0, 0);
  return nextReset.toISOString();
}

function nonNegativeInteger(value: number | null | undefined): number {
  return Number.isFinite(value)
    ? Math.max(0, Math.trunc(value ?? 0))
    : 0;
}

export function normalizeAIQueueCounts(
  row: Pick<
    AIRetryStatusRow,
    | "high_priority_entries"
    | "low_priority_entries"
    | "high_pending_review_entries"
    | "low_pending_review_entries"
    | "pending_processing_entries"
    | "active_processing_entries"
  > | null,
): {
  highPriority: number;
  lowPriority: number;
  highPendingReview: number;
  lowPendingReview: number;
  pendingProcessing: number;
  processing: number;
  total: number;
} {
  const highPriority = nonNegativeInteger(row?.high_priority_entries);
  const lowPriority = nonNegativeInteger(row?.low_priority_entries);
  return {
    highPriority,
    lowPriority,
    highPendingReview: nonNegativeInteger(row?.high_pending_review_entries),
    lowPendingReview: nonNegativeInteger(row?.low_pending_review_entries),
    pendingProcessing: nonNegativeInteger(row?.pending_processing_entries),
    processing: nonNegativeInteger(row?.active_processing_entries),
    total: highPriority + lowPriority,
  };
}

export function approvedSimilaritySearchQuery(source: string): string | null {
  const tokens = normalizedSource(source).match(/[\p{L}\p{N}]+/gu) ?? [];
  const uniqueTokens = [...new Set(tokens)]
    .filter((token) => token.length >= 2)
    .slice(0, 8);
  return uniqueTokens.length > 0
    ? uniqueTokens.map((token) => `"${token}"`).join(" OR ")
    : null;
}

export function validateGlossaryEntryBody(
  value: unknown,
): GlossaryEntryBody | string {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "Request body must be an object.";
  }
  const candidate = value as Record<string, unknown>;
  const source =
    typeof candidate.source === "string"
      ? trimmedAndCollapsedSource(candidate.source)
      : "";
  const translation =
    typeof candidate.translation === "string"
      ? trimmedAndCollapsedSource(candidate.translation)
      : "";

  if (
    source.length < 2 ||
    source.length > 160 ||
    !/[\p{L}\p{N}]/u.test(source)
  ) {
    return "source must contain 2–160 characters and include a letter or number.";
  }
  if (translation.length < 1 || translation.length > 500) {
    return "translation must contain 1–500 characters.";
  }
  return { source, translation };
}

export function sourceContainsGlossaryPhrase(
  source: string,
  phrase: string,
): boolean {
  return buildMachineTranslationPlan(source, [
    { source: phrase, translation: "__glossary_match__" },
  ]).some((segment) => segment.approvedTranslation !== undefined);
}

export function validatePriorityBody(value: unknown): PriorityBody | string {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "Request body must be an object.";
  }
  const priority = (value as Record<string, unknown>).priority;
  return priority === "high" || priority === "low"
    ? { priority }
    : "priority must be high or low.";
}

async function readDailyAIUsage(
  env: AdminEnv,
  now = new Date(),
): Promise<{
  usage: {
    date: string;
    requests: number;
    characters: number;
    failures: number;
    requestLimit: number;
    characterLimit: number;
    remainingRequests: number;
    remainingCharacters: number;
    deferredEntries: number;
    resetsAt: string;
  };
}> {
  const usageDate = utcUsageDate(now);
  const [usage, deferred] = await Promise.all([
    env.DB
      .prepare(
        `SELECT usage_date, ai_requests, ai_characters, ai_failures
         FROM daily_usage
         WHERE usage_date = ?1`,
      )
      .bind(usageDate)
      .first<DailyAIUsageRow>(),
    env.DB
      .prepare(
        `SELECT COUNT(*) AS count
         FROM translation_entries INDEXED BY translation_entries_budget_deferred
         WHERE locale = ?1
           AND status = 'failed'
           AND failure_reason = 'Daily AI budget exhausted.'`,
      )
      .bind(supportedTargetLocale)
      .first<{ count: number }>(),
  ]);
  const requests = Math.max(0, usage?.ai_requests ?? 0);
  const characters = Math.max(0, usage?.ai_characters ?? 0);
  const requestLimit = positiveInteger(
    env.DAILY_AI_REQUEST_LIMIT,
    1_000,
    1_000_000,
  );
  const characterLimit = positiveInteger(
    env.DAILY_AI_CHARACTER_LIMIT,
    100_000,
    10_000_000,
  );

  return {
    usage: {
      date: usageDate,
      requests,
      characters,
      failures: Math.max(0, usage?.ai_failures ?? 0),
      requestLimit,
      characterLimit,
      remainingRequests: Math.max(0, requestLimit - requests),
      remainingCharacters: Math.max(0, characterLimit - characters),
      deferredEntries: Math.max(0, deferred?.count ?? 0),
      resetsAt: nextUTCUsageReset(now),
    },
  };
}

async function resetDailyAIUsage(
  request: Request,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const requestURL = new URL(request.url);
  if (request.headers.get("origin") !== requestURL.origin) {
    return json({ error: "A same-origin request is required." }, 403);
  }

  const now = new Date();
  const timestamp = now.toISOString();
  const snapshot = await readDailyAIUsage(env, now);
  const current = snapshot.usage;
  const results = await env.DB.batch([
    env.DB
      .prepare(
        `INSERT INTO ai_limit_resets (
           usage_date, previous_ai_requests, previous_ai_characters,
           previous_ai_failures, resumed_entries, actor, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
      )
      .bind(
        current.date,
        current.requests,
        current.characters,
        current.failures,
        current.deferredEntries,
        identity.email,
        timestamp,
      ),
    env.DB
      .prepare(
        `INSERT INTO daily_usage (
           usage_date, ai_requests, ai_characters, ai_failures, cache_hits
         ) VALUES (?1, 0, 0, 0, 0)
         ON CONFLICT(usage_date) DO UPDATE SET
           ai_requests = 0,
           ai_characters = 0`,
      )
      .bind(current.date),
    env.DB
      .prepare(
        `UPDATE translation_entries INDEXED BY translation_entries_budget_deferred
         SET retry_after = ?1
         WHERE locale = ?2
           AND status = 'failed'
           AND failure_reason = 'Daily AI budget exhausted.'`,
      )
      .bind(timestamp, supportedTargetLocale),
  ]);
  const resumedEntries = results[2]?.meta.changes ?? 0;

  console.log(
    JSON.stringify({
      message: "Daily AI allowance reset by administrator.",
      actor: identity.email,
      usageDate: current.date,
      previousRequests: current.requests,
      previousCharacters: current.characters,
      resumedEntries,
    }),
  );

  return json({
    ...(await readDailyAIUsage(env, now)),
    resumedEntries,
  });
}

async function adminSummary(env: AdminEnv): Promise<Response> {
  const [countRows, state, release] = await Promise.all([
    env.DB
      .prepare(
        `SELECT dimension, value, entry_count
         FROM translation_summary_counts
         WHERE locale = ?1 AND entry_count > 0
         ORDER BY dimension, value COLLATE NOCASE`,
      )
      .bind(supportedTargetLocale)
      .all<{
        dimension: "status" | "kind";
        value: string;
        entry_count: number;
      }>(),
    env.DB
      .prepare(
        `SELECT locale, is_dirty, changed_at, changed_by
         FROM dictionary_state
         WHERE locale = ?1`,
      )
      .bind(supportedTargetLocale)
      .first<{
        locale: string;
        is_dirty: number;
        changed_at: string | null;
        changed_by: string | null;
      }>(),
    env.DB
      .prepare(
        `SELECT version, entry_count, checksum, published_at
         FROM dictionary_releases
         WHERE locale = ?1 AND status = 'current'
         LIMIT 1`,
      )
      .bind(supportedTargetLocale)
      .first<{
        version: number;
        entry_count: number;
        checksum: string;
        published_at: string | null;
      }>(),
  ]);
  const counts = countRows.results ?? [];
  const statusRows = counts
    .filter((row) => row.dimension === "status")
    .map((row) => ({ status: row.value, count: row.entry_count }));
  const kindRows = counts
    .filter((row) => row.dimension === "kind")
    .map((row) => ({ kind: row.value, count: row.entry_count }));

  return json({
    locale: supportedTargetLocale,
    statuses: statusRows,
    kinds: kindRows,
    dictionary: state
      ? {
          dirty: state.is_dirty === 1,
          changedAt: state.changed_at,
          changedBy: state.changed_by,
        }
      : null,
    currentRelease: release,
  });
}

async function aiRetryStatus(env: AdminEnv): Promise<Response> {
  const status = await env.DB
    .prepare(
      `WITH queue_counts AS (
         SELECT
           (
             SELECT COUNT(*)
             FROM translation_entries
               INDEXED BY translation_entries_retry_failed_ready
             WHERE locale = ?1
               AND priority = 'high'
               AND retry_job_id IS NOT NULL
               AND status = 'failed'
           ) + (
             SELECT COUNT(*)
             FROM translation_entries
               INDEXED BY translation_entries_retry_generating_stale
             WHERE locale = ?1
               AND priority = 'high'
               AND retry_job_id IS NOT NULL
               AND status = 'generating'
           ) AS high_priority_entries,
           (
             SELECT COUNT(*)
             FROM translation_entries
               INDEXED BY translation_entries_retry_failed_ready
             WHERE locale = ?1
               AND priority = 'low'
               AND retry_job_id IS NOT NULL
               AND status = 'failed'
           ) + (
             SELECT COUNT(*)
             FROM translation_entries
               INDEXED BY translation_entries_retry_generating_stale
             WHERE locale = ?1
               AND priority = 'low'
               AND retry_job_id IS NOT NULL
               AND status = 'generating'
           ) AS low_priority_entries,
           COALESCE((
             SELECT entry_count
             FROM translation_priority_status_counts
             WHERE locale = ?1
               AND priority = 'high'
               AND status = 'pending'
           ), 0) AS high_pending_review_entries,
           COALESCE((
             SELECT entry_count
             FROM translation_priority_status_counts
             WHERE locale = ?1
               AND priority = 'low'
               AND status = 'pending'
           ), 0) AS low_pending_review_entries,
           (
             SELECT COUNT(*)
             FROM translation_entries
               INDEXED BY translation_entries_retry_failed_ready
             WHERE locale = ?1
               AND retry_job_id IS NOT NULL
               AND status = 'failed'
           ) AS pending_processing_entries,
           (
             SELECT COUNT(*)
             FROM translation_entries
               INDEXED BY translation_entries_retry_generating_stale
             WHERE locale = ?1
               AND retry_job_id IS NOT NULL
               AND status = 'generating'
           ) AS active_processing_entries
       ),
       latest_job AS (
         SELECT id, requested_by, total_entries, remaining_entries,
                processing_entries, completed_entries, created_at
         FROM ai_retry_jobs
         WHERE locale = ?1
         ORDER BY id DESC
         LIMIT 1
       )
       SELECT latest_job.id, latest_job.requested_by,
              latest_job.total_entries, latest_job.remaining_entries,
              latest_job.processing_entries, latest_job.completed_entries,
              latest_job.created_at, queue_counts.high_priority_entries,
              queue_counts.low_priority_entries,
              queue_counts.high_pending_review_entries,
              queue_counts.low_pending_review_entries,
              queue_counts.pending_processing_entries,
              queue_counts.active_processing_entries
       FROM queue_counts
       LEFT JOIN latest_job ON 1 = 1`,
    )
    .bind(supportedTargetLocale)
    .first<AIRetryStatusRow>();

  const queue = normalizeAIQueueCounts(status);

  if (!status?.id) {
    return json({ job: null, queue });
  }

  const remaining = nonNegativeInteger(status.remaining_entries);
  const processing = nonNegativeInteger(status.processing_entries);

  return json({
    job: {
      id: status.id,
      requestedBy: status.requested_by,
      createdAt: status.created_at,
      total: nonNegativeInteger(status.total_entries),
      completed: nonNegativeInteger(status.completed_entries),
      remaining,
      processing,
      pending: Math.max(0, remaining - processing),
    },
    queue,
  });
}

async function retryFailedTranslations(
  request: Request,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const requestURL = new URL(request.url);
  if (request.headers.get("origin") !== requestURL.origin) {
    return json({ error: "A same-origin request is required." }, 403);
  }

  const failed = await env.DB
    .prepare(
      `SELECT COUNT(*) AS count
       FROM translation_entries
       WHERE locale = ?1 AND status = 'failed'`,
    )
    .bind(supportedTargetLocale)
    .first<{ count: number }>();
  const failedCount = failed?.count ?? 0;
  if (failedCount === 0) {
    return aiRetryStatus(env);
  }

  const timestamp = new Date().toISOString();
  const job = await env.DB
    .prepare(
      `INSERT INTO ai_retry_jobs (
         locale, requested_by, total_entries, remaining_entries,
         processing_entries, completed_entries, created_at
       ) VALUES (?1, ?2, ?3, ?3, 0, 0, ?4)
       RETURNING id`,
    )
    .bind(supportedTargetLocale, identity.email, failedCount, timestamp)
    .first<{ id: number }>();
  if (!job) {
    return json({ error: "The retry job could not be created." }, 500);
  }

  const queued = await env.DB
    .prepare(
      `UPDATE translation_entries
       SET retry_job_id = ?1,
           retry_after = ?2,
           updated_at = ?2
       WHERE locale = ?3 AND status = 'failed'`,
    )
    .bind(job.id, timestamp, supportedTargetLocale)
    .run();
  const queuedCount = queued.meta?.changes ?? 0;

  if (queuedCount !== failedCount) {
    await env.DB
      .prepare(
        `UPDATE ai_retry_jobs
         SET total_entries = ?1,
             remaining_entries = ?1
         WHERE id = ?2`,
      )
      .bind(queuedCount, job.id)
      .run();
  }

  return aiRetryStatus(env);
}

async function pendingGlossaryMatches(
  source: string,
  env: AdminEnv,
): Promise<PendingGlossaryMatch[] | string> {
  const normalized = normalizedSource(source);
  const candidates = await env.DB
    .prepare(
      `SELECT id, source, normalized_source, machine_translation
       FROM translation_entries
       WHERE locale = ?1
         AND status = 'pending'
         AND instr(normalized_source, ?2) > 0
       ORDER BY id
       LIMIT ?3`,
    )
    .bind(
      supportedTargetLocale,
      normalized,
      maximumGlossaryMatches + 1,
    )
    .all<PendingGlossaryMatch>();

  if (candidates.results.length > maximumGlossaryMatches) {
    return "This phrase matches too many pending entries. Use a more specific phrase.";
  }
  return candidates.results.filter(
    (candidate) =>
      candidate.normalized_source !== normalized &&
      sourceContainsGlossaryPhrase(candidate.source, source),
  );
}

async function glossaryPreview(
  request: Request,
  env: AdminEnv,
): Promise<Response> {
  const source = new URL(request.url).searchParams.get("source") ?? "";
  const validation = validateGlossaryEntryBody({
    source,
    translation: "preview",
  });
  if (typeof validation === "string") {
    return json({ error: validation }, 400);
  }

  const matches = await pendingGlossaryMatches(validation.source, env);
  if (typeof matches === "string") {
    return json({ error: matches }, 409);
  }
  return json({
    matchCount: matches.length,
    examples: matches.slice(0, 3).map((match) => ({
      id: match.id,
      source: match.source,
      machineTranslation: match.machine_translation,
    })),
  });
}

async function saveGlossaryEntry(
  body: GlossaryEntryBody,
  identity: AdminIdentity,
  env: AdminEnv,
  timestamp: string,
): Promise<{
  id: number;
  source: string;
  translation: string;
  status: string;
}> {
  const normalized = normalizedSource(body.source);
  const sourceHash = await sha256(
    `${supportedTargetLocale}\n${normalized}`,
  );
  const current = await env.DB
    .prepare(
      `SELECT id, status, machine_translation, approved_translation
       FROM translation_entries
       WHERE locale = ?1 AND normalized_source = ?2`,
    )
    .bind(supportedTargetLocale, normalized)
    .first<{
      id: number;
      status: string;
      machine_translation: string | null;
      approved_translation: string | null;
    }>();
  const previousTranslation =
    current?.approved_translation ?? current?.machine_translation ?? null;

  const results = await env.DB.batch([
    env.DB
      .prepare(
        `INSERT INTO translation_entries (
           locale, normalized_source, source_hash, source, kind,
           approved_translation, status, first_seen_at, last_seen_at,
           approved_at, approved_by, origin, updated_at, approval_method
         ) VALUES (
           ?1, ?2, ?3, ?4, 'keyword',
           ?5, 'edited', ?6, ?6,
           ?6, ?7, 'human', ?6, 'human'
         )
         ON CONFLICT(locale, normalized_source) DO UPDATE SET
           source = excluded.source,
           approved_translation = excluded.approved_translation,
           status = 'edited',
           approved_at = excluded.approved_at,
           approved_by = excluded.approved_by,
           origin = 'human',
           approval_method = 'human',
           deferred_until = NULL,
           failure_reason = NULL,
           retry_after = NULL,
           retry_job_id = NULL,
           updated_at = excluded.updated_at
         RETURNING id, source, approved_translation, status`,
      )
      .bind(
        supportedTargetLocale,
        normalized,
        sourceHash,
        body.source,
        body.translation,
        timestamp,
        identity.email,
      ),
    env.DB
      .prepare(
        `INSERT INTO translation_revisions (
           translation_entry_id, previous_status, new_status,
           previous_translation, new_translation, actor, created_at
         )
         SELECT id, ?1, 'edited', ?2, approved_translation, ?3, ?4
         FROM translation_entries
         WHERE locale = ?5
           AND normalized_source = ?6
           AND updated_at = ?4`,
      )
      .bind(
        current?.status ?? null,
        previousTranslation,
        identity.email,
        timestamp,
        supportedTargetLocale,
        normalized,
      ),
    env.DB
      .prepare(
        `UPDATE dictionary_state
         SET is_dirty = 1, changed_at = ?1, changed_by = ?2
         WHERE locale = ?3
           AND EXISTS (
             SELECT 1
             FROM translation_entries
             WHERE locale = ?3
               AND normalized_source = ?4
               AND updated_at = ?1
           )`,
      )
      .bind(
        timestamp,
        identity.email,
        supportedTargetLocale,
        normalized,
      ),
  ]);

  const row = results[0]?.results[0] as
    | {
        id?: unknown;
        source?: unknown;
        approved_translation?: unknown;
        status?: unknown;
      }
    | undefined;
  if (
    typeof row?.id !== "number" ||
    typeof row.source !== "string" ||
    typeof row.approved_translation !== "string" ||
    typeof row.status !== "string"
  ) {
    throw new Error("The dictionary entry could not be returned after saving.");
  }
  return {
    id: row.id,
    source: row.source,
    translation: row.approved_translation,
    status: row.status,
  };
}

async function queueGlossaryRefresh(
  matches: PendingGlossaryMatch[],
  source: string,
  identity: AdminIdentity,
  env: AdminEnv,
  timestamp: string,
): Promise<{ jobID: number | null; queued: number }> {
  if (matches.length === 0) {
    return { jobID: null, queued: 0 };
  }

  const job = await env.DB
    .prepare(
      `INSERT INTO ai_retry_jobs (
         locale, requested_by, total_entries, remaining_entries,
         processing_entries, completed_entries, created_at
       ) VALUES (?1, ?2, ?3, ?3, 0, 0, ?4)
       RETURNING id`,
    )
    .bind(
      supportedTargetLocale,
      identity.email,
      matches.length,
      timestamp,
    )
    .first<{ id: number }>();
  if (!job) {
    throw new Error("The glossary refresh job could not be created.");
  }

  const reason =
    `Dictionary phrase "${source}" changed; queued for glossary reapplication.`;
  const statements: D1PreparedStatement[] = [];
  for (
    let offset = 0;
    offset < matches.length;
    offset += glossaryMatchBatchSize
  ) {
    const ids = matches
      .slice(offset, offset + glossaryMatchBatchSize)
      .map((match) => match.id);
    const placeholders = ids.map(() => "?").join(", ");
    statements.push(
      env.DB
        .prepare(
          `UPDATE translation_entries
           SET status = 'failed',
               failure_reason = ?,
               retry_after = ?,
               retry_job_id = ?,
               updated_at = ?
           WHERE id IN (${placeholders})
             AND locale = ?
             AND status = 'pending'
           RETURNING id`,
        )
        .bind(
          reason.slice(0, 500),
          timestamp,
          job.id,
          timestamp,
          ...ids,
          supportedTargetLocale,
        ),
    );
  }

  const results = await env.DB.batch(statements);
  const queued = results.reduce(
    (total, result) => total + result.results.length,
    0,
  );
  if (queued !== matches.length) {
    await env.DB
      .prepare(
        `UPDATE ai_retry_jobs
         SET total_entries = ?1,
             remaining_entries = ?1
         WHERE id = ?2`,
      )
      .bind(queued, job.id)
      .run();
  }
  if (queued === 0) {
    await env.DB
      .prepare(`DELETE FROM ai_retry_jobs WHERE id = ?1`)
      .bind(job.id)
      .run();
    return { jobID: null, queued: 0 };
  }
  return { jobID: job.id, queued };
}

async function addGlossaryEntry(
  request: Request,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const requestURL = new URL(request.url);
  if (request.headers.get("origin") !== requestURL.origin) {
    return json({ error: "A same-origin request is required." }, 403);
  }
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    return json({ error: "Content-Type must be application/json." }, 415);
  }

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return json({ error: "Request body must be valid JSON." }, 400);
  }
  const body = validateGlossaryEntryBody(rawBody);
  if (typeof body === "string") {
    return json({ error: body }, 400);
  }

  const timestamp = new Date().toISOString();
  const matches = await pendingGlossaryMatches(body.source, env);
  if (typeof matches === "string") {
    return json({ error: matches }, 409);
  }
  const entry = await saveGlossaryEntry(
    body,
    identity,
    env,
    timestamp,
  );
  const refresh = await queueGlossaryRefresh(
    matches,
    body.source,
    identity,
    env,
    timestamp,
  );
  return json({
    entry,
    matchedPending: matches.length,
    queuedPending: refresh.queued,
    retryJobID: refresh.jobID,
  }, 201);
}

async function listTranslations(request: Request, env: AdminEnv): Promise<Response> {
  const url = new URL(request.url);
  const status = url.searchParams.get("status");
  const databaseStatus = status === "auto-approved" ? "approved" : status;
  const automaticApprovalOnly = status === "auto-approved";
  const kind = url.searchParams.get("kind")?.trim() || null;
  const priority = url.searchParams.get("priority")?.trim() || null;
  const query = url.searchParams.get("q")?.trim() || null;
  const cursor = positiveInteger(url.searchParams.get("cursor"), Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
  const limit = positiveInteger(url.searchParams.get("limit"), 50, 100);

  if (status && !allowedStatuses.has(status)) {
    return json({ error: "Unsupported status filter." }, 400);
  }
  if (kind && kind.length > 64) {
    return json({ error: "kind must contain at most 64 characters." }, 400);
  }
  if (priority && !allowedPriorities.has(priority)) {
    return json({ error: "Unsupported priority filter." }, 400);
  }
  if (query && query.length > 100) {
    return json({ error: "q must contain at most 100 characters." }, 400);
  }

  const rows = await env.DB
    .prepare(
      `SELECT id, locale, source, normalized_source, kind, machine_translation,
              approved_translation, status, origin, seen_count, first_seen_at,
              last_seen_at, approved_at, approved_by, deferred_until, updated_at,
              priority, priority_updated_at, priority_updated_by,
              approval_method
       FROM translation_entries
       WHERE locale = ?1
         AND id < ?2
         AND (?3 IS NULL OR status = ?3)
         AND (?4 = 0 OR approval_method = 'automatic')
         AND (?5 IS NULL OR kind = ?5)
         AND (?6 IS NULL OR priority = ?6)
         AND (
           ?7 IS NULL
           OR source LIKE '%' || ?7 || '%' COLLATE NOCASE
           OR machine_translation LIKE '%' || ?7 || '%'
           OR approved_translation LIKE '%' || ?7 || '%'
         )
       ORDER BY id DESC
       LIMIT ?8`,
    )
    .bind(
      supportedTargetLocale,
      cursor,
      databaseStatus,
      automaticApprovalOnly ? 1 : 0,
      kind,
      priority,
      query,
      limit + 1,
    )
    .all<AdminTranslationRow>();

  const values = rows.results ?? [];
  const hasMore = values.length > limit;
  const translations = hasMore ? values.slice(0, limit) : values;
  return json({
    translations,
    nextCursor: hasMore ? translations.at(-1)?.id ?? null : null,
  });
}

async function translationDetail(id: number, env: AdminEnv): Promise<Response> {
  const entry = await env.DB
    .prepare(
      `SELECT id, locale, source, normalized_source, kind, machine_translation,
              approved_translation, status, origin, seen_count, first_seen_at,
              last_seen_at, approved_at, approved_by, deferred_until, updated_at,
              priority, priority_updated_at, priority_updated_by,
              approval_method
       FROM translation_entries
       WHERE id = ?1 AND locale = ?2`,
    )
    .bind(id, supportedTargetLocale)
    .first<AdminTranslationRow>();

  if (!entry) {
    return json({ error: "Translation entry not found." }, 404);
  }

  const searchQuery = approvedSimilaritySearchQuery(entry.normalized_source);
  const statements = [
    env.DB
      .prepare(
        `SELECT id, alias, normalized_alias
         FROM translation_aliases
         WHERE translation_entry_id = ?1
         ORDER BY alias COLLATE NOCASE`,
      )
      .bind(id),
    env.DB
      .prepare(
        `SELECT id, previous_status, new_status, previous_translation,
                new_translation, actor, created_at
         FROM translation_revisions
         WHERE translation_entry_id = ?1
         ORDER BY id DESC
         LIMIT 100`,
      )
      .bind(id),
  ];
  if (searchQuery) {
    statements.push(
      env.DB
        .prepare(
          `SELECT CAST(entry_id AS INTEGER) AS id,
                  source,
                  approved_translation,
                  kind,
                  'text' AS reference_type
           FROM approved_translation_search
           WHERE approved_translation_search MATCH ?1
             AND entry_id <> ?2
           ORDER BY bm25(approved_translation_search)
           LIMIT 2`,
        )
        .bind(searchQuery, id),
    );
  }
  const [aliases, revisions, textMatches] =
    await env.DB.batch<SimilarApprovedRow>(statements);
  const similar = textMatches?.results ?? [];

  if (similar.length < 2) {
    const fallback = await env.DB
      .prepare(
        `SELECT id, source, approved_translation, kind,
                'same-kind' AS reference_type
         FROM translation_entries
         WHERE locale = ?1
           AND kind = ?2
           AND id <> ?3
           AND id <> COALESCE(?4, -1)
           AND id <> COALESCE(?5, -1)
           AND status IN ('approved', 'edited')
           AND approved_translation IS NOT NULL
         ORDER BY approved_at DESC, id DESC
         LIMIT ?6`,
      )
      .bind(
        supportedTargetLocale,
        entry.kind,
        id,
        similar[0]?.id ?? null,
        similar[1]?.id ?? null,
        2 - similar.length,
      )
      .all<SimilarApprovedRow>();
    similar.push(...(fallback.results ?? []));
  }

  return json({
    translation: entry,
    aliases: aliases.results ?? [],
    revisions: revisions.results ?? [],
    similar,
  });
}

async function updateTranslationPriority(
  request: Request,
  id: number,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const requestURL = new URL(request.url);
  if (request.headers.get("origin") !== requestURL.origin) {
    return json({ error: "A same-origin request is required." }, 403);
  }
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    return json({ error: "Content-Type must be application/json." }, 415);
  }

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return json({ error: "Request body must be valid JSON." }, 400);
  }
  const body = validatePriorityBody(rawBody);
  if (typeof body === "string") {
    return json({ error: body }, 400);
  }

  const timestamp = new Date().toISOString();
  const translation = await env.DB
    .prepare(
      `UPDATE translation_entries
       SET priority = ?1,
           priority_updated_at = ?2,
           priority_updated_by = ?3
       WHERE id = ?4 AND locale = ?5
       RETURNING id, locale, source, normalized_source, kind,
                 machine_translation, approved_translation, status, origin,
                 seen_count, first_seen_at, last_seen_at, approved_at,
                 approved_by, deferred_until, updated_at, priority,
                 priority_updated_at, priority_updated_by, approval_method`,
    )
    .bind(
      body.priority,
      timestamp,
      identity.email,
      id,
      supportedTargetLocale,
    )
    .first<AdminTranslationRow>();

  if (!translation) {
    return json({ error: "Translation entry not found." }, 404);
  }
  console.log(
    JSON.stringify({
      message: "Translation priority changed.",
      entryID: id,
      priority: body.priority,
      actor: identity.email,
    }),
  );
  return json({ translation });
}

function validateReviewBody(value: unknown, now: Date): ReviewBody | string {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "Request body must be an object.";
  }
  const candidate = value as Record<string, unknown>;
  if (
    candidate.action !== "approve" &&
    candidate.action !== "edit" &&
    candidate.action !== "reject" &&
    candidate.action !== "defer"
  ) {
    return "Unsupported review action.";
  }
  if (
    candidate.expectedUpdatedAt !== null &&
    (typeof candidate.expectedUpdatedAt !== "string" ||
      Number.isNaN(Date.parse(candidate.expectedUpdatedAt)))
  ) {
    return "expectedUpdatedAt must be an ISO-8601 timestamp or null.";
  }
  const expectedUpdatedAt = candidate.expectedUpdatedAt as string | null;

  if (candidate.action === "edit") {
    if (typeof candidate.translation !== "string") {
      return "translation is required for edit.";
    }
    const translation = trimmedAndCollapsedSource(candidate.translation);
    if (!translation || translation.length > 500) {
      return "translation must contain 1–500 characters.";
    }
    return { action: "edit", translation, expectedUpdatedAt };
  }

  if (candidate.action === "defer") {
    if (
      typeof candidate.deferUntil !== "string" ||
      Number.isNaN(Date.parse(candidate.deferUntil)) ||
      Date.parse(candidate.deferUntil) <= now.getTime()
    ) {
      return "deferUntil must be a future ISO-8601 timestamp.";
    }
    return {
      action: "defer",
      deferUntil: new Date(candidate.deferUntil).toISOString(),
      expectedUpdatedAt,
    };
  }

  return { action: candidate.action, expectedUpdatedAt };
}

export function validateRestoreRevisionBody(
  value: unknown,
): RestoreRevisionBody | string {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return "Request body must be an object.";
  }
  const candidate = value as Record<string, unknown>;
  if (
    candidate.expectedUpdatedAt !== null &&
    (typeof candidate.expectedUpdatedAt !== "string" ||
      Number.isNaN(Date.parse(candidate.expectedUpdatedAt)))
  ) {
    return "expectedUpdatedAt must be an ISO-8601 timestamp or null.";
  }
  return {
    expectedUpdatedAt: candidate.expectedUpdatedAt as string | null,
  };
}

async function restoreRevision(
  request: Request,
  id: number,
  revisionID: number,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const requestURL = new URL(request.url);
  if (request.headers.get("origin") !== requestURL.origin) {
    return json({ error: "A same-origin request is required." }, 403);
  }
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    return json({ error: "Content-Type must be application/json." }, 415);
  }

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return json({ error: "Request body must be valid JSON." }, 400);
  }
  const body = validateRestoreRevisionBody(rawBody);
  if (typeof body === "string") {
    return json({ error: body }, 400);
  }

  const [current, revision] = await Promise.all([
    env.DB
      .prepare(
        `SELECT id, status, machine_translation, approved_translation, updated_at
         FROM translation_entries
         WHERE id = ?1 AND locale = ?2`,
      )
      .bind(id, supportedTargetLocale)
      .first<{
        id: number;
        status: string;
        machine_translation: string | null;
        approved_translation: string | null;
        updated_at: string | null;
      }>(),
    env.DB
      .prepare(
        `SELECT id, previous_status, previous_translation
         FROM translation_revisions
         WHERE id = ?1 AND translation_entry_id = ?2`,
      )
      .bind(revisionID, id)
      .first<{
        id: number;
        previous_status: string | null;
        previous_translation: string | null;
      }>(),
  ]);

  if (!current) {
    return json({ error: "Translation entry not found." }, 404);
  }
  if (current.updated_at !== body.expectedUpdatedAt) {
    return json(
      { error: "This translation changed after it was loaded. Refresh and try again." },
      409,
    );
  }
  if (!revision) {
    return json({ error: "Translation revision not found." }, 404);
  }

  const restoredTranslation = revision.previous_translation
    ? trimmedAndCollapsedSource(revision.previous_translation)
    : "";
  if (!restoredTranslation || restoredTranslation.length > 500) {
    return json({ error: "This revision has no restorable translation." }, 409);
  }
  if (
    (current.status === "approved" || current.status === "edited") &&
    current.approved_translation === restoredTranslation
  ) {
    return json({ error: "This revision is already the current translation." }, 409);
  }

  const timestamp = new Date().toISOString();
  const previousTranslation =
    current.approved_translation ?? current.machine_translation;
  const results = await env.DB.batch<ReviewBatchRow>([
    env.DB
      .prepare(
        `UPDATE translation_entries
         SET status = 'edited',
             approved_translation = ?1,
             approved_at = ?2,
             approved_by = ?3,
             origin = 'human',
             approval_method = 'human',
             deferred_until = NULL,
             updated_at = ?2
         WHERE id = ?4
           AND locale = ?5
           AND (
             updated_at = ?6
             OR (updated_at IS NULL AND ?6 IS NULL)
           )
         RETURNING id, locale, source, normalized_source, kind,
                   machine_translation, approved_translation, status, origin,
                   seen_count, first_seen_at, last_seen_at, approved_at,
                   approved_by, deferred_until, updated_at, priority,
                   priority_updated_at, priority_updated_by, approval_method`,
      )
      .bind(
        restoredTranslation,
        timestamp,
        identity.email,
        id,
        supportedTargetLocale,
        body.expectedUpdatedAt,
      ),
    env.DB
      .prepare(
        `INSERT INTO translation_revisions (
          translation_entry_id, previous_status, new_status,
          previous_translation, new_translation, actor, created_at
        )
        SELECT ?1, ?2, 'edited', ?3, ?4, ?5, ?6
        WHERE EXISTS (
          SELECT 1 FROM translation_entries
          WHERE id = ?1 AND locale = ?7 AND updated_at = ?6
        )
        RETURNING id, translation_entry_id, previous_status, new_status,
                  previous_translation, new_translation, actor, created_at`,
      )
      .bind(
        id,
        current.status,
        previousTranslation,
        restoredTranslation,
        identity.email,
        timestamp,
        supportedTargetLocale,
      ),
    env.DB
      .prepare(
        `UPDATE dictionary_state
         SET is_dirty = 1, changed_at = ?1, changed_by = ?2
         WHERE locale = ?3
           AND EXISTS (
             SELECT 1 FROM translation_entries
             WHERE id = ?4 AND locale = ?3 AND updated_at = ?1
           )`,
      )
      .bind(timestamp, identity.email, supportedTargetLocale, id),
  ]);

  if ((results[0]?.meta.changes ?? 0) !== 1) {
    return json(
      { error: "This translation changed during restoration. Refresh and try again." },
      409,
    );
  }
  const translation = results[0]?.results[0];
  const recordedRevision = results[1]?.results[0];
  if (!translation || !("locale" in translation)) {
    return json({ error: "The restored translation could not be returned." }, 500);
  }
  return json({
    translation,
    revision:
      recordedRevision && "translation_entry_id" in recordedRevision
        ? recordedRevision
        : null,
  });
}

async function reviewTranslation(
  request: Request,
  id: number,
  identity: AdminIdentity,
  env: AdminEnv,
): Promise<Response> {
  const requestURL = new URL(request.url);
  if (request.headers.get("origin") !== requestURL.origin) {
    return json({ error: "A same-origin request is required." }, 403);
  }

  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    return json({ error: "Content-Type must be application/json." }, 415);
  }

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return json({ error: "Request body must be valid JSON." }, 400);
  }

  const now = new Date();
  const body = validateReviewBody(rawBody, now);
  if (typeof body === "string") {
    return json({ error: body }, 400);
  }

  const current = await env.DB
    .prepare(
      `SELECT id, status, machine_translation, approved_translation, origin,
              updated_at
       FROM translation_entries
       WHERE id = ?1 AND locale = ?2`,
    )
    .bind(id, supportedTargetLocale)
    .first<{
      id: number;
      status: string;
      machine_translation: string | null;
      approved_translation: string | null;
      origin: string;
      updated_at: string | null;
    }>();

  if (!current) {
    return json({ error: "Translation entry not found." }, 404);
  }
  if (current.updated_at !== body.expectedUpdatedAt) {
    return json(
      {
        error: "This translation changed after it was loaded. Refresh and review it again.",
      },
      409,
    );
  }

  const previousTranslation =
    current.approved_translation ?? current.machine_translation;
  let newStatus: string;
  let newTranslation: string | null;
  let deferredUntil: string | null = null;
  let marksDictionaryDirty = false;

  switch (body.action) {
    case "approve":
      if (!previousTranslation) {
        return json({ error: "Entry has no translation to approve." }, 409);
      }
      newStatus = "approved";
      newTranslation = previousTranslation;
      marksDictionaryDirty = true;
      break;
    case "edit":
      newStatus = "edited";
      newTranslation = body.translation ?? null;
      marksDictionaryDirty = true;
      break;
    case "reject":
      newStatus = "rejected";
      newTranslation = null;
      marksDictionaryDirty = current.approved_translation !== null;
      break;
    case "defer":
      newStatus = "pending";
      newTranslation = current.approved_translation;
      deferredUntil = body.deferUntil ?? null;
      break;
  }

  const timestamp = now.toISOString();
  const statements: D1PreparedStatement[] = [
    env.DB
      .prepare(
        `UPDATE translation_entries
         SET status = ?1,
             approved_translation = ?2,
             approved_at = CASE WHEN ?1 IN ('approved', 'edited') THEN ?3 ELSE NULL END,
             approved_by = CASE WHEN ?1 IN ('approved', 'edited') THEN ?4 ELSE NULL END,
             origin = CASE WHEN ?1 = 'edited' THEN 'human' ELSE origin END,
             approval_method = CASE
               WHEN ?1 IN ('approved', 'edited') THEN 'human'
               ELSE NULL
             END,
             deferred_until = ?5,
             updated_at = ?3
         WHERE id = ?6
           AND locale = ?7
           AND (
             updated_at = ?8
             OR (updated_at IS NULL AND ?8 IS NULL)
           )
         RETURNING id, locale, source, normalized_source, kind,
                   machine_translation, approved_translation, status, origin,
                   seen_count, first_seen_at, last_seen_at, approved_at,
                   approved_by, deferred_until, updated_at, priority,
                   priority_updated_at, priority_updated_by, approval_method`,
      )
      .bind(
        newStatus,
        newTranslation,
        timestamp,
        identity.email,
        deferredUntil,
        id,
        supportedTargetLocale,
        body.expectedUpdatedAt,
      ),
    env.DB
      .prepare(
        `INSERT INTO translation_revisions (
          translation_entry_id, previous_status, new_status,
          previous_translation, new_translation, actor, created_at
        )
        SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7
        WHERE EXISTS (
          SELECT 1 FROM translation_entries
          WHERE id = ?1 AND locale = ?8 AND updated_at = ?7
        )
        RETURNING id, translation_entry_id, previous_status, new_status,
                  previous_translation, new_translation, actor, created_at`,
      )
      .bind(
        id,
        current.status,
        newStatus,
        previousTranslation,
        newTranslation,
        identity.email,
        timestamp,
        supportedTargetLocale,
      ),
  ];

  if (marksDictionaryDirty) {
    statements.push(
      env.DB
        .prepare(
          `UPDATE dictionary_state
           SET is_dirty = 1, changed_at = ?1, changed_by = ?2
           WHERE locale = ?3
             AND EXISTS (
               SELECT 1 FROM translation_entries
               WHERE id = ?4 AND locale = ?3 AND updated_at = ?1
             )`,
        )
        .bind(timestamp, identity.email, supportedTargetLocale, id),
    );
  }

  const results = await env.DB.batch<ReviewBatchRow>(statements);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    return json(
      {
        error: "This translation changed during review. Refresh and review it again.",
      },
      409,
    );
  }
  const translation = results[0]?.results[0];
  const recordedRevision = results[1]?.results[0];
  if (!translation || !("locale" in translation)) {
    return json({ error: "The reviewed translation could not be returned." }, 500);
  }
  return json({
    translation,
    revision:
      recordedRevision && "translation_entry_id" in recordedRevision
        ? recordedRevision
        : null,
  });
}

function secureAdminAsset(response: Response): Response {
  const secured = new Response(response.body, response);
  secured.headers.set("cache-control", "private, no-store");
  secured.headers.set(
    "content-security-policy",
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  );
  secured.headers.set("referrer-policy", "no-referrer");
  secured.headers.set("x-content-type-options", "nosniff");
  secured.headers.set(
    "permissions-policy",
    "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
  );
  return secured;
}

async function adminAsset(request: Request, env: AdminEnv): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/admin") {
    url.pathname = "/admin/";
    return Response.redirect(url.toString(), 308);
  }
  if (url.pathname === "/admin/") {
    url.pathname = "/admin/index.html";
  }
  const assetRequest = new Request(url.toString(), request);
  return secureAdminAsset(await env.ASSETS.fetch(assetRequest));
}

export async function handleAdminRequest(
  request: Request,
  env: AdminEnv,
): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname !== "/admin" && !url.pathname.startsWith("/admin/")) {
    return null;
  }

  const authentication = await authenticateAdminRequest(request, env);
  if (authentication.response) {
    return authentication.response;
  }
  const identity = authentication.identity;

  const releaseResponse = await handleReleaseRequest(request, identity, env);
  if (releaseResponse) {
    return releaseResponse;
  }

  if (
    request.method === "GET" &&
    url.pathname === "/admin/api/session"
  ) {
    return json({ email: identity.email });
  }
  if (
    request.method === "GET" &&
    url.pathname === "/admin/api/summary"
  ) {
    return adminSummary(env);
  }
  if (
    request.method === "GET" &&
    url.pathname === "/admin/api/ai-retries"
  ) {
    return aiRetryStatus(env);
  }
  if (
    request.method === "POST" &&
    url.pathname === "/admin/api/ai-retries"
  ) {
    return retryFailedTranslations(request, identity, env);
  }
  if (
    request.method === "GET" &&
    url.pathname === "/admin/api/ai-usage"
  ) {
    return json(await readDailyAIUsage(env));
  }
  if (
    request.method === "POST" &&
    url.pathname === "/admin/api/ai-usage/reset"
  ) {
    return resetDailyAIUsage(request, identity, env);
  }
  if (
    request.method === "GET" &&
    url.pathname === "/admin/api/glossary/preview"
  ) {
    return glossaryPreview(request, env);
  }
  if (
    request.method === "POST" &&
    url.pathname === "/admin/api/glossary"
  ) {
    return addGlossaryEntry(request, identity, env);
  }

  if (
    request.method === "GET" &&
    url.pathname === "/admin/api/translations"
  ) {
    return listTranslations(request, env);
  }

  if (url.pathname.startsWith("/admin/api/")) {
    const priorityMatch = url.pathname.match(
      /^\/admin\/api\/translations\/(\d+)\/priority$/u,
    );
    if (priorityMatch) {
      if (request.method !== "POST") {
        return json({ error: "Method not allowed." }, 405);
      }
      return updateTranslationPriority(
        request,
        Number.parseInt(priorityMatch[1], 10),
        identity,
        env,
      );
    }

    const restoreMatch = url.pathname.match(
      /^\/admin\/api\/translations\/(\d+)\/revisions\/(\d+)\/restore$/u,
    );
    if (restoreMatch) {
      if (request.method !== "POST") {
        return json({ error: "Method not allowed." }, 405);
      }
      return restoreRevision(
        request,
        Number.parseInt(restoreMatch[1], 10),
        Number.parseInt(restoreMatch[2], 10),
        identity,
        env,
      );
    }

    const match = url.pathname.match(
      /^\/admin\/api\/translations\/(\d+)(?:\/review)?$/u,
    );
    if (!match) {
      return json({ error: "Not found." }, 404);
    }
    const id = Number.parseInt(match[1], 10);

    if (request.method === "GET" && !url.pathname.endsWith("/review")) {
      return translationDetail(id, env);
    }
    if (request.method === "POST" && url.pathname.endsWith("/review")) {
      return reviewTranslation(request, id, identity, env);
    }

    return json({ error: "Method not allowed." }, 405);
  }

  if (request.method === "GET" || request.method === "HEAD") {
    return adminAsset(request, env);
  }
  return json({ error: "Method not allowed." }, 405);
}

export { validateReviewBody };

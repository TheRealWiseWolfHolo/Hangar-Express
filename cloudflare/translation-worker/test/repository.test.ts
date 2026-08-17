import assert from "node:assert/strict";
import test from "node:test";
import {
  claimNextRetryableTranslation,
  claimNextPendingAutoApproval,
  claimQueuedTranslationByID,
  completeAutoApprovedTranslation,
  completeTranslation,
  enqueueTranslations,
  failTranslation,
  findApprovedGlossaryTerms,
  reserveDailyBudget,
} from "../src/repository.ts";

interface RecordedStatement {
  query: string;
  bindings: unknown[];
  run(): Promise<{ meta: { changes: number } }>;
  first<T>(): Promise<T | null>;
}

function recordingDatabase() {
  const statements: RecordedStatement[] = [];
  let batchCalls = 0;

  const db = {
    prepare(query: string) {
      return {
        bind(...bindings: unknown[]) {
          const statement: RecordedStatement = {
            query,
            bindings,
            async run() {
              return { meta: { changes: 1 } };
            },
            async first<T>() {
              if (!query.includes("RETURNING id")) {
                return null;
              }
              return { id: bindings.at(-1) } as T;
            },
          };
          statements.push(statement);
          return statement;
        },
      };
    },
    async batch(batch: RecordedStatement[]) {
      batchCalls += 1;
      assert.deepEqual(batch, statements);
      return batch.map((statement) => ({
        meta: { changes: 7 },
        results: statement.query.includes("RETURNING id")
          ? [{ id: statement.bindings.at(-1) }]
          : [],
      }));
    },
  } as unknown as D1Database;

  return {
    db,
    statements,
    get batchCalls() {
      return batchCalls;
    },
  };
}

test("records an AI generation failure and daily failure count atomically", async () => {
  const recording = recordingDatabase();
  const failedAt = new Date("2026-07-26T12:30:00.000Z");

  await failTranslation(
    recording.db,
    42,
    "Workers AI failed.",
    new Date("2026-07-26T13:30:00.000Z"),
    failedAt,
    "2026-07-26",
  );

  assert.equal(recording.batchCalls, 1);
  assert.equal(recording.statements.length, 2);
  assert.match(recording.statements[0].query, /UPDATE translation_entries/);
  assert.match(recording.statements[0].query, /RETURNING id/);
  assert.match(recording.statements[1].query, /ai_failures = ai_failures \+ 1/);
  assert.deepEqual(recording.statements[1].bindings, [
    "2026-07-26",
    42,
    failedAt.toISOString(),
  ]);
});

test("does not count budget exhaustion as an AI failure", async () => {
  const recording = recordingDatabase();

  await failTranslation(
    recording.db,
    42,
    "Daily AI budget exhausted.",
    new Date("2026-07-27T00:00:00.000Z"),
    new Date("2026-07-26T12:30:00.000Z"),
  );

  assert.equal(recording.batchCalls, 0);
  assert.equal(recording.statements.length, 1);
  assert.match(recording.statements[0].query, /UPDATE translation_entries/);
  assert.match(recording.statements[0].query, /RETURNING id/);
});

test("completes a translation by its returned row even when triggers add writes", async () => {
  const recording = recordingDatabase();

  await completeTranslation(
    recording.db,
    42,
    "毛虫 - ArcCorp 涂装",
    "@cf/meta/m2m100-1.2b",
    new Date("2026-07-27T22:00:00.000Z"),
  );

  assert.equal(recording.statements.length, 1);
  assert.match(recording.statements[0].query, /RETURNING id/);
  assert.equal(recording.statements[0].bindings.at(-1), 42);
});

test("auto-approves a deterministic upgrade and marks the dictionary dirty atomically", async () => {
  const recording = recordingDatabase();
  const completedAt = new Date("2026-08-07T23:00:00.000Z");

  await completeAutoApprovedTranslation(
    recording.db,
    42,
    "升级 - 克拉克远征 到 双鱼远征 标准版",
    completedAt,
  );

  assert.equal(recording.batchCalls, 1);
  assert.equal(recording.statements.length, 3);
  assert.match(recording.statements[0].query, /approval_method = 'automatic'/);
  assert.match(recording.statements[0].query, /model = 'approved-glossary'/);
  assert.match(recording.statements[0].query, /status = \?4/);
  assert.match(recording.statements[1].query, /new_status/);
  assert.match(recording.statements[1].query, /'approved'/);
  assert.match(recording.statements[2].query, /UPDATE dictionary_state/);
  assert.deepEqual(recording.statements[2].bindings, [
    completedAt.toISOString(),
    "system-auto-approval",
    42,
  ]);
});

test("claims unchecked pending upgrades in priority order", async () => {
  const checkedAt = new Date("2026-08-07T23:30:00.000Z");
  let query = "";
  let bindings: unknown[] = [];
  const db = {
    prepare(value: string) {
      query = value;
      return {
        bind(...values: unknown[]) {
          bindings = values;
          return {
            async first() {
              return { id: 51, source: "Upgrade - A to B Standard Edition", kind: "upgrade" };
            },
          };
        },
      };
    },
  } as unknown as D1Database;

  const claim = await claimNextPendingAutoApproval(db, "zh-Hans", checkedAt);

  assert.deepEqual(claim, {
    id: 51,
    source: "Upgrade - A to B Standard Edition",
    kind: "upgrade",
    checkedAt: checkedAt.toISOString(),
  });
  assert.deepEqual(bindings, [checkedAt.toISOString(), "zh-Hans"]);
  assert.match(query, /status = 'pending'/);
  assert.match(query, /kind = 'upgrade'/);
  assert.match(query, /auto_approval_checked_at IS NULL/);
  assert.match(query, /ORDER BY priority, id/);
});

test("auto-approves an existing pending upgrade using the pending lease", async () => {
  const recording = recordingDatabase();

  await completeAutoApprovedTranslation(
    recording.db,
    42,
    "升级 - 水龟 到 海盗船 标准版",
    new Date("2026-08-07T23:45:00.000Z"),
    "pending",
  );

  assert.deepEqual(recording.statements[0].bindings.slice(-2), ["pending", 42]);
  assert.equal(recording.statements[1].bindings[0], "pending");
});

test("finds approved sources and aliases for glossary matching", async () => {
  let bindings: unknown[] = [];
  const db = {
    prepare(query: string) {
      assert.match(query, /translation_aliases/);
      return {
        bind(...values: unknown[]) {
          bindings = values;
          return {
            async all() {
              return {
                results: [
                  {
                    match_source: "Syulen",
                    approved_translation: "絮伦",
                  },
                  {
                    match_source: "Uamchuai",
                    approved_translation: "万川",
                  },
                ],
              };
            },
          };
        },
      };
    },
  } as unknown as D1Database;

  const terms = await findApprovedGlossaryTerms(
    db,
    "zh-Hans",
    "Syulen plus Uamchuai Paint",
  );

  assert.deepEqual(bindings, [
    "zh-Hans",
    "syulen plus uamchuai paint",
    32,
  ]);
  assert.deepEqual(terms, [
    { source: "Syulen", translation: "絮伦" },
    { source: "Uamchuai", translation: "万川" },
  ]);
});

test("reserves the actual fragment request and character totals", async () => {
  const recording = recordingDatabase();

  const reserved = await reserveDailyBudget(
    recording.db,
    "2026-07-27",
    19,
    100,
    10_000,
    3,
  );

  assert.equal(reserved, true);
  assert.deepEqual(recording.statements[0].bindings, [
    "2026-07-27",
    3,
    19,
    100,
    10_000,
  ]);
  assert.match(
    recording.statements[0].query,
    /ai_requests \+ excluded\.ai_requests <=/,
  );
});

test("claims an eligible failed entry for scheduled retry", async () => {
  const statements: Array<{ query: string; bindings: unknown[] }> = [];
  let reads = 0;
  const db = {
    prepare(query: string) {
      return {
        bind(...bindings: unknown[]) {
          statements.push({ query, bindings });
          return {
            async first() {
              reads += 1;
              return reads === 1
                ? {
                    id: 42,
                    source: "Caterpillar - ArcCorp Paint",
                    kind: "paint",
                    status: "failed",
                  }
                : { id: 42 };
            },
          };
        },
      };
    },
  } as unknown as D1Database;
  const now = new Date("2026-07-27T22:00:00.000Z");

  const claim = await claimNextRetryableTranslation(
    db,
    "zh-Hans",
    now,
  );

  assert.deepEqual(claim, {
    id: 42,
    source: "Caterpillar - ArcCorp Paint",
    kind: "paint",
  });
  assert.equal(statements.length, 2);
  assert.match(statements[0].query, /status = 'failed'/);
  assert.match(statements[0].query, /ORDER BY priority, retry_after, id/);
  assert.match(statements[1].query, /SET status = 'generating'/);
  assert.match(statements[1].query, /RETURNING id/);
  assert.equal(statements[1].bindings[0], now.toISOString());
});

test("returns no retry claim when the queue is empty", async () => {
  const db = {
    prepare() {
      return {
        bind() {
          return {
            async first() {
              return null;
            },
          };
        },
      };
    },
  } as unknown as D1Database;

  assert.equal(
    await claimNextRetryableTranslation(
      db,
      "zh-Hans",
      new Date("2026-07-27T22:00:00.000Z"),
    ),
    null,
  );
});

test("persists mobile uploads as durable retry jobs before queue delivery", async () => {
  const statements: Array<{ query: string; bindings: unknown[] }> = [];
  const db = {
    prepare(query: string) {
      return {
        bind(...bindings: unknown[]) {
          statements.push({ query, bindings });
          return {
            async first() {
              return query.includes("INSERT INTO ai_retry_jobs")
                ? { id: 17 }
                : null;
            },
            async all() {
              return { results: [{ id: 41 }, { id: 42 }] };
            },
            async run() {
              return { meta: { changes: 1 } };
            },
          };
        },
      };
    },
  } as unknown as D1Database;

  const queued = await enqueueTranslations(
    db,
    "zh-Hans",
    [
      { id: 41, source: "Caterpillar" },
      { id: 42, source: "Terrapin" },
    ],
    new Date("2026-07-31T17:00:00.000Z"),
  );

  assert.deepEqual(queued, [41, 42]);
  assert.equal(statements.length, 2);
  assert.match(statements[0].query, /INSERT INTO ai_retry_jobs/);
  assert.match(statements[0].bindings[1] as string, /^mobile-upload:/);
  assert.match(statements[1].query, /Queued for background translation/);
  assert.match(statements[1].query, /retry_job_id IS NULL/);
  assert.deepEqual(statements[1].bindings.slice(-3), [41, 42, "zh-Hans"]);
});

test("claims a specific queued translation idempotently", async () => {
  let statement: { query: string; bindings: unknown[] } | undefined;
  const db = {
    prepare(query: string) {
      return {
        bind(...bindings: unknown[]) {
          statement = { query, bindings };
          return {
            async first() {
              return { id: 42, source: "Terrapin", kind: "ship" };
            },
          };
        },
      };
    },
  } as unknown as D1Database;
  const now = new Date("2026-07-31T17:01:00.000Z");

  const claim = await claimQueuedTranslationByID(
    db,
    "zh-Hans",
    42,
    now,
  );

  assert.deepEqual(claim, { id: 42, source: "Terrapin", kind: "ship" });
  assert.match(statement?.query ?? "", /AND status = 'failed'/);
  assert.match(statement?.query ?? "", /RETURNING id, source, kind/);
  assert.deepEqual(statement?.bindings, [now.toISOString(), 42, "zh-Hans"]);
});

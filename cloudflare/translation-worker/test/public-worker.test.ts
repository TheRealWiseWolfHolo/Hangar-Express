import assert from "node:assert/strict";
import test from "node:test";
import {
  existingResult,
  handleCurrentDictionary,
} from "../src/delivery.ts";
import translationWorker from "../src/index.ts";
import type { StoredTranslation } from "../src/repository.ts";

function stored(
  overrides: Partial<StoredTranslation>,
): StoredTranslation {
  return {
    id: 1,
    source: "120 Month Insurance",
    normalized_source: "120 month insurance",
    kind: "insurance",
    machine_translation: null,
    approved_translation: null,
    status: "pending",
    retry_after: null,
    retry_job_id: null,
    ...overrides,
  };
}

function dictionaryEnv(
  customMetadata: Record<string, string>,
): Env {
  const release = {
    version: 7,
    object_key: "releases/zh-Hans/v7.json",
    checksum: "abc123",
    entry_count: 368,
  };
  return {
    DB: {
      prepare() {
        return {
          bind() {
            return {
              async first() {
                return release;
              },
            };
          },
        };
      },
    },
    RELEASES: {
      async get() {
        return {
          body: JSON.stringify({ locale: "zh-Hans", version: 7 }),
          customMetadata,
          httpEtag: '"r2-etag"',
          writeHttpMetadata(headers: Headers) {
            headers.set("content-language", "zh-Hans");
          },
        };
      },
    },
  } as unknown as Env;
}

test("never exposes an unreviewed machine suggestion to the app", () => {
  const result = existingResult(
    "item-1",
    "120 Month Insurance",
    stored({ machine_translation: "120 个月保险" }),
  );

  assert.deepEqual(result, {
    clientID: "item-1",
    source: "120 Month Insurance",
    status: "pending",
    reason: "A translation suggestion is awaiting human review.",
  });
});

test("returns approved translations from the authoritative dictionary rows", () => {
  const result = existingResult(
    "item-1",
    "120 Month Insurance",
    stored({
      status: "edited",
      machine_translation: "错误建议",
      approved_translation: "120 个月保险",
    }),
  );

  assert.equal(result?.translation, "120 个月保险");
  assert.equal(result?.provider, "dictionary");
  assert.equal(result?.status, "approved");
});

test("serves a release only when R2 metadata matches the D1 pointer", async () => {
  const env = dictionaryEnv({
    checksum: "abc123",
    locale: "zh-Hans",
    version: "7",
    entryCount: "368",
  });
  const response = await handleCurrentDictionary(
    new Request("https://example.com/item-translations/zh-Hans.json"),
    env,
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("etag"), '"r2-etag"');
  assert.equal(response.headers.get("x-content-sha256"), "abc123");
  assert.equal(response.headers.get("x-dictionary-version"), "7");
  assert.equal(response.headers.get("x-dictionary-entry-count"), "368");
});

test("fails closed when R2 metadata does not match D1", async () => {
  const response = await handleCurrentDictionary(
    new Request("https://example.com/item-translations/zh-Hans.json"),
    dictionaryEnv({
      checksum: "wrong",
      locale: "zh-Hans",
      version: "7",
      entryCount: "368",
    }),
  );

  assert.equal(response.status, 503);
  assert.match(await response.text(), /failed verification/i);
});

test("honors the verified R2 entity tag without transferring the body", async () => {
  const response = await handleCurrentDictionary(
    new Request("https://example.com/item-translations/zh-Hans.json", {
      headers: { "if-none-match": '"r2-etag"' },
    }),
    dictionaryEnv({
      checksum: "abc123",
      locale: "zh-Hans",
      version: "7",
      entryCount: "368",
    }),
  );

  assert.equal(response.status, 304);
  assert.equal(await response.text(), "");
});

test("requires JSON and rejects oversized resolve bodies before binding work", async () => {
  const missingContentType = await translationWorker.fetch(
    new Request("https://example.com/v1/translations/resolve", {
      method: "POST",
      body: "{}",
    }),
    {} as Env,
  );
  assert.equal(missingContentType.status, 415);

  const declaredOversized = await translationWorker.fetch(
    new Request("https://example.com/v1/translations/resolve", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "content-length": String(32 * 1024 + 1),
      },
      body: "{}",
    }),
    {} as Env,
  );
  assert.equal(declaredOversized.status, 413);

  const streamedOversized = await translationWorker.fetch(
    new Request("https://example.com/v1/translations/resolve", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ padding: "x".repeat(32 * 1024) }),
    }),
    {} as Env,
  );
  assert.equal(streamedOversized.status, 413);
});

test("enforces the fail-safe fifty-item resolve ceiling", async () => {
  const response = await translationWorker.fetch(
    new Request("https://example.com/v1/translations/resolve", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sourceLocale: "en",
        targetLocale: "zh-Hans",
        items: Array.from({ length: 51 }, (_, index) => ({
          clientID: String(index),
          source: `Catalog item ${index}`,
          kind: "item",
        })),
      }),
    }),
    {
      MAX_BATCH_SIZE: "100",
      MAX_SOURCE_LENGTH: "160",
    } as Env,
  );

  assert.equal(response.status, 400);
  assert.match(await response.text(), /at most 50 entries/i);
});

test("accepts validated text into the queue without reading D1 or running AI", async () => {
  const messages: Array<{ body: unknown }> = [];
  const env = {
    TRANSLATION_QUEUE: {
      async sendBatch(batch: Iterable<{ body: unknown }>) {
        messages.push(...batch);
        return {
          metadata: {
            metrics: { backlogCount: messages.length, backlogBytes: 0 },
          },
        };
      },
    },
    get DB(): never {
      throw new Error("D1 must not be touched by the upload request.");
    },
    get AI(): never {
      throw new Error("Workers AI must not run in the upload request.");
    },
    MAX_BATCH_SIZE: "50",
    MAX_SOURCE_LENGTH: "160",
  } as unknown as Env;

  const response = await translationWorker.fetch(
    new Request("https://example.com/v1/translations/resolve", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        sourceLocale: "en",
        targetLocale: "zh-Hans",
        items: [
          { clientID: "a", source: "Caterpillar", kind: "ship" },
          { clientID: "b", source: "Terrapin", kind: "ship" },
        ],
      }),
    }),
    env,
  );

  assert.equal(response.status, 200);
  assert.deepEqual(messages, [
    {
      body: {
        version: 2,
        clientID: "a",
        source: "Caterpillar",
        kind: "ship",
      },
    },
    {
      body: {
        version: 2,
        clientID: "b",
        source: "Terrapin",
        kind: "ship",
      },
    },
  ]);
  assert.deepEqual(await response.json(), {
    translations: [
      {
        clientID: "a",
        source: "Caterpillar",
        status: "pending",
        reason: "Translation is queued for human review.",
      },
      {
        clientID: "b",
        source: "Terrapin",
        status: "pending",
        reason: "Translation is queued for human review.",
      },
    ],
  });
});

test("scheduled retries exit cleanly when the queue is empty", async () => {
  const env = {
    DB: {
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
    },
  } as unknown as Env;

  await translationWorker.scheduled(
    {
      cron: "* * * * *",
      scheduledTime: Date.parse("2026-07-27T22:00:00.000Z"),
      noRetry() {},
    },
    env,
    {} as ExecutionContext,
  );
});

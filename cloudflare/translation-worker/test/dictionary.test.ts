import assert from "node:assert/strict";
import test from "node:test";
import {
  buildCuratedImportSQL,
  validateCuratedDictionary,
} from "../src/dictionary.ts";

function payload() {
  return {
    locale: "zh-Hans",
    version: 7,
    generatedAt: "2026-07-26T17:52:50.617Z",
    count: 2,
    entries: [
      {
        source: "100i",
        translation: "100i",
        kind: "ship",
        aliases: ["Origin 100i"],
      },
      {
        source: "Standalone Ship",
        translation: "独立舰船",
        kind: "keyword",
        aliases: [],
      },
    ],
  };
}

test("validates curated kinds independently from the runtime allowlist", async () => {
  const dictionary = await validateCuratedDictionary(payload());

  assert.equal(dictionary.count, 2);
  assert.equal(dictionary.entries[1].kind, "keyword");
  assert.equal(dictionary.checksum.length, 64);
});

test("rejects normalized collisions across sources and aliases", async () => {
  const value = payload();
  value.entries[1].aliases = ["  ORIGIN   100i "];

  await assert.rejects(
    validateCuratedDictionary(value),
    /Duplicate normalized dictionary key/,
  );
});

test("rejects a count that does not match entries", async () => {
  const value = payload();
  value.count = 99;

  await assert.rejects(validateCuratedDictionary(value), /count must match/);
});

test("builds a replay-safe import that preserves human-reviewed entries", async () => {
  const dictionary = await validateCuratedDictionary(payload());
  const sql = await buildCuratedImportSQL(
    dictionary,
    new Date("2026-07-26T20:30:00.000Z"),
  );

  assert.match(sql, /ON CONFLICT\(locale, normalized_source\) DO UPDATE/);
  assert.match(sql, /translation_entries\.origin = 'curated'/);
  assert.match(sql, /status IN \('generating', 'pending', 'failed'\)/);
  assert.match(sql, /INSERT OR IGNORE INTO translation_aliases/);
  assert.match(sql, /UPDATE dictionary_state/);
  assert.doesNotMatch(sql, /\bBEGIN\b|\bCOMMIT\b/);
});

test("escapes quotes in curated SQL values", async () => {
  const value = payload();
  value.entries[0].source = "Pilot's 100i";
  value.entries[0].translation = "飞行员的 100i";
  value.entries[0].aliases = [];
  const dictionary = await validateCuratedDictionary(value);
  const sql = await buildCuratedImportSQL(dictionary, new Date(0));

  assert.match(sql, /Pilot''s 100i/);
  assert.doesNotMatch(sql, /Pilot's 100i/);
});

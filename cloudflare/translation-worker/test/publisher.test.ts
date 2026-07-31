import assert from "node:assert/strict";
import test from "node:test";
import {
  buildDictionaryRelease,
  compareReleaseEntries,
  validatePublishBody,
  verifyDictionaryRelease,
  verifyReleaseObjectMetadata,
} from "../src/publisher.ts";

const entries = [
  {
    id: 1,
    source: "100i",
    translation: "100i",
    kind: "ship",
  },
  {
    id: 2,
    source: "Standalone Ship",
    translation: "独立舰船",
    kind: "keyword",
  },
];

const aliases = [
  { translation_entry_id: 1, alias: "Origin 100i" },
  { translation_entry_id: 1, alias: "Origin Jumpworks 100i" },
];

test("builds and verifies an app-compatible immutable release payload", async () => {
  const release = await buildDictionaryRelease(
    4,
    new Date("2026-07-26T21:30:00.000Z"),
    entries,
    aliases,
  );

  const payload = JSON.parse(release.body);
  assert.equal(payload.locale, "zh-Hans");
  assert.equal(payload.version, 4);
  assert.equal(payload.count, 2);
  assert.equal(payload.sourceCount, 2);
  assert.deepEqual(payload.entries[0].aliases, [
    "Origin 100i",
    "Origin Jumpworks 100i",
  ]);
  assert.equal(release.checksum.length, 64);
  await verifyDictionaryRelease(release.body, {
    version: 4,
    count: 2,
    checksum: release.checksum,
  });
});

test("rejects aliases that reference an entry outside the release", async () => {
  await assert.rejects(
    buildDictionaryRelease(
      1,
      new Date(0),
      entries,
      [{ translation_entry_id: 99, alias: "Missing" }],
    ),
    /missing entry 99/i,
  );
});

test("detects modified release bytes before activation", async () => {
  const release = await buildDictionaryRelease(1, new Date(0), entries, aliases);

  await assert.rejects(
    verifyDictionaryRelease(`${release.body} `, {
      version: release.version,
      count: release.count,
      checksum: release.checksum,
    }),
    /checksum/,
  );
});

test("rejects release objects whose R2 metadata cannot satisfy delivery", () => {
  const expected = {
    locale: "zh-Hans",
    version: 4,
    count: 2,
    checksum: "a".repeat(64),
  };
  const validMetadata = {
    checksum: expected.checksum,
    locale: expected.locale,
    version: String(expected.version),
    entryCount: String(expected.count),
  };

  assert.doesNotThrow(() => {
    verifyReleaseObjectMetadata(
      {
        size: 1_024,
        customMetadata: validMetadata,
      },
      expected,
    );
  });
  assert.throws(
    () => {
      verifyReleaseObjectMetadata(
        {
          size: 1_024,
          customMetadata: {
            ...validMetadata,
            entryCount: "3",
          },
        },
        expected,
      );
    },
    /metadata does not match D1/i,
  );
  assert.throws(
    () => {
      verifyReleaseObjectMetadata(
        {
          size: 5 * 1024 * 1024 + 1,
          customMetadata: validMetadata,
        },
        expected,
      );
    },
    /too large/i,
  );
});

test("validates optional release notes", () => {
  assert.deepEqual(
    validatePublishBody({
      expectedChangedAt: "2026-07-26T21:30:00.000Z",
      note: "  Corrected insurance term  ",
    }),
    {
      expectedChangedAt: "2026-07-26T21:30:00.000Z",
      note: "Corrected insurance term",
    },
  );
  assert.equal(
    validatePublishBody({
      expectedChangedAt: "2026-07-26T21:30:00.000Z",
      note: "x".repeat(241),
    }),
    "note must contain at most 240 characters.",
  );
});

test("compares immutable release entries", () => {
  const changes = compareReleaseEntries(
    [
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
      {
        source: "Removed",
        translation: "已删除",
        kind: "keyword",
        aliases: [],
      },
    ],
    [
      {
        source: "100i",
        translation: "100i",
        kind: "ship",
        aliases: ["Origin 100i"],
      },
      {
        source: "Standalone Ship",
        translation: "独立船只",
        kind: "keyword",
        aliases: [],
      },
      {
        source: "Added",
        translation: "新增",
        kind: "keyword",
        aliases: [],
      },
    ],
  );

  assert.deepEqual(
    changes.map((change) => [change.type, change.source]),
    [
      ["added", "Added"],
      ["removed", "Removed"],
      ["changed", "Standalone Ship"],
    ],
  );
});

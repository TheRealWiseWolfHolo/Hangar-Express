import assert from "node:assert/strict";
import test from "node:test";

import {
  applyReviewedEntryToQueue,
  entryMatchesStatus,
  nextReviewEntryID,
  normalizeReviewTranslation,
  reconcileQueueEntry,
  reviewReloadURL,
  reviewActionForInput,
  selectionAfterReviewedEntry,
} from "../public/admin/review-decision.js";

test("normalizes review text like the admin API", () => {
  assert.equal(normalizeReviewTranslation("  毛虫 \n -  涂装  "), "毛虫 - 涂装");
});

test("approves an unchanged machine suggestion", () => {
  assert.equal(
    reviewActionForInput(
      {
        status: "pending",
        machine_translation: "毛虫 - ArcCorp 涂装",
        approved_translation: null,
      },
      "毛虫 - ArcCorp 涂装",
    ),
    "approve",
  );
});

test("saves changed machine text as an edit", () => {
  assert.equal(
    reviewActionForInput(
      {
        status: "pending",
        machine_translation: "毛虫 - ArcCorp 涂装",
        approved_translation: null,
      },
      "毛虫 - 弧光星 涂装",
    ),
    "edit",
  );
});

test("keeps a previously edited translation edited", () => {
  assert.equal(
    reviewActionForInput(
      {
        status: "edited",
        machine_translation: "毛虫 - ArcCorp 涂装",
        approved_translation: "毛虫 - 弧光星 涂装",
      },
      "毛虫 - 弧光星 涂装",
    ),
    "edit",
  );
});

test("approves an unchanged approved-only translation", () => {
  assert.equal(
    reviewActionForInput(
      {
        status: "approved",
        machine_translation: null,
        approved_translation: "毛虫",
      },
      "毛虫",
    ),
    "approve",
  );
});

test("disables the review action for empty text", () => {
  assert.equal(
    reviewActionForInput(
      {
        status: "pending",
        machine_translation: null,
        approved_translation: null,
      },
      " \n ",
    ),
    null,
  );
});

test("selects the following queue entry after a review", () => {
  const entries = [{ id: 30 }, { id: 20 }, { id: 10 }];

  assert.equal(nextReviewEntryID(entries, 30), 20);
  assert.equal(nextReviewEntryID(entries, 20), 10);
  assert.equal(nextReviewEntryID(entries, 10), null);
  assert.equal(nextReviewEntryID(entries, 999), null);
});

test("lazily removes reviewed entries that no longer match the queue filter", () => {
  const entries = [
    { id: 30, status: "pending", source: "A" },
    { id: 20, status: "pending", source: "B" },
  ];
  const reviewed = { id: 30, status: "approved", source: "A" };

  assert.deepEqual(
    applyReviewedEntryToQueue(entries, reviewed, "pending"),
    [entries[1]],
  );
  assert.deepEqual(
    applyReviewedEntryToQueue(entries, reviewed, ""),
    [reviewed, entries[1]],
  );
});

test("builds a cache-busted review workspace reload URL", () => {
  assert.equal(
    reviewReloadURL(1268, "2026.07.28.2"),
    "/admin/?reviewed=1268&ui=2026.07.28.2#review-workspace",
  );
});

test("preserves the selected priority queue after review", () => {
  assert.equal(
    reviewReloadURL(1268, "2026.08.07.1", {
      priority: "low",
      status: "pending",
      kind: "package",
      query: "upgrade",
    }),
    "/admin/?reviewed=1268&ui=2026.08.07.1&priority=low&status=pending&kind=package&q=upgrade#review-workspace",
  );
});

test("removes a stale edited detail from the pending queue and selects the next row", () => {
  const entries = [
    { id: 1266, status: "pending", kind: "package" },
    { id: 1261, status: "pending", kind: "package" },
    { id: 1259, status: "pending", kind: "package" },
  ];
  const refreshed = { id: 1261, status: "edited", kind: "package" };

  assert.deepEqual(
    reconcileQueueEntry(entries, refreshed, "pending", ""),
    {
      entries: [entries[0], entries[2]],
      nextID: 1259,
      matches: false,
    },
  );
});

test("updates a queue row when its refreshed detail still matches the filters", () => {
  const entries = [
    { id: 1266, status: "pending", kind: "package", source: "Old" },
  ];
  const refreshed = {
    id: 1266,
    status: "pending",
    kind: "package",
    source: "Current",
  };

  assert.deepEqual(
    reconcileQueueEntry(entries, refreshed, "pending", "package"),
    {
      entries: [refreshed],
      nextID: 1266,
      matches: true,
    },
  );
});

test("removes an entry moved out of the selected priority queue", () => {
  const entries = [
    { id: 30, status: "pending", kind: "item", priority: "high" },
    { id: 20, status: "pending", kind: "item", priority: "high" },
  ];
  const moved = { ...entries[0], priority: "low" };

  assert.deepEqual(
    reconcileQueueEntry(entries, moved, "pending", "item", "high"),
    {
      entries: [entries[1]],
      nextID: 20,
      matches: false,
    },
  );
});

test("matches the synthetic auto-approved review category", () => {
  assert.equal(
    entryMatchesStatus(
      { status: "approved", approval_method: "automatic" },
      "auto-approved",
    ),
    true,
  );
  assert.equal(
    entryMatchesStatus(
      { status: "approved", approval_method: "human" },
      "auto-approved",
    ),
    false,
  );
  assert.equal(
    entryMatchesStatus(
      { status: "pending", approval_method: null },
      "pending",
    ),
    true,
  );
});

test("selects the following lower-ID row after a reviewed entry reload", () => {
  const entries = [{ id: 1266 }, { id: 1259 }, { id: 1253 }];

  assert.equal(selectionAfterReviewedEntry(entries, 1261), 1259);
  assert.equal(selectionAfterReviewedEntry(entries, 1200), 1266);
  assert.equal(selectionAfterReviewedEntry(entries, Number.NaN), 1266);
  assert.equal(selectionAfterReviewedEntry([], 1261), null);
});

import assert from "node:assert/strict";
import test from "node:test";
import {
  authenticateAdminRequest,
  validatedTeamDomain,
} from "../src/access.ts";
import {
  approvedSimilaritySearchQuery,
  normalizeAIQueueCounts,
  sourceContainsGlossaryPhrase,
  validateGlossaryEntryBody,
  validatePriorityBody,
  validateRestoreRevisionBody,
  validateReviewBody,
} from "../src/admin.ts";

const now = new Date("2026-07-26T20:30:00.000Z");
const expectedUpdatedAt = "2026-07-26T20:00:00.000Z";

test("accepts supported review actions", () => {
  assert.deepEqual(
    validateReviewBody({ action: "approve", expectedUpdatedAt }, now),
    {
      action: "approve",
      expectedUpdatedAt,
    },
  );
  assert.deepEqual(
    validateReviewBody(
      {
        action: "edit",
        translation: "  120 个月保险  ",
        expectedUpdatedAt,
      },
      now,
    ),
    {
      action: "edit",
      translation: "120 个月保险",
      expectedUpdatedAt,
    },
  );
  assert.deepEqual(
    validateReviewBody({ action: "reject", expectedUpdatedAt: null }, now),
    {
      action: "reject",
      expectedUpdatedAt: null,
    },
  );
  assert.deepEqual(
    validateReviewBody(
      {
        action: "defer",
        deferUntil: "2026-07-27T20:30:00.000Z",
        expectedUpdatedAt,
      },
      now,
    ),
    {
      action: "defer",
      deferUntil: "2026-07-27T20:30:00.000Z",
      expectedUpdatedAt,
    },
  );
});

test("rejects invalid edits and deferrals", () => {
  assert.equal(
    validateReviewBody(
      { action: "edit", translation: "  ", expectedUpdatedAt },
      now,
    ),
    "translation must contain 1–500 characters.",
  );
  assert.equal(
    validateReviewBody(
      {
        action: "defer",
        deferUntil: "2026-07-25T20:30:00.000Z",
        expectedUpdatedAt,
      },
      now,
    ),
    "deferUntil must be a future ISO-8601 timestamp.",
  );
  assert.equal(
    validateReviewBody({ action: "publish", expectedUpdatedAt }, now),
    "Unsupported review action.",
  );
  assert.equal(
    validateReviewBody({ action: "approve" }, now),
    "expectedUpdatedAt must be an ISO-8601 timestamp or null.",
  );
});

test("validates optimistic locking for revision restoration", () => {
  assert.deepEqual(validateRestoreRevisionBody({ expectedUpdatedAt }), {
    expectedUpdatedAt,
  });
  assert.deepEqual(validateRestoreRevisionBody({ expectedUpdatedAt: null }), {
    expectedUpdatedAt: null,
  });
  assert.equal(
    validateRestoreRevisionBody({}),
    "expectedUpdatedAt must be an ISO-8601 timestamp or null.",
  );
  assert.equal(
    validateRestoreRevisionBody({ expectedUpdatedAt: "not-a-date" }),
    "expectedUpdatedAt must be an ISO-8601 timestamp or null.",
  );
});

test("accepts only high and low translation priorities", () => {
  assert.deepEqual(validatePriorityBody({ priority: "high" }), {
    priority: "high",
  });
  assert.deepEqual(validatePriorityBody({ priority: "low" }), {
    priority: "low",
  });
  assert.equal(
    validatePriorityBody({ priority: "urgent" }),
    "priority must be high or low.",
  );
});

test("normalizes global AI queue counts", () => {
  assert.deepEqual(
    normalizeAIQueueCounts({
      high_priority_entries: 12,
      low_priority_entries: 7,
      high_pending_review_entries: 112,
      low_pending_review_entries: 9,
      pending_processing_entries: 15,
      active_processing_entries: 4,
    }),
    {
      highPriority: 12,
      lowPriority: 7,
      highPendingReview: 112,
      lowPendingReview: 9,
      pendingProcessing: 15,
      processing: 4,
      total: 19,
    },
  );
  assert.deepEqual(normalizeAIQueueCounts(null), {
    highPriority: 0,
    lowPriority: 0,
    highPendingReview: 0,
    lowPendingReview: 0,
    pendingProcessing: 0,
    processing: 0,
    total: 0,
  });
});

test("builds a bounded FTS query for approved translation references", () => {
  assert.equal(
    approvedSimilaritySearchQuery("Perseus - Flintlock Paint"),
    "\"perseus\" OR \"flintlock\" OR \"paint\"",
  );
  assert.equal(
    approvedSimilaritySearchQuery("Upgrade to Razor Standard Edition"),
    "\"upgrade\" OR \"to\" OR \"razor\" OR \"standard\" OR \"edition\"",
  );
  assert.equal(approvedSimilaritySearchQuery("---"), null);
  assert.equal(
    approvedSimilaritySearchQuery("A A one one two three four five six seven eight nine"),
    "\"one\" OR \"two\" OR \"three\" OR \"four\" OR \"five\" OR \"six\" OR \"seven\" OR \"eight\"",
  );
});

test("validates manual glossary entries", () => {
  assert.deepEqual(
    validateGlossaryEntryBody({
      source: "  C1   Spirit ",
      translation: " 星灵 C1 ",
    }),
    {
      source: "C1 Spirit",
      translation: "星灵 C1",
    },
  );
  assert.equal(
    validateGlossaryEntryBody({ source: " ", translation: "星灵" }),
    "source must contain 2–160 characters and include a letter or number.",
  );
  assert.equal(
    validateGlossaryEntryBody({ source: "C1 Spirit", translation: " " }),
    "translation must contain 1–500 characters.",
  );
});

test("matches glossary phrases with the translator's word boundaries", () => {
  assert.equal(
    sourceContainsGlossaryPhrase(
      "Upgrade - C1 Spirit to Clipper Warbond Edition",
      "C1 Spirit",
    ),
    true,
  );
  assert.equal(
    sourceContainsGlossaryPhrase("Upgrade To Clipper", "to"),
    true,
  );
  assert.equal(
    sourceContainsGlossaryPhrase("Storm - Polar Paint", "to"),
    false,
  );
  assert.equal(
    sourceContainsGlossaryPhrase("C1 Spirit Paint", "c1 spirit"),
    true,
  );
});

test("keeps administration hidden until explicitly enabled", async () => {
  const result = await authenticateAdminRequest(
    new Request("https://example.com/admin/api/translations"),
    {
      ADMIN_API_ENABLED: "false",
      ADMIN_DEV_EMAIL: "",
      TEAM_DOMAIN: "",
      POLICY_AUD: "",
    },
  );

  assert.equal(result.response?.status, 404);
});

test("fails closed when Access configuration is missing", async () => {
  const result = await authenticateAdminRequest(
    new Request("https://example.com/admin/api/translations"),
    {
      ADMIN_API_ENABLED: "true",
      ADMIN_DEV_EMAIL: "",
      TEAM_DOMAIN: "",
      POLICY_AUD: "",
    },
  );

  assert.equal(result.response?.status, 503);
});

test("requires an Access JWT after valid configuration", async () => {
  const result = await authenticateAdminRequest(
    new Request("https://example.com/admin/api/translations"),
    {
      ADMIN_API_ENABLED: "true",
      ADMIN_DEV_EMAIL: "",
      TEAM_DOMAIN: "https://hanger-express.cloudflareaccess.com",
      POLICY_AUD: "test-audience",
    },
  );

  assert.equal(result.response?.status, 401);
});

test("allows an explicit reviewer only on localhost", async () => {
  const localResult = await authenticateAdminRequest(
    new Request("http://localhost/admin/api/session"),
    {
      ADMIN_API_ENABLED: "true",
      ADMIN_DEV_EMAIL: "Reviewer@Local.Test",
      TEAM_DOMAIN: "",
      POLICY_AUD: "",
    },
  );
  const remoteResult = await authenticateAdminRequest(
    new Request("https://example.com/admin/api/session"),
    {
      ADMIN_API_ENABLED: "true",
      ADMIN_DEV_EMAIL: "reviewer@local.test",
      TEAM_DOMAIN: "",
      POLICY_AUD: "",
    },
  );

  assert.equal(localResult.identity?.email, "reviewer@local.test");
  assert.equal(remoteResult.response?.status, 503);
});

test("accepts only canonical Cloudflare Access team domains", () => {
  assert.equal(
    validatedTeamDomain("https://hanger-express.cloudflareaccess.com"),
    "https://hanger-express.cloudflareaccess.com",
  );
  assert.equal(validatedTeamDomain("https://example.com"), null);
  assert.equal(
    validatedTeamDomain("https://hanger-express.cloudflareaccess.com/path"),
    null,
  );
});

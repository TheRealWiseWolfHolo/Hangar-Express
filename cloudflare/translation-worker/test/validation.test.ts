import assert from "node:assert/strict";
import test from "node:test";
import { validateItem, validateResolveRequest } from "../src/validation.ts";

const limits = { maxBatchSize: 25, maxSourceLength: 160 };

test("accepts the supported locale pair and eligible catalog items", () => {
  const body = {
    sourceLocale: "en",
    targetLocale: "zh-Hans",
    items: [{ clientID: "0", source: "  F8C Lightning ", kind: "ship" }],
  };
  const request = validateResolveRequest(body, limits);
  const item = validateItem(body.items[0], limits);

  assert.ok(request.request);
  assert.equal(item.validated?.source, "F8C Lightning");
});

test("rejects unsupported locale pairs", () => {
  const result = validateResolveRequest(
    {
      sourceLocale: "en",
      targetLocale: "fr",
      items: [{ clientID: "0", source: "Gladius", kind: "ship" }],
    },
    limits,
  );

  assert.match(result.error ?? "", /targetLocale/);
});

test("rejects invalid dictionary versions", () => {
  const result = validateResolveRequest(
    {
      sourceLocale: "en",
      targetLocale: "zh-Hans",
      dictionaryVersion: 0,
      items: [{ clientID: "1", source: "Gladius", kind: "ship" }],
    },
    limits,
  );

  assert.match(result.error ?? "", /dictionaryVersion/);
});

test("rejects private or arbitrary content shapes", () => {
  for (const source of [
    "Contact pilot@example.com",
    "See https://example.com/account",
    "Line one\nLine two",
  ]) {
    const result = validateItem(
      { clientID: "0", source, kind: "item" },
      limits,
    );
    assert.equal(result.validated, undefined);
  }
});

test("rejects kinds outside the cloud privacy allowlist", () => {
  const result = validateItem(
    { clientID: "0", source: "Recovered from buy back", kind: "notes" },
    limits,
  );

  assert.equal(result.validated, undefined);
  assert.match(result.reason ?? "", /not eligible/);
});

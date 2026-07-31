import assert from "node:assert/strict";
import test from "node:test";
import {
  normalizedSource,
  sha256,
  trimmedAndCollapsedSource,
} from "../src/normalization.ts";

test("collapses source whitespace without changing display casing", () => {
  assert.equal(
    trimmedAndCollapsedSource("  Anvil   F8C\tLightning  "),
    "Anvil F8C Lightning",
  );
});

test("normalizes case, whitespace, and diacritics for deduplication", () => {
  assert.equal(normalizedSource("  MÉDICAL   Ursa  "), "medical ursa");
});

test("produces stable SHA-256 keys", async () => {
  assert.equal(
    await sha256("zh-Hans\nf8c lightning"),
    await sha256("zh-Hans\nf8c lightning"),
  );
  assert.notEqual(
    await sha256("zh-Hans\nf8c lightning"),
    await sha256("zh-Hans\ngladius"),
  );
});

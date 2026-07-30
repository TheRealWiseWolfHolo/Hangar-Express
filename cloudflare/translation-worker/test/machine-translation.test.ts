import assert from "node:assert/strict";
import test from "node:test";
import {
  buildMachineTranslationPlan,
  ensureSimplifiedChinese,
  machineTranslationFragments,
  preserveSourceQuotationMarks,
  renderMachineTranslationPlan,
} from "../src/machine-translation.ts";

test("normalizes machine output to Mainland Simplified Chinese", () => {
  assert.equal(
    ensureSimplifiedChinese("獨立船舶與翻譯"),
    "独立船舶与翻译",
  );
});

test("preserves source quotation marks instead of Chinese book-title brackets", () => {
  assert.equal(
    preserveSourceQuotationMarks(
      'Klaus & Werner Gallant "Conviction Camo" Rifle',
      "克劳斯和维尔纳·加兰特《信仰迷彩》步枪",
    ),
    '克劳斯和维尔纳·加兰特"信仰迷彩"步枪',
  );
  assert.equal(
    preserveSourceQuotationMarks(
      "Misfit ‘Bonefire’ Jacket",
      "Misfit 《篝火》夹克",
    ),
    "Misfit ‘篝火’夹克",
  );
  assert.equal(
    preserveSourceQuotationMarks(
      "Behring P8-AR 'Dominion Camo' Rifle",
      "贝林 P8-AR 《统治迷彩》步枪",
    ),
    "贝林 P8-AR '统治迷彩'步枪",
  );
});

test("removes machine-added book-title brackets absent from the source", () => {
  assert.equal(
    preserveSourceQuotationMarks(
      "CureLife Field Medic Kit",
      "《CureLife Field Medic Kit》",
    ),
    "CureLife Field Medic Kit",
  );
  assert.equal(
    preserveSourceQuotationMarks(
      "Terrapin - Deck the Hull Paint",
      "水龟《Deck the Hull》涂装",
    ),
    "水龟Deck the Hull涂装",
  );
});

test("restores multiple quotation pairs in source order", () => {
  assert.equal(
    preserveSourceQuotationMarks(
      '"Red" and “Blue” Paint',
      "《红色》和《蓝色》涂装",
    ),
    '"红色"和“蓝色”涂装',
  );
});

test("applies quotation preservation to rendered machine output", async () => {
  const translation = await renderMachineTranslationPlan(
    buildMachineTranslationPlan(
      'Klaus & Werner Gallant "Conviction Camo" Rifle',
      [],
    ),
    async () => "克劳斯和维尔纳·加兰特《信仰迷彩》步枪",
  );

  assert.equal(
    translation,
    '克劳斯和维尔纳·加兰特"信仰迷彩"步枪',
  );
});

test("locks approved conventional names and translates only unmatched fragments", async () => {
  const plan = buildMachineTranslationPlan(
    "Standalone Ship - Syulen plus Uamchuai Paint",
    [
      { source: "Standalone Ship", translation: "独立舰船" },
      { source: "Syulen", translation: "絮伦" },
      { source: "Uamchuai", translation: "万川" },
      { source: "Paint", translation: "涂装" },
    ],
  );

  assert.deepEqual(machineTranslationFragments(plan), ["plus"]);
  const requestedFragments: string[] = [];
  const translation = await renderMachineTranslationPlan(
    plan,
    async (source) => {
      requestedFragments.push(source);
      return "加上";
    },
  );

  assert.deepEqual(requestedFragments, ["plus"]);
  assert.equal(translation, "独立舰船 - 絮伦 加上 万川 涂装");
});

test("preserves an unknown catalog name without sending it to AI", async () => {
  const plan = buildMachineTranslationPlan(
    "Standalone Ships - Tyilui plus Uamchuai Paint",
    [
      { source: "Standalone Ships", translation: "独立舰船" },
      { source: "plus", translation: "和" },
      { source: "Paint", translation: "涂装" },
    ],
  );

  assert.deepEqual(machineTranslationFragments(plan), []);
  const translation = await renderMachineTranslationPlan(
    plan,
    async () => {
      throw new Error("Unknown catalog names must not be sent to AI.");
    },
  );

  assert.equal(translation, "独立舰船 - Tyilui 和 Uamchuai 涂装");
});

test("uses longest non-overlapping glossary matches with word boundaries", () => {
  const plan = buildMachineTranslationPlan(
    "Pioneer and Ion",
    [
      { source: "Ion", translation: "离子" },
      { source: "Pioneer", translation: "拓荒者" },
      { source: "Pio", translation: "不应使用" },
    ],
  );

  assert.deepEqual(plan, [
    { source: "Pioneer", approvedTranslation: "拓荒者" },
    { source: " and " },
    { source: "Ion", approvedTranslation: "离子" },
  ]);
});

test("matches the approved To connector regardless of source casing", () => {
  const plan = buildMachineTranslationPlan(
    "Upgrade - Starlancer TAC to Galaxy Standard Edition",
    [
      { source: "To", translation: "到" },
      { source: "Standard Edition", translation: "标准版" },
    ],
  );

  assert.deepEqual(plan, [
    { source: "Upgrade - Starlancer TAC " },
    { source: "to", approvedTranslation: "到" },
    { source: " Galaxy " },
    { source: "Standard Edition", approvedTranslation: "标准版" },
  ]);
});

test("treats Warbond Edition as one glossary term", async () => {
  const plan = buildMachineTranslationPlan(
    "Upgrade - Prospector to Vulture Warbond Edition",
    [
      { source: "Warbond", translation: "战争债券" },
      { source: "Edition", translation: "版" },
      { source: "Warbond Edition", translation: "战争债券版" },
    ],
  );

  assert.deepEqual(plan.at(-1), {
    source: "Warbond Edition",
    approvedTranslation: "战争债券版",
  });
  assert.equal(
    await renderMachineTranslationPlan(plan, async (source) => source),
    "Upgrade - Prospector to Vulture 战争债券版",
  );
});

test("removes legacy spacing inside Warbond Edition output", () => {
  assert.equal(
    ensureSimplifiedChinese("升级 - 勘探者 到 秃鹫 战争债券 版"),
    "升级 - 勘探者 到 秃鹫 战争债券版",
  );
});

test("treats Standard Edition as one glossary term", async () => {
  const plan = buildMachineTranslationPlan(
    "Upgrade - Ballista to Razor Standard Edition",
    [
      { source: "Edition", translation: "版" },
      { source: "Standard Edition", translation: "标准版" },
    ],
  );

  assert.deepEqual(plan.at(-1), {
    source: "Standard Edition",
    approvedTranslation: "标准版",
  });
  assert.equal(
    await renderMachineTranslationPlan(plan, async (source) => source),
    "Upgrade - Ballista to Razor 标准版",
  );
});

test("normalizes legacy Standard Edition output", () => {
  assert.equal(
    ensureSimplifiedChinese("升级 - 弩炮 到 剃刀 Standard 版"),
    "升级 - 弩炮 到 剃刀 标准版",
  );
  assert.equal(
    ensureSimplifiedChinese("升级 - 弩炮 到 剃刀 标准 版"),
    "升级 - 弩炮 到 剃刀 标准版",
  );
});

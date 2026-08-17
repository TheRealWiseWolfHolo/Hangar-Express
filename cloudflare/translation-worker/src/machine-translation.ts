import type { ApprovedGlossaryTerm } from "./repository.ts";
import { convertToSimplifiedChinese } from "./opencc-t2cn.js";

const translatableCharacterPattern = /[\p{L}\p{N}]/u;
const wordCharacterPattern = /[\p{L}\p{N}]/u;
const singleCatalogNamePattern =
  /^[^\p{L}\p{N}]*[A-Z][\p{L}\p{M}\p{N}'’.-]*[^\p{L}\p{N}]*$/u;

function normalizeCatalogTranslationSpacing(value: string): string {
  return value
    .replaceAll("战争债券 版", "战争债券版")
    .replaceAll("标准 版", "标准版")
    .replace(/Standard\s*版/giu, "标准版")
    .replace(/Standard Edition/giu, "标准版");
}

interface GlossaryMatch {
  start: number;
  end: number;
  translation: string;
}

interface SourceQuotationPair {
  start: number;
  end: number;
  opening: string;
  closing: string;
}

export interface MachineTranslationPlanSegment {
  source: string;
  approvedTranslation?: string;
}

const exactUpgradeEditionPattern =
  /^Upgrade[\t ]*-[\t ]+.+?[\t ]+to[\t ]+.+?[\t ]+(?:Standard|Warbond)[\t ]+Edition$/iu;

function sourceQuotationPairs(source: string): SourceQuotationPair[] {
  const candidates: SourceQuotationPair[] = [];
  const patterns = [
    /"[^"]+"/gu,
    /'[^']+'/gu,
    /“[^”]+”/gu,
    /‘[^’]+’/gu,
    /《[^》]+》/gu,
  ];

  for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) {
      if (match.index === undefined) {
        continue;
      }
      candidates.push({
        start: match.index,
        end: match.index + match[0].length,
        opening: match[0][0],
        closing: match[0][match[0].length - 1],
      });
    }
  }

  const accepted: SourceQuotationPair[] = [];
  for (const candidate of candidates.sort(
    (left, right) => left.start - right.start || right.end - left.end,
  )) {
    if (
      accepted.some(
        (pair) => candidate.start < pair.end && candidate.end > pair.start,
      )
    ) {
      continue;
    }
    accepted.push(candidate);
  }
  return accepted;
}

export function preserveSourceQuotationMarks(
  source: string,
  translation: string,
): string {
  const quotationPairs = sourceQuotationPairs(source);
  let quotationIndex = 0;
  const restored = translation.replace(
    /《([^《》]*)》/gu,
    (_match, content: string) => {
      const quotation = quotationPairs[quotationIndex];
      if (!quotation) {
        return content;
      }
      quotationIndex += 1;
      return `${quotation.opening}${content}${quotation.closing}`;
    },
  );

  let result = restored;
  if (!source.includes("《")) {
    result = result.replaceAll("《", "");
  }
  if (!source.includes("》")) {
    result = result.replaceAll("》", "");
  }
  return result;
}

function isWordCharacter(value: string | undefined): boolean {
  return value !== undefined && wordCharacterPattern.test(value);
}

function hasWordBoundaries(
  source: string,
  term: string,
  start: number,
): boolean {
  const end = start + term.length;
  const requiresLeadingBoundary = isWordCharacter(term[0]);
  const requiresTrailingBoundary = isWordCharacter(term[term.length - 1]);
  return !(
    (requiresLeadingBoundary && isWordCharacter(source[start - 1])) ||
    (requiresTrailingBoundary && isWordCharacter(source[end]))
  );
}

function glossaryMatches(
  source: string,
  terms: ApprovedGlossaryTerm[],
): GlossaryMatch[] {
  const lowercasedSource = source.toLocaleLowerCase("en-US");
  const candidates: GlossaryMatch[] = [];
  const seenTerms = new Set<string>();

  for (const term of [...terms].sort(
    (left, right) => right.source.length - left.source.length,
  )) {
    const lowercasedTerm = term.source.toLocaleLowerCase("en-US");
    if (!lowercasedTerm || seenTerms.has(lowercasedTerm)) {
      continue;
    }
    seenTerms.add(lowercasedTerm);

    let searchStart = 0;
    while (searchStart < lowercasedSource.length) {
      const start = lowercasedSource.indexOf(lowercasedTerm, searchStart);
      if (start < 0) {
        break;
      }
      if (hasWordBoundaries(lowercasedSource, lowercasedTerm, start)) {
        candidates.push({
          start,
          end: start + lowercasedTerm.length,
          translation: term.translation,
        });
      }
      searchStart = start + Math.max(lowercasedTerm.length, 1);
    }
  }

  const accepted: GlossaryMatch[] = [];
  for (const candidate of candidates.sort(
    (left, right) =>
      left.start - right.start ||
      (right.end - right.start) - (left.end - left.start),
  )) {
    if (
      accepted.some(
        (match) => candidate.start < match.end && candidate.end > match.start,
      )
    ) {
      continue;
    }
    accepted.push(candidate);
  }
  return accepted.sort((left, right) => left.start - right.start);
}

export function buildMachineTranslationPlan(
  source: string,
  terms: ApprovedGlossaryTerm[],
): MachineTranslationPlanSegment[] {
  const matches = glossaryMatches(source, terms);
  if (matches.length === 0) {
    return [{ source }];
  }

  const segments: MachineTranslationPlanSegment[] = [];
  let offset = 0;
  for (const match of matches) {
    if (match.start > offset) {
      segments.push({ source: source.slice(offset, match.start) });
    }
    segments.push({
      source: source.slice(match.start, match.end),
      approvedTranslation: match.translation,
    });
    offset = match.end;
  }
  if (offset < source.length) {
    segments.push({ source: source.slice(offset) });
  }
  return segments;
}

export function machineTranslationFragments(
  plan: MachineTranslationPlanSegment[],
): string[] {
  return plan
    .filter((segment) => segment.approvedTranslation === undefined)
    .map((segment) => segment.source.trim())
    .filter(
      (source) =>
        source.length > 0 &&
        translatableCharacterPattern.test(source) &&
        !singleCatalogNamePattern.test(source),
    );
}

export function isFullyApprovedUpgradePlan(
  kind: string,
  source: string,
  plan: MachineTranslationPlanSegment[],
): boolean {
  if (kind !== "upgrade" || !exactUpgradeEditionPattern.test(source)) {
    return false;
  }

  return plan.every(
    (segment) =>
      segment.approvedTranslation !== undefined ||
      !translatableCharacterPattern.test(segment.source),
  );
}

export async function renderFullyApprovedUpgrade(
  kind: string,
  source: string,
  plan: MachineTranslationPlanSegment[],
): Promise<string | null> {
  if (!isFullyApprovedUpgradePlan(kind, source, plan)) {
    return null;
  }

  return renderMachineTranslationPlan(plan, async () => {
    throw new Error("A fully approved upgrade must not invoke Workers AI.");
  });
}

export async function renderMachineTranslationPlan(
  plan: MachineTranslationPlanSegment[],
  translate: (source: string) => Promise<string>,
): Promise<string> {
  const source = plan.map((segment) => segment.source).join("");
  const rendered: string[] = [];
  for (const segment of plan) {
    if (segment.approvedTranslation !== undefined) {
      rendered.push(segment.approvedTranslation);
      continue;
    }

    const leadingWhitespace = segment.source.match(/^\s*/u)?.[0] ?? "";
    const trailingWhitespace = segment.source.match(/\s*$/u)?.[0] ?? "";
    const trimmedSource = segment.source.trim();
    if (
      !trimmedSource ||
      !translatableCharacterPattern.test(trimmedSource)
    ) {
      rendered.push(segment.source);
      continue;
    }
    if (singleCatalogNamePattern.test(trimmedSource)) {
      rendered.push(segment.source);
      continue;
    }

    rendered.push(
      `${leadingWhitespace}${await translate(trimmedSource)}${trailingWhitespace}`,
    );
  }

  return preserveSourceQuotationMarks(
    source,
    normalizeCatalogTranslationSpacing(
      convertToSimplifiedChinese(rendered.join("")),
    ),
  ).trim();
}

export function ensureSimplifiedChinese(value: string): string {
  return normalizeCatalogTranslationSpacing(convertToSimplifiedChinese(value));
}

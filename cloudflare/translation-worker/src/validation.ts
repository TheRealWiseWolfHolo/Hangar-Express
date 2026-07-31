import {
  allowedKinds,
  supportedSourceLocale,
  supportedTargetLocale,
} from "./contracts.ts";
import type { ResolveItem, ResolveRequest } from "./contracts.ts";
import { trimmedAndCollapsedSource } from "./normalization.ts";

const emailPattern = /\b\S+@\S+\.\S+\b/u;
const urlPattern = /\b(?:https?:\/\/|www\.)\S+/iu;
const controlCharacterPattern = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/u;

export interface ValidationLimits {
  maxBatchSize: number;
  maxSourceLength: number;
}

export interface ValidatedItem extends ResolveItem {
  source: string;
}

export interface ItemValidation {
  item: ResolveItem;
  validated?: ValidatedItem;
  reason?: string;
}

export function validateResolveRequest(
  value: unknown,
  limits: ValidationLimits,
): { request?: ResolveRequest; error?: string } {
  if (!value || typeof value !== "object") {
    return { error: "The request body must be a JSON object." };
  }

  const candidate = value as Partial<ResolveRequest>;
  if (candidate.sourceLocale !== supportedSourceLocale) {
    return { error: `sourceLocale must be ${supportedSourceLocale}.` };
  }
  if (candidate.targetLocale !== supportedTargetLocale) {
    return { error: `targetLocale must be ${supportedTargetLocale}.` };
  }
  if (
    candidate.dictionaryVersion !== undefined &&
    (
      typeof candidate.dictionaryVersion !== "number" ||
      !Number.isSafeInteger(candidate.dictionaryVersion) ||
      candidate.dictionaryVersion <= 0
    )
  ) {
    return { error: "dictionaryVersion must be a positive integer when present." };
  }
  if (!Array.isArray(candidate.items) || candidate.items.length === 0) {
    return { error: "items must contain at least one translation request." };
  }
  if (candidate.items.length > limits.maxBatchSize) {
    return { error: `items must contain at most ${limits.maxBatchSize} entries.` };
  }

  return { request: candidate as ResolveRequest };
}

export function validateItem(
  item: unknown,
  limits: ValidationLimits,
): ItemValidation {
  const fallback: ResolveItem = {
    clientID: "",
    source: "",
    kind: "item",
  };

  if (!item || typeof item !== "object") {
    return { item: fallback, reason: "Item must be an object." };
  }

  const candidate = item as Partial<ResolveItem>;
  const resultItem: ResolveItem = {
    clientID: typeof candidate.clientID === "string" ? candidate.clientID : "",
    source: typeof candidate.source === "string" ? candidate.source : "",
    kind: candidate.kind ?? "item",
  };
  const rawSource = resultItem.source;
  const source = trimmedAndCollapsedSource(resultItem.source);

  if (!resultItem.clientID || resultItem.clientID.length > 64) {
    return { item: resultItem, reason: "clientID must contain 1–64 characters." };
  }
  if (!allowedKinds.has(resultItem.kind)) {
    return { item: resultItem, reason: "kind is not eligible for cloud translation." };
  }
  if (!source || source.length > limits.maxSourceLength) {
    return {
      item: resultItem,
      reason: `source must contain 1–${limits.maxSourceLength} characters.`,
    };
  }
  if (
    emailPattern.test(source) ||
    urlPattern.test(source) ||
    controlCharacterPattern.test(rawSource) ||
    rawSource.includes("\n") ||
    rawSource.includes("\r")
  ) {
    return { item: resultItem, reason: "source contains ineligible content." };
  }

  return {
    item: resultItem,
    validated: {
      clientID: resultItem.clientID,
      source,
      kind: resultItem.kind,
    },
  };
}

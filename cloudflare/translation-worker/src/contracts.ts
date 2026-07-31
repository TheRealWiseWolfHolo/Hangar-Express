export const supportedSourceLocale = "en";
export const supportedTargetLocale = "zh-Hans";

export const allowedKinds = new Set([
  "insurance",
  "item",
  "manufacturer",
  "package",
  "paint",
  "role",
  "ship",
  "upgrade",
]);

export type TranslationKind =
  | "insurance"
  | "item"
  | "manufacturer"
  | "package"
  | "paint"
  | "role"
  | "ship"
  | "upgrade";

export interface ResolveItem {
  clientID: string;
  source: string;
  kind: TranslationKind;
}

export interface ResolveRequest {
  sourceLocale: string;
  targetLocale: string;
  dictionaryVersion?: number;
  items: ResolveItem[];
}

export type ResolveStatus =
  | "approved"
  | "pending"
  | "rejected"
  | "ineligible"
  | "unavailable";

export interface ResolveResult {
  clientID: string;
  source: string;
  translation?: string;
  status: ResolveStatus;
  provider?: "dictionary";
  reason?: string;
}

export interface ResolveResponse {
  translations: ResolveResult[];
}

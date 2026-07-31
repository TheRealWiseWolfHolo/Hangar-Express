import { supportedTargetLocale } from "./contracts.ts";
import type { ResolveResult } from "./contracts.ts";
import type { StoredTranslation } from "./repository.ts";

function json(value: unknown, status: number): Response {
  return Response.json(value, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

export function existingResult(
  clientID: string,
  source: string,
  stored: StoredTranslation,
): ResolveResult | null {
  if (
    (stored.status === "approved" || stored.status === "edited") &&
    stored.approved_translation
  ) {
    return {
      clientID,
      source,
      translation: stored.approved_translation,
      status: "approved",
      provider: "dictionary",
    };
  }

  if (stored.status === "pending" && stored.machine_translation) {
    return {
      clientID,
      source,
      status: "pending",
      reason: "A translation suggestion is awaiting human review.",
    };
  }

  if (stored.status === "rejected") {
    return { clientID, source, status: "rejected" };
  }

  return null;
}

export async function handleCurrentDictionary(
  request: Request,
  env: Env,
): Promise<Response> {
  const release = await env.DB
    .prepare(
      `SELECT version, object_key, checksum, entry_count
       FROM dictionary_releases
       WHERE locale = ?1 AND status = 'current'
       LIMIT 1`,
    )
    .bind(supportedTargetLocale)
    .first<{
      version: number;
      object_key: string;
      checksum: string;
      entry_count: number;
    }>();

  if (!release) {
    return json({ error: "No translation dictionary has been published." }, 503);
  }

  const object = await env.RELEASES.get(release.object_key);
  if (!object) {
    return json({ error: "The current translation dictionary is unavailable." }, 503);
  }
  if (
    object.customMetadata?.checksum !== release.checksum ||
    object.customMetadata?.locale !== supportedTargetLocale ||
    object.customMetadata?.version !== String(release.version) ||
    object.customMetadata?.entryCount !== String(release.entry_count)
  ) {
    console.error(
      JSON.stringify({
        message: "Current R2 dictionary metadata does not match D1.",
        objectKey: release.object_key,
        version: release.version,
      }),
    );
    return json({ error: "The current translation dictionary failed verification." }, 503);
  }

  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("etag", object.httpEtag);
  headers.set("x-content-sha256", release.checksum);
  headers.set("x-dictionary-version", String(release.version));
  headers.set("x-dictionary-entry-count", String(release.entry_count));
  headers.set("cache-control", "public, max-age=300, s-maxage=3600");
  headers.set("vary", "accept-encoding");

  if (request.headers.get("if-none-match") === object.httpEtag) {
    return new Response(null, { status: 304, headers });
  }
  return new Response(object.body, { headers });
}

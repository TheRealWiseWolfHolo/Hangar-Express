import { supportedTargetLocale } from "./contracts.ts";
import type { ResolveResponse, ResolveResult } from "./contracts.ts";
import {
  existingResult,
  handleCurrentDictionary,
} from "./delivery.ts";
import {
  claimNextRetryableTranslation,
  claimQueuedTranslationByID,
  completeTranslation,
  enqueueTranslations,
  failTranslation,
  findApprovedGlossaryTerms,
  findOrClaimTranslation,
  reserveDailyBudget,
} from "./repository.ts";
import {
  buildMachineTranslationPlan,
  machineTranslationFragments,
  renderMachineTranslationPlan,
} from "./machine-translation.ts";
import {
  validateItem,
  validateResolveRequest,
} from "./validation.ts";
import type { ValidationLimits } from "./validation.ts";

const translationModel = "@cf/meta/m2m100-1.2b";
const maximumResolveBatchSize = 6;
const maximumResolveRequestBytes = 32 * 1024;
const scheduledRetryBatchSize = 6;

interface TranslationQueueMessage {
  entryID: number;
}

class ResolveRequestTooLargeError extends Error {}

function json(value: unknown, status = 200, additionalHeaders?: HeadersInit): Response {
  const headers = new Headers(additionalHeaders);
  headers.set("content-type", "application/json; charset=utf-8");
  headers.set("cache-control", "no-store");
  return new Response(JSON.stringify(value), { status, headers });
}

function positiveInteger(value: string, fallback: number): number {
  const parsed = Number.parseInt(value, 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function limits(env: Env): ValidationLimits {
  return {
    maxBatchSize: Math.min(
      positiveInteger(env.MAX_BATCH_SIZE, maximumResolveBatchSize),
      maximumResolveBatchSize,
    ),
    maxSourceLength: positiveInteger(env.MAX_SOURCE_LENGTH, 160),
  };
}

async function readLimitedJSONBody(
  request: Request,
  maximumBytes: number,
): Promise<unknown> {
  const declaredLength = request.headers.get("content-length");
  if (declaredLength) {
    const parsedLength = Number.parseInt(declaredLength, 10);
    if (Number.isFinite(parsedLength) && parsedLength > maximumBytes) {
      throw new ResolveRequestTooLargeError();
    }
  }

  const reader = request.body?.getReader();
  if (!reader) {
    throw new SyntaxError("The request body is empty.");
  }
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      totalBytes += value.byteLength;
      if (totalBytes > maximumBytes) {
        await reader.cancel();
        throw new ResolveRequestTooLargeError();
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(
    new TextDecoder("utf-8", {
      fatal: true,
      ignoreBOM: false,
    }).decode(bytes),
  );
}

function translatedTextFromAI(value: unknown): string | null {
  if (!value || typeof value !== "object") {
    return null;
  }

  const candidate = value as {
    translated_text?: unknown;
    response?: { translated_text?: unknown };
  };
  const translated =
    typeof candidate.translated_text === "string"
      ? candidate.translated_text
      : candidate.response &&
          typeof candidate.response.translated_text === "string"
        ? candidate.response.translated_text
        : null;

  const trimmed = translated?.trim() ?? "";
  return trimmed && trimmed.length <= 500 ? trimmed : null;
}

async function resolveNewTranslation(
  env: Env,
  clientID: string,
  source: string,
  entryID: number,
  now: Date,
): Promise<ResolveResult> {
  const requestLimit = positiveInteger(env.DAILY_AI_REQUEST_LIMIT, 1000);
  const characterLimit = positiveInteger(env.DAILY_AI_CHARACTER_LIMIT, 100_000);
  const usageDate = now.toISOString().slice(0, 10);
  let reservedAIRequest = false;

  try {
    const glossaryTerms = await findApprovedGlossaryTerms(
      env.DB,
      supportedTargetLocale,
      source,
    );
    const translationPlan = buildMachineTranslationPlan(source, glossaryTerms);
    const aiFragments = machineTranslationFragments(translationPlan);
    const hasBudget =
      aiFragments.length === 0 ||
      await reserveDailyBudget(
        env.DB,
        usageDate,
        aiFragments.reduce((total, fragment) => total + fragment.length, 0),
        requestLimit,
        characterLimit,
        aiFragments.length,
      );

    if (!hasBudget) {
      const retryAfter = new Date(now);
      retryAfter.setUTCDate(retryAfter.getUTCDate() + 1);
      retryAfter.setUTCHours(0, 0, 0, 0);
      await failTranslation(
        env.DB,
        entryID,
        "Daily AI budget exhausted.",
        retryAfter,
        now,
      );
      return {
        clientID,
        source,
        status: "unavailable",
        reason: "Translation capacity is temporarily unavailable.",
      };
    }
    reservedAIRequest = aiFragments.length > 0;

    const translation = await renderMachineTranslationPlan(
      translationPlan,
      async (fragment) => {
        const aiResult = await env.AI.run(translationModel, {
          text: fragment,
          source_lang: "english",
          target_lang: "chinese",
        });
        return translatedTextFromAI(aiResult) || fragment;
      },
    );
    if (!translation || translation === source) {
      throw new Error("The translation model returned no usable translation.");
    }

    await completeTranslation(
      env.DB,
      entryID,
      translation,
      translationModel,
      new Date(),
    );
    return {
      clientID,
      source,
      status: "pending",
      reason: "A translation suggestion was created and is awaiting human review.",
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unknown Workers AI error.";
    const retryAfter = new Date(now.getTime() + 60 * 60 * 1000);
    await failTranslation(
      env.DB,
      entryID,
      message,
      retryAfter,
      new Date(),
      reservedAIRequest ? usageDate : undefined,
    );
    return {
      clientID,
      source,
      status: "unavailable",
      reason: "Translation is temporarily unavailable.",
    };
  }
}

async function processRetryBatch(
  env: Env,
  now = new Date(),
  batchSize = scheduledRetryBatchSize,
): Promise<number> {
  let processed = 0;
  for (let index = 0; index < batchSize; index += 1) {
    const claim = await claimNextRetryableTranslation(
      env.DB,
      supportedTargetLocale,
      new Date(),
    );
    if (!claim) {
      break;
    }
    await resolveNewTranslation(
      env,
      `retry-${claim.id}`,
      claim.source,
      claim.id,
      now,
    );
    processed += 1;
  }
  return processed;
}

async function handleResolve(
  request: Request,
  env: Env,
  context?: ExecutionContext,
): Promise<Response> {
  const contentType = request.headers.get("content-type")?.toLowerCase() ?? "";
  if (!contentType.startsWith("application/json")) {
    return json({ error: "Content-Type must be application/json." }, 415);
  }

  let body: unknown;
  try {
    body = await readLimitedJSONBody(request, maximumResolveRequestBytes);
  } catch (error) {
    if (error instanceof ResolveRequestTooLargeError) {
      return json(
        {
          error: `The request body must not exceed ${maximumResolveRequestBytes} bytes.`,
        },
        413,
      );
    }
    return json({ error: "The request body must be valid JSON." }, 400);
  }

  const requestValidation = validateResolveRequest(body, limits(env));
  if (!requestValidation.request) {
    return json({ error: requestValidation.error }, 400);
  }

  const now = new Date();
  const translations: ResolveResult[] = [];
  const queuedClaims: Array<{
    clientID: string;
    source: string;
    entryID: number;
  }> = [];

  for (const rawItem of requestValidation.request.items) {
    const validation = validateItem(rawItem, limits(env));
    if (!validation.validated) {
      translations.push({
        clientID: validation.item.clientID,
        source: validation.item.source,
        status: "ineligible",
        reason: validation.reason,
      });
      continue;
    }

    try {
      const claim = await findOrClaimTranslation(
        env.DB,
        supportedTargetLocale,
        validation.validated,
        now,
      );
      const existing = existingResult(
        validation.validated.clientID,
        validation.validated.source,
        claim.stored,
      );
      if (existing) {
        translations.push(existing);
      } else if (!claim.ownsGeneration) {
        translations.push({
          clientID: validation.validated.clientID,
          source: validation.validated.source,
          status: claim.stored.retry_job_id === null ? "unavailable" : "pending",
          reason: claim.stored.retry_job_id === null
            ? "Translation is temporarily unavailable."
            : "Translation is queued for human review.",
        });
      } else {
        queuedClaims.push({
          clientID: validation.validated.clientID,
          source: validation.validated.source,
          entryID: claim.stored.id,
        });
      }
    } catch {
      translations.push({
        clientID: validation.validated.clientID,
        source: validation.validated.source,
        status: "unavailable",
        reason: "Translation storage is temporarily unavailable.",
      });
    }
  }

  if (queuedClaims.length > 0) {
    try {
      const queuedIDs = new Set(
        await enqueueTranslations(
          env.DB,
          supportedTargetLocale,
          queuedClaims.map((claim) => ({
            id: claim.entryID,
            source: claim.source,
          })),
          now,
        ),
      );
      const queueMessages = queuedClaims
        .filter((claim) => queuedIDs.has(claim.entryID))
        .map((claim) => ({ body: { entryID: claim.entryID } }));

      for (const claim of queuedClaims) {
        const queued = queuedIDs.has(claim.entryID);
        translations.push({
          clientID: claim.clientID,
          source: claim.source,
          status: queued ? "pending" : "unavailable",
          reason: queued
            ? "Translation is queued for human review."
            : "Translation storage is temporarily unavailable.",
        });
      }

      if (queueMessages.length > 0) {
        const delivery = env.TRANSLATION_QUEUE
          .sendBatch(queueMessages)
          .catch((error) => {
            console.error(
              JSON.stringify({
                message: "Cloudflare Queue delivery failed; scheduled retry will recover it.",
                entryIDs: queueMessages.map((message) => message.body.entryID),
                error: error instanceof Error ? error.message : String(error),
              }),
            );
          });
        if (context) {
          context.waitUntil(delivery);
        } else {
          await delivery;
        }
      }
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "Translation queue persistence failed.",
          entryIDs: queuedClaims.map((claim) => claim.entryID),
          error: error instanceof Error ? error.message : String(error),
        }),
      );
      for (const claim of queuedClaims) {
        translations.push({
          clientID: claim.clientID,
          source: claim.source,
          status: "unavailable",
          reason: "Translation storage is temporarily unavailable.",
        });
      }
    }
  }

  return json({ translations } satisfies ResolveResponse);
}

export default {
  async fetch(
    request: Request,
    env: Env,
    context?: ExecutionContext,
  ): Promise<Response> {
    try {
      const url = new URL(request.url);

      if (request.method === "GET" && url.pathname === "/health") {
        return json({ status: "ok" });
      }
      if (request.method === "POST" && url.pathname === "/v1/translations/resolve") {
        return handleResolve(request, env, context);
      }
      if (
        request.method === "GET" &&
        url.pathname === "/item-translations/zh-Hans.json"
      ) {
        return handleCurrentDictionary(request, env);
      }

      return json({ error: "Not found." }, 404);
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "Unhandled translation Worker error.",
          path: new URL(request.url).pathname,
          error: error instanceof Error ? error.message : String(error),
        }),
      );
      return json({ error: "Internal server error." }, 500);
    }
  },
  async scheduled(
    controller: ScheduledController,
    env: Env,
  ): Promise<void> {
    try {
      const processed = await processRetryBatch(
        env,
        new Date(controller.scheduledTime),
      );
      console.log(
        JSON.stringify({
          message: "Scheduled translation retry completed.",
          processed,
        }),
      );
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "Scheduled translation retry failed.",
          error: error instanceof Error ? error.message : String(error),
        }),
      );
      throw error;
    }
  },
  async queue(
    batch: MessageBatch<TranslationQueueMessage>,
    env: Env,
  ): Promise<void> {
    for (const message of batch.messages) {
      try {
        const claim = await claimQueuedTranslationByID(
          env.DB,
          supportedTargetLocale,
          message.body.entryID,
          new Date(),
        );
        if (claim) {
          await resolveNewTranslation(
            env,
            `queue-${claim.id}`,
            claim.source,
            claim.id,
            new Date(),
          );
        }
        message.ack();
      } catch (error) {
        console.error(
          JSON.stringify({
            message: "Queued translation processing failed.",
            entryID: message.body.entryID,
            error: error instanceof Error ? error.message : String(error),
          }),
        );
        message.retry({ delaySeconds: 60 });
      }
    }
  },
} satisfies ExportedHandler<Env, TranslationQueueMessage>;

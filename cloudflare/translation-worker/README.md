# Hanger Express Translation Control Plane

Cloudflare foundation for shared English-to-Simplified-Chinese item translation.
The public Worker translates each eligible unique source once, stores the
suggestion in D1 for review, and serves the approved dictionary from R2. A
separate administration Worker provides the review interface against the same
D1 and R2 resources.

The separately controlled iOS rollout, privacy allowlist, and opt-in behavior
are specified in [`IOS_INTEGRATION_PLAN.md`](./IOS_INTEGRATION_PLAN.md).

## Current scope

- `POST /v1/translations/resolve`
- `GET /item-translations/zh-Hans.json`
- `GET /health`
- An independently deployed, Cloudflare Access-protected administration Worker
  and review interface that also fails closed in application code.
- Access-protected manual dictionary entry with a pending-impact preview and
  automatic glossary-aware regeneration of matching suggestions.
- Replay-safe import of an existing curated `zh-Hans` dictionary into D1.
- D1 concurrency claims prevent duplicate AI work.
- Unreviewed machine suggestions never leave the review queue; the public API
  reports `pending` without returning their text.
- Failed claims become retryable after `retry_after`, and abandoned generation
  leases can be reclaimed after ten minutes.
- D1 daily request and character budgets bound Workers AI usage.
- Only catalog-like translation kinds are accepted.
- Published dictionaries are served from immutable R2 release objects.

The administration Worker is protected by Cloudflare Access. Its review
console includes atomic publication and rollback controls.

## Development deployment

- Worker: `https://hangar-express-translations.liuchen2004.workers.dev`
- Administration Worker:
  `https://hangar-express-translation-admin.liuchen2004.workers.dev`
  (Access-protected)
- D1 database: `cn-translation`
- R2 bucket: `cn-translation-bucket`

## Privacy boundary

Only public-facing catalog terminology may be sent to this Worker. The current
allowlist covers ships, manufacturers, paints, items, insurance, packages,
roles, and upgrades. Buyback notes, hangar-log reasons, raw page content,
identifiers, and user-entered text must remain on device.

## Create Cloudflare resources

```bash
npm install
npx wrangler d1 create cn-translation
npx wrangler r2 bucket create cn-translation-bucket
```

Copy the returned D1 database ID into `wrangler.jsonc`, replacing
`REPLACE_WITH_PRODUCTION_DATABASE_ID`.

Apply the schema:

```bash
npx wrangler d1 migrations apply cn-translation --local
npx wrangler d1 migrations apply cn-translation --remote
```

## Import the current curated dictionary

Build a validated SQL import from the hosted dictionary:

```bash
npm run build-import -- /path/to/zh-Hans.json /tmp/zh-Hans-import.sql
```

Test it against local D1 first:

```bash
npx wrangler d1 migrations apply cn-translation --local
npx wrangler d1 execute cn-translation --local \
  --file /tmp/zh-Hans-import.sql
```

Before changing production, export a rollback backup. Then apply the migration
and import:

```bash
npx wrangler d1 export cn-translation --remote \
  --output /tmp/cn-translation-before-import.sql
npx wrangler d1 migrations apply cn-translation --remote
npx wrangler d1 execute cn-translation --remote \
  --file /tmp/zh-Hans-import.sql
```

Curated rows are stored as approved entries with their aliases and source
dictionary metadata. Re-imports can refresh curated or unreviewed runtime rows,
but do not overwrite entries whose origin is `human` or runtime entries that
have already been approved or edited. Wrangler executes the remote SQL file
atomically; the generated file intentionally does not include its own
`BEGIN TRANSACTION` statement because remote D1 rejects nested transaction
control.

## Administration Worker

The dedicated administration Worker contains:

- `GET /admin/`
- `GET /admin/api/session`
- `GET /admin/api/summary`
- `GET /admin/api/translations`
- `GET /admin/api/translations/:id`
- `POST /admin/api/translations/:id/review`
- `POST /admin/api/translations/:id/revisions/:revision/restore`
- `GET /admin/api/glossary/preview`
- `POST /admin/api/glossary`
- `GET /admin/api/releases`
- `POST /admin/api/releases/publish`
- `GET /admin/api/releases/:from/compare/:to`
- `POST /admin/api/releases/:version/rollback`

The list endpoint supports `status`, `kind`, `q`, `cursor`, and `limit`.
Review actions are `approve`, `edit`, `reject`, and `defer`. Every mutation
requires the row version loaded by the reviewer, rejects stale concurrent edits
with `409`, and records the verified email, previous value, new value, status,
and timestamp in `translation_revisions`.

Manual dictionary entries are stored as human-edited approved terminology in
the same authoritative table used by the translation planner. Before saving,
the review interface previews pending entries that contain the English phrase
using the planner's case-insensitive word boundaries. Saving records an audit
revision, marks the working dictionary dirty, and queues matching pending
suggestions through the existing bounded Workers AI retry job. The public
dictionary remains unchanged until the working set is published.

Restoring a revision never rewrites or removes history. It restores the
revision's previous translation as a new human edit, records another revision,
and marks the working dictionary dirty. The live R2 dictionary does not change
until that edit is published.

Publishing likewise requires the exact `dictionary_state.changed_at` value
loaded by the reviewer and accepts an optional 240-character release note. It
writes a new versioned R2 object with an
`If-None-Match: *` precondition, reads it back, validates its bytes and
SHA-256, size, locale, version, entry-count, and custom metadata, then
transactionally changes the D1 current-release pointer. Rollback performs the
same complete validation on a retained superseded object before reactivating
its pointer and recording an audit event. Release comparison independently
validates both retained R2 objects before calculating additions, removals, and
changed translations. Failed and superseded objects are never overwritten.

`ADMIN_API_ENABLED` must be `true` together with a valid Cloudflare Access team
domain and application audience. The production configuration is scoped to the
Access-protected administration Worker. The Worker still fails closed if the
JWT configuration is missing or invalid and validates the Access JWT signature,
algorithm, issuer, audience, and email claim.

The public and administration Workers are intentionally separate. Direct Worker
protection in Access can secure every administration route without blocking the
public iOS translation endpoint.

### Local review UI

Run the admin Worker with an explicit localhost reviewer:

```bash
npx wrangler d1 migrations apply cn-translation --local
npm run dev:admin -- \
  --var ADMIN_API_ENABLED:true \
  --var ADMIN_DEV_EMAIL:reviewer@local.test
```

Open `http://localhost:8787/admin/`. `ADMIN_DEV_EMAIL` is accepted only when the
request hostname is exactly `localhost` or `127.0.0.1`; it cannot enable a
deployed Worker.

### Cloudflare Access setup and recovery

The production Access application is already configured. The following steps
are the reproducible setup/recovery procedure, not outstanding deployment work.

1. Deploy the administration Worker only after creating its Access application:

   ```bash
   npm run deploy:admin
   ```

2. In Cloudflare Zero Trust, create a self-hosted Access application whose
   destination is the Worker named `hangar-express-translation-admin`.
3. Add an Allow policy for the exact reviewer email. Do not add an Everyone or
   Bypass policy.
4. Copy the Zero Trust team domain and the application's Audience (`AUD`) tag.
5. Store the verified non-secret Access identifiers in
   `wrangler.admin.jsonc`, then deploy:

   ```bash
   npx wrangler deploy --config wrangler.admin.jsonc
   ```

6. Confirm an unauthenticated request is stopped by Access, sign in as the
   allowed reviewer, and confirm `/admin/` loads. Test one defer action before
   approving or editing production suggestions.

## Verified production baseline

Verified on 2026-07-26:

- All four D1 migrations are applied.
- The curated import contains 367 authoritative entries; one reviewed runtime
  suggestion brings the current published dictionary to 368 entries.
- D1 release version 3 is current and the working dictionary is clean.
- R2 `releases/zh-Hans/v3.json`, the D1 release checksum, and the public
  dictionary bytes all share SHA-256
  `ae4f69d4ab18575597a9123e128728de229a53e3d45b9da27a27823201c2b75b`.
- The public route returns version `3`, entry count `368`, and ETag
  `"06780a4702445a93bb31b452c3a0f2cb"`; a matching request returns `304`
  without a response body.
- An unauthenticated admin request is redirected to Cloudflare Access.
- Admin rollback hardening and explicit Simplified Chinese font fallbacks are
  deployed as Worker version `34e42c42-1913-4fd7-b0ba-af99ccadeb00`.
- Public request-cost safeguards and atomic daily AI-failure accounting are
  deployed as Worker version `05f7f309-614a-4231-8982-362ea7f07d86`;
  production probes verify `415` for non-JSON requests, `413` above 32 KiB,
  and rejection above six items without consuming additional Workers AI
  budget.

The release workflow was exercised with a real correction to `Combat Support`
from `战场支援` to `战斗支援`: version 2 was published and independently matched
against its immutable R2 object, then rolled back to version 1. A client holding
the superseded v2 ETag correctly received `200` with the lower-version v1 body.
The corrected working set was then published forward as version 3. Versions 1
and 2 remain retained and superseded, the rollback and publish events are
audited to the verified Access identity, and the protected comparison UI
reports exactly one changed entry with no additions or removals.

Review requests must use `Content-Type: application/json`. Example:

```json
{
  "action": "edit",
  "translation": "120 个月保险",
  "expectedUpdatedAt": "2026-07-26T20:30:00.000Z"
}
```

Revision restoration uses the translation row version loaded by the reviewer:

```json
{
  "expectedUpdatedAt": "2026-07-26T20:30:00.000Z"
}
```

Publishing may include a release note:

```json
{
  "expectedChangedAt": "2026-07-26T20:31:00.000Z",
  "note": "Corrected insurance terminology"
}
```

## Develop and test

```bash
npm test
npm run typecheck
npm run dev:public
```

Local request:

```bash
curl http://localhost:8787/v1/translations/resolve \
  --request POST \
  --header 'content-type: application/json' \
  --data '{
    "sourceLocale": "en",
    "targetLocale": "zh-Hans",
    "dictionaryVersion": 1,
    "items": [
      {
        "clientID": "0",
        "source": "120 Month Insurance",
        "kind": "insurance"
      }
    ]
  }'
```

## Cost controls

The development configuration permits at most 100 new AI translations and
10,000 input characters per UTC day. Cached translations do not consume this
budget. Exhaustion returns an `unavailable` result and never blocks the app.

Resolve requests must be JSON, are streamed through a 32 KiB body ceiling, and
contain no more than six items. Six is the hard code ceiling even if a deployed
environment variable is accidentally raised; it keeps the worst retry path
below the Workers Free-plan subrequest limit. Repeated sightings update their
D1 popularity counter at most once per source per hour to bound write
amplification.

Workers AI exceptions atomically mark the claimed translation failed and
increment that UTC day's `ai_failures` counter. Budget exhaustion is recorded
as an unavailable translation but is not misclassified as an AI provider
failure.

Runtime misses are suggestion requests, not an alternate translation feed. The
app keeps displaying its English source until a reviewer approves or edits the
suggestion and publishes a new dictionary release.

These limits are safety ceilings, not targets. Production rollout should begin
with lower values and Cloudflare notifications.

## Release rules

The app-facing dictionary payload must remain compatible with
`HostedHangarItemTranslationClient`. A publisher must:

1. Validate all approved entries and normalized aliases.
2. Generate an immutable `releases/zh-Hans/v{version}.json` object.
3. Read and validate the object after writing it.
4. Mark the new D1 release current only after validation.
5. Preserve the preceding R2 object and release row for rollback.

The public dictionary route additionally compares the R2 object's checksum,
locale, version, and entry-count metadata with the current D1 release pointer
before serving it. A mismatch fails closed with `503`. Successful responses
include an ETag, checksum, dictionary version, and entry count; matching
`If-None-Match` requests return `304`.

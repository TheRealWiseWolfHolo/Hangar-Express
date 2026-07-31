# iOS Cloud Suggestion Integration

The queue-only iOS foundation is implemented but remains disabled behind
`CloudHangarItemTranslationRollout.isEnabled`. Cloudflare Access now protects
the review console and production dictionary version 3 is published and
verified after a complete v2-to-v1 rollback drill; enabling iOS submission is
still a separate product decision.

## Current implementation status

- Gates 1–3 are complete: Access is enabled, production version 3 is verified,
  and the Cloudflare dictionary is the first iOS feed with Pages and GitHub
  retained as fallbacks.
- The iOS client requires Cloudflare responses to carry a matching SHA-256,
  dictionary version, entry count, and ETag. Invalid Cloudflare metadata is
  rejected and the client continues to the existing backup feeds.
- A focused compatibility test proves that a fresh feed load accepts a verified
  lower version, allowing a production v2-to-v1 pointer rollback to reach the
  app without weakening dictionary validation.
- Gates 4–6 are implemented behind the disabled rollout flag: the structured
  privacy classifier, queue client, versioned retry state, and settings picker
  all compile in the app.
- The migration-safe effective mode is always **On Device** while the rollout
  flag is false, even if a future preference value is already stored.
- Both background preprocessing and the ship-description on-demand translation
  path use the same effective-mode gate. Cloud Review therefore cannot invoke
  Apple Translation when the rollout is enabled.
- Gate 7 has not started. Do not switch the rollout flag until an internal
  queue-only release is explicitly approved.
- The release-control drill is complete: a real v2 correction was published,
  immutable v1 was reactivated and served to a client holding the old v2 ETag,
  and the corrected working set was published forward as v3. D1, R2, the
  public feed, release comparison, and audit events all matched.

## User-visible behavior

The curated hosted dictionary remains the first translation source in every
mode. A new setting controls only what happens when that dictionary misses:

- **On Device** (default): preserve the current Apple Translation framework
  fallback and its local cache.
- **Cloud Review** (opt-in): queue eligible catalog terminology for review,
  keep displaying the original English text, and receive translations only
  through a later approved hosted dictionary release.

Cloud Review must never display a `pending` machine suggestion returned by the
resolve API. The Worker also enforces this by omitting suggestion text until a
row is approved.

Changing modes does not change the selected item language and does not erase
either cache. Clearing the translation cache continues to clear the downloaded
dictionary and on-device cache; the cloud review queue is server-side and is
not user-specific.

## Privacy allowlist

Build cloud requests from structured `HangarSnapshot` fields, not from generic
rendered strings. The initial mapping is:

| Snapshot field | Cloud kind |
| --- | --- |
| Package title | `package` |
| Package content item title | `item` |
| Fleet ship display name | `ship` |
| Upgrade source and target ship names | `ship` |
| Fleet manufacturer and normalized manufacturer display name | `manufacturer` |
| Fleet role and role categories | `role` |
| Paint title when the domain model identifies it as paint | `paint` |
| Insurance label when the domain model identifies it as insurance | `insurance` |
| Upgrade title constructed only from public ship names | `upgrade` |

Never submit:

- Buyback notes or raw buyback page fields.
- Hangar log reasons, timestamps, or user-entered annotations.
- Account handles, email addresses, identifiers, prices, serials, or pledge IDs.
- Cookies, credentials, request URLs, debug logs, or raw HTML.
- Generic combined display strings such as `category • detail` unless every
  component has first been classified independently as eligible catalog data.

The client and Worker both enforce limits; the client-side classifier is a
privacy boundary, while the Worker validation is defense in depth.

## Client contract

Add a small actor-backed client with an injectable `URLSession` and base URL:

```text
POST /v1/translations/resolve
sourceLocale = en
targetLocale = zh-Hans
dictionaryVersion = currently loaded version
items = at most 6 classified unique misses
```

Each item gets a deterministic client ID derived locally from its normalized
source and kind. The ID is for response correlation only and must not contain
account or inventory identifiers.

The client accepts only these result semantics:

- `approved`: may be used only if a future product decision explicitly enables
  immediate approved-row lookup; the initial release still waits for the hosted
  dictionary to preserve one authoritative delivery path.
- `pending`: queued successfully; display English.
- `rejected`: do not resubmit until the dictionary version changes.
- `ineligible`: do not resubmit.
- `unavailable`: retry with bounded exponential backoff.

Persist only normalized source hashes, kind, last submitted dictionary version,
and retry time. Do not persist a server-provided machine suggestion.

## Batching and cost behavior

- Deduplicate by normalized source plus kind before network work.
- Submit at most 6 items per request. This keeps even the retry path beneath
  the Workers Free-plan subrequest ceiling.
- Permit one request at a time.
- Do not resubmit a successful `pending`, `rejected`, or `ineligible` source for
  the same dictionary version.
- Retry `unavailable` after 1 hour, then 6 hours, then the next UTC day.
- Run after the hosted dictionary has loaded and only on a user snapshot that
  is already available; never delay rendering or refresh.
- Respect Low Data Mode and avoid background cellular retries in the first
  rollout.

The server remains the final cost ceiling with its atomic daily request and
character budgets.

## Controlled rollout

1. Protect and enable the review console with Cloudflare Access.
2. Publish version 1, fetch it from the production Worker, and verify the iOS
   decoder, checksum header, ETag, and fallback behavior.
3. Add the Cloudflare dictionary URL as the first feed URL while retaining the
   existing Pages and GitHub feeds as fallbacks.
4. Implement the client and privacy classifier behind an internal feature flag.
5. Add unit tests for every allowed and excluded snapshot field, batching,
   deduplication, retry state, and response decoding.
6. Add the user setting with **On Device** as the migration-safe default.
7. Run an internal queue-only release, review the submitted terms, and inspect
   daily usage before making Cloud Review generally available.

Steps 1–6 are implemented and the production release/rollback mechanics have
been verified independently. Step 7 remains deliberately paused with the app
rollout flag set to `false`.

### Explicit activation procedure

Activation is intentionally a one-line code change followed by validation:

1. Set `CloudHangarItemTranslationRollout.isEnabled` to `true`.
2. Build an internal app release; do not make the mode the default.
3. Select **Cloud Review** on a test account and confirm the request contains
   only allowlisted catalog terms.
4. Review D1 pending rows and Workers usage before approving or publishing.
5. Publish the reviewed queue terms as a new immutable version and verify the
   app receives them only through the hosted dictionary refresh.
6. If the new release needs reversal, reactivate a retained immutable version,
   verify the lower-version public payload and app feed, then publish the
   still-authoritative D1 working set forward as a new version.

## Acceptance gates

- Selecting On Device produces no resolve requests.
- Selecting Cloud Review never invokes Apple on-device machine translation.
- Buyback notes and hangar-log reasons cannot appear in a request fixture.
- Pending machine text cannot reach a rendered UI path.
- Network, budget, D1, R2, and dictionary failures all leave the original
  English source visible.
- A newly approved term appears only after a verified dictionary publication
  and subsequent feed refresh.

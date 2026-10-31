# Inventory presentation and freshness

Snapshots track the last successful refresh and content revision independently
for Hangar/Fleet, Buy Back, Account and Hangar Log. A successful no-op advances
freshness without advancing content. An Account or Log refresh does not make
inventory fresh. Legacy snapshots inherit their old aggregate timestamp once;
subsequent reads maintain section-specific dates. `lastSyncedAt` remains an
aggregate compatibility field, not the inventory auto-refresh clock.

Full Refresh collects independent section outcomes. Successful sections replace
their data; failed sections retain cached values, successful-refresh dates and a
failed-at flag. Packages and their derived fleet always commit together. Account
shows each section's last success and failure state. Authentication failures still
require sign-in. A failed inventory read cannot acknowledge mutation recovery.

## Shared inventory data

`InventoryPresentationBuilder` groups inventories, computes filter flags and
builds member/detail lookups on an actor. Fleet and Buy Back group IDs are computed
once. AppModel accepts an immutable result only while its tracked account owner
and requested key remain current. The key includes account identity, section
revisions and a local content epoch, which also catches legacy/test providers
that change contents without advancing their revision. One current presentation
is retained. Account/Log-only changes reuse inventory data.

Views show a preparation indicator while the matching inventory is built; stale
groups are not offered as current actions. Fleet detail and Buy Back confirmation
state resolve through current stable group IDs. Removed groups dismiss their
pending presentation. Hangar selection waits for matching search data before
pruning IDs. No UI or WebKit objects enter the builder.

## Search lifetime

`InventoryTranslationContext` captures immutable translation inputs. Background
search builds are keyed by inventory, language, dictionary locale/version,
on-device cache generation, section and upgraded-name preference. Each inventory
section retains one current text index, at most three total. Changing account
removes contexts from the previous account. Only the requested section is built.
Each view retains one query result, not a history of arbitrary queries.

Canonical normalization permits fast literal rejection. ASCII matches use a fast
literal path; Unicode candidates also pass Swift's grapheme-aware match. This
preserves accent equivalence and avoids matching individual components inside
joined emoji or combining characters. Filters use precomputed flags; Buy Back's
category precedence is upgrade, skin, gear, package, then standalone. Compiled
constant patterns are reused.

The existing IME-aware local draft/debounce remains in charge of input. Search
index work does not replace typed text. Closing search clears it; lowering the
keyboard preserves it. A cold search index has an explicit preparation state.

## Related boundaries

Snapshot persistence is ordered, coalesced and failure-reporting; see
[account operations](ACCOUNT_OPERATIONS.md). Parsing and normalization have actor
owners. Translation-cache disk loading exposes asynchronous readiness and rejects
late results after a clear. Hosted feeds share conditional requests and validated
fallback data. Image freshness is independent of inventory revisions: unchanged
warm images survive refresh, source changes invalidate dependent outputs, and
explicit Clear Local Cache forces a cold reload. Processed images display without
waiting for network validation; conditional checks run in the post-refresh task.

## Hangar Log updates

Hangar Log observes constant-cost source keys rather than polling. AppModel advances
log epochs when committed entries or incremental preview contents change, including
edits that retain their IDs. The key also includes account context, inventory lookup
identity, subscription limit and image token. Diagnostics and refresh progress
observe their own state without regrouping inventory.

The inventory builder also prepares log navigation lookups from its existing groups.
Unchanged Hangar/Fleet content reuses those lookups through unrelated Buy Back or log
updates. Same-ID package or ship edits rebuild them on the actor. Account boundaries
clear old rows immediately, even during interaction.

During refresh, scrolling or focused search input, newer rows are buffered. The
latest buffered result applies after refresh and the interaction cooldown finish;
“Show loaded log entries” can apply it explicitly. Lowering the keyboard preserves
the query and ends editing; closing search clears it. The only delay task is a
one-shot interaction cooldown, canceled when the view disappears.

## Game-access package popup

Both Account game tiles open a read-only sheet, including when dimmed. The sheet
uses the current account's immutable inventory presentation to list individual
pledges and the explicit game-license contents that matched. The background builder
computes these matches once per inventory revision; opening the sheet never fetches
RSI entitlements. Account access colors/status still come from Account Refresh.

Matching uses explicit game/download/access items, not package marketing names or
ship names. Ambiguous merchandise and generic download labels do not grant matches;
reclaimed/gifted/cancelled pledges are excluded. A shared license item can match both
games. Each pledge copy keeps its own ID. A confirmed account entitlement without
a matching saved package gets an honest empty state, rather than an invented source.
Account/authentication-context changes dismiss the sheet; inventory and language
changes update its contents using existing app mechanisms.

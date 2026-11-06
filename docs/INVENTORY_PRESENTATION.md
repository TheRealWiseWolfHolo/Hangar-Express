# Inventory presentation

## Freshness and refresh

Hangar/Fleet, Buy Back, Account, and Hangar Log have separate refresh dates and
content revisions. A successful no-op refresh advances freshness without rebuilding
unchanged content. Account and Log refreshes do not make inventory fresh.

Full Refresh keeps successful sections and retains cached data for failed sections.
Packages and their fleet projection commit together. Account shows section success
and failure states. Authentication failures still require sign-in.

## Shared groups and search

`InventoryPresentationBuilder` prepares groups, filter flags, and lookups on an
actor. AppModel accepts them only for the current account, section revisions, and
content epoch. Account/Log-only changes reuse unchanged inventory data.

Views show preparation while matching data is built. Detail and confirmation views
resolve current stable group IDs; removed groups dismiss pending presentations.
No UI or WebKit objects enter the background builder.

Search indexes include inventory, language, dictionary version, local translation
cache generation, and display preferences. There is at most one current index per
section, three total, and one current query result per view. Account changes remove
old contexts. Unicode matching preserves accents and joined characters.

Local input/debounce owns typed text. Background search cannot replace newer input.
Dismissing the keyboard keeps the query; closing search clears it. Buy Back category
precedence remains upgrade, skin, gear, package, then standalone.

## Images and logs

Warm unchanged images survive refresh. Source changes invalidate dependent variants;
same-URL images can be revalidated. Processed images display before background
network validation. Clear Local Cache forces a cold reload.

Hangar Log follows content events instead of polling, including same-ID edits.
It reuses inventory navigation lookups. Refresh, scrolling, and search editing
buffer incoming rows until interaction settles; the user can apply loaded entries
explicitly. Account changes clear old rows immediately.

## Game access and referrals

Tapping either Account game tile opens matching saved packages, individual pledge
IDs, and explicit license contents. This does not request new RSI entitlements.
Status and brightness still use saved Account Refresh results.

Matching uses license contents, not marketing names or ship names. Removed, gifted,
reclaimed, and cancelled pledges are excluded. Missing matches get an empty state;
the app never invents a package to explain a known entitlement.

Reached referral rewards can open existing Hangar details. Matching runs on an
actor only when tapped. Multiple matches get a chooser; missing matches get a
refresh message. See [referrals](REFERRALS.md).

Account/authentication changes dismiss these sheets. Inventory and language changes
update their contents or cancel stale matching. Normal detail actions retain the
same authentication checks. See [account operations](ACCOUNT_OPERATIONS.md).

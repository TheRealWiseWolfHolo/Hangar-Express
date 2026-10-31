# Referral rewards

Account → Tools → Referrals is an Early Access tool, labeled with the existing badge and member entry check (the same policy as WBCCU Deals). The Early Access page shows check/cross availability symbols and an expected release of 1.2.0 for Referrals (the other four Labs features remain TBD). Existing Account snapshot referral counts remain available independently of the tool.

The tool shows the current or legacy reward ladder, with pictures and the referral counts saved by Account/Full Refresh. Opening the tool does not sign in to RSI or refresh the account. It cannot claim rewards or submit referrals.

The two counts are independent. Missing counts are never shown as zero. If the saved account has no legacy ladder, the legacy catalog is view-only, without a personal milestone status or progress bar. Switching accounts or authentication contexts dismisses the tool.

## Shared catalog

`HostedReferralRewardsClient` uses `ValidatedHostedFeedStore` for shared requests, conditional validation, atomic disk caching and offline fallback. The static catalog has a one-day in-memory freshness ceiling and a one-year maximum offline fallback, subject to the server's cache directives. Failed or malformed responses cannot replace a validated catalog. Reward pictures use the existing processed image cache.

Schema 1 contains `reviewedAt` plus `current` and `legacy` arrays. Each reward has a positive unique `threshold` (ascending), a `title`, an HTTPS `imageURL`, and optional validated `imageAspectRatio` metadata to preserve the complete picture. Both ladders must be nonempty. The decoder rejects unsupported versions, oversized documents, duplicate/unsorted milestones, and credential-bearing image URLs. Personal counts, invite codes, account IDs and cookies are never part of this feed.

The catalog contains public reward descriptions and artwork. Catalog updates do not require an RSI account session.

## Private release configuration

Supply `REMOTE_REFERRAL_REWARDS_BASE_URL` in the private build configuration. It maps to the `RemoteReferralRewardsBaseURL` Info.plist key; the client appends `referral-rewards.json`. No production host, cloud resource ID or cloud credential belongs in tracked files. A Debug checkout without this setting shows the normal retry/unavailable screen. Release builds require the setting through the existing private-configuration validation gate; offline Release benchmarks supply a placeholder endpoint.

## Checks

`ReferralRewardsTests` covers separate counts, zero versus missing counts, unavailable legacy progress, catalog validation, unauthenticated requests and offline restoration. The opt-in UI fixture covers New/Legacy switching and view-only behavior in dark and light appearances without a live RSI account. Small public reward pictures are bundled only in the test runner and injected into the explicit test fixture for realistic screenshot checks. Reached cards use green only in the title/count/status footer. Photos keep their original colors and the outer border stays neutral. Missing counts and unavailable legacy progress retain neutral cards. Each ladder button includes its padding in a rectangular hit area; UI checks tap blank areas near the left/right and top/bottom edges. Public cloud assets are validated separately by the private publishing checks.


Legacy artwork measures the loaded UIImage through the cached image view's
optional size callback. That measured ratio takes precedence over catalog metadata,
so older offline catalogs without dimensions (or outdated dimensions) cannot add
letterbox gutters. The New ladder retains its existing sizing path. UI regression
checks include wide, standard and taller legacy pictures with missing/wrong metadata.


Reached reward cards open the existing HangarPackageDetailView for matching saved
pledges. Matching runs on a dedicated actor using the existing inventory groups;
it never creates synthetic ownership, downloads account data, or scans inventory
on every render. Known referral wrappers, quote/ampersand formatting, and legacy
numeric reward titles are supported. Short aliases require referral provenance;
exact named referral pledges take priority over incidental bundle contents. Multiple
matching groups get a picker, missing matches get an honest refresh message, and
unknown/unreached milestones remain noninteractive. Inventory/account/ladder changes
cancel pending matching; inventory changes also clear the navigation destination.
Existing Hangar detail actions retain their normal authentication safeguards.

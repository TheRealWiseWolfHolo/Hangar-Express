# Referral rewards

Open **Account → Tools → Referrals**. The tool requires Early Access; saved referral
counts on Account remain available separately. The comparison page lists 1.2.0 as
the expected public release, not a guaranteed release date.

## Browsing and progress

- Browse current and legacy reward ladders with pictures.
- Use the independent counts saved by Account/Full Refresh.
- Show missing counts as unknown, never zero.
- Browse the legacy catalog without personal progress when no legacy ladder is available.
- Highlight only the text footer of reached rewards; preserve original picture colors.

Opening the tool does not sign in to RSI, refresh counts, submit referrals, or
claim rewards. Account/authentication changes dismiss it. Legacy pictures use
loaded image dimensions when catalog sizing is missing or wrong.

## Open a saved reward

Tap a reached reward to find a real matching saved Hangar package. Multiple matches
show a pledge chooser; no match shows a refresh/preparation message. Unknown and
unreached rewards stay noninteractive. The tool never invents ownership.

Matching runs on an actor only on tap. It handles known referral names and wrappers,
requires referral provenance for short aliases, and excludes removed/gifted items.
Account, inventory, and ladder changes cancel stale work. The destination is the
normal Hangar detail view, with its existing action and authentication checks.

## Public catalog and private configuration

The catalog contains public reward descriptions and artwork, not personal counts,
invite codes, account IDs, or cookies. `HostedReferralRewardsClient` uses shared
requests, conditional validation, atomic caching, and validated offline fallback.
Freshness is capped at one day; offline fallback is capped at one year, subject
to cache directives.

Schema 1 has `reviewedAt`, nonempty `current`/`legacy` arrays, and unique ascending
positive thresholds. Rewards include a title, HTTPS image URL, and optional image
aspect ratio. Invalid versions, sizes, URLs, or milestones cannot replace valid data.

Supply `REMOTE_REFERRAL_REWARDS_BASE_URL` privately. The client appends
`referral-rewards.json`; no real host or cloud credential belongs in tracked files.
Unconfigured Debug builds show an unavailable/retry state. Release builds require
the setting. See the [README](../README.md) for all private build settings.

## Checks

Tests cover counts, catalog validation, unauthenticated catalog requests, offline
restore, reached-item matching, and dark/light layouts. Reward pictures used by
explicit UI fixtures are test-runner assets only. See [asset sources](../ASSET_SOURCES.md)
and [testing](TESTING.md).

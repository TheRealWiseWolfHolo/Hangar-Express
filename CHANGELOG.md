# Changelog

## v0.5 (In Progress)

### Changed
- Moved active development onto the `v0.5` branch for the next round of account-page polish.
- Removed the account profile card's top-right organization and email icons for a cleaner presentation.
- Updated the account profile card to use the highest-MSRP owned ship with a known value as a cropped background image.
- Added a profile-card background picker so each account can save any owned ship as its preferred card background, with an automatic highest-MSRP fallback.

### Fixed
- Stopped Fleet from silently dropping unmatched ship entries when the hosted catalog cannot identify an exact ship variant, which restores missing capitals like some Idris pledges.
- Improved legacy fleet ship matching so older RSI names like `Idris-M Frigate`, `Idris-P Frigate`, `Mk1`, and older Hornet variants that omit `Super` now resolve to hosted MSRP, thumbnails, and full manufacturer names when the catalog has them.
- Changed `Clear Local Cache` to warn that a full reload is required, then clear cached snapshots and images before immediately rebuilding the live account data.
- Changed expired or missing RSI session cookies to trigger a dedicated re-login flow instead of a generic refresh failure, while keeping cached data visible when possible.

## v0.4 (In Progress)

### Added
- Added a stronger unofficial-app warning to the login screen so users see that Hangar Express is not an official RSI app before signing in.

### Changed
- Replaced the custom repository license file with an all-rights-reserved setup plus a separate limited personal-use permissions notice.
- Clarified the legal copy to state that Star Citizen, Squadron 42, RSI, and related game content shown by the app belong to the Cloud Imperium group of companies and their respective owners.

## v0.3 (In Progress)

### Added
- Added RSI store credit to the account snapshot when the live session exposes a logged-in account balance.
- Added a legal settings section plus repository disclaimer and custom personal-use license documents.

### Fixed
- Changed the account snapshot so the main value now shows current value and the smaller sublabel shows melt value.
- Tightened the account snapshot into a denser two-column layout so the extra summary cards fit more cleanly.
- Stopped live current-value totals from always mirroring melt by using the hosted ship MSRP feed for ship and CCU-based packages when available.
- Improved live store-credit retrieval by opening the top-right account avatar panel and reading the Store Credit row directly.
- Moved ship MSRP and CCU actual-value enrichment off the in-app RSI storefront flow and onto the hosted `ships.json` catalog.
- Persisted the last synced hangar snapshot on disk so normal build-to-build app updates can reopen cached data without forcing an immediate live reload.
- Fixed Fleet so unmatched FPS equipment no longer shows up under `Unknown`, and `GREY` catalog items now group under `Grey's Market`.
- Grouped duplicate ships in Fleet into counted rows so identical ships do not render multiple separate entries.
- Changed grouped hangar and fleet rows to show per-item values instead of reading like combined totals.
- Removed the always-zero recovered-value line from Buy Back rows to keep that list cleaner.
- Switched store-credit retrieval away from brittle avatar-popover scraping to RSI's structured `accountDashboard` credits data, with the side panel kept as a fallback path.
- Fixed store-credit normalization so RSI's structured balance now treats the last two digits as cents instead of whole dollars.

## v0.2 (In Progress)

### Added
- Started the `v0.2` release branch and patch notes tracking for ongoing work.
- Added a new `Account` tab to hold account-specific summary information.
- Added multi-account session storage so multiple RSI logins, cookies, and saved credentials persist in Keychain at the same time.
- Added an account switcher in `Settings` with one-tap switching plus an `Add Another Account` flow.
- Added saved-account buttons on the login screen so stored RSI sessions can be reopened without typing credentials again.
- Added a searchable buy-back list with search-activated quick filters for skins, ships, packages, and upgrades.

### Fixed
- Updated the RSI verification code field to accept letters and numbers instead of a numbers-only keyboard.
- Normalized verification codes to uppercase alphanumeric characters while typing so RSI email codes paste cleanly.
- Moved the hangar snapshot summary out of the `Hangar` tab and into the new `Account` tab.
- Moved `Settings` behind an account-screen toolbar button instead of keeping it as a standalone tab.
- Added common hangar search filters for `LTI`, `Upgrades`, and multi-ship `Packages`.
- Migrated older single-account saved sessions forward automatically so existing users keep their current cookies after upgrading.
- Hid the hangar’s common search filters until the search bar is active so the list stays cleaner when not searching.
- Fixed live hangar refresh so short pledge pages no longer get treated as the last page before the full hangar is synced.
- Raised the live RSI pagination safety limits and stopped silently truncating very large hangars mid-refresh.
- Grouped exact duplicate hangar items into counted rows while still keeping near-matches, like giftable versus locked copies, separated.
- Fixed missing hangar thumbnails for flair and other single-item pledges by using RSI’s pledge-card thumbnail instead of only item-detail images.

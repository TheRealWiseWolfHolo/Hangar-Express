# Changelog

## v1.0.9 (In Progress)

### Added
- Added a WBCCU Deals tool that displays current StarCitizen-Info Warbond upgrade offers with ship artwork, standard and Warbond values, savings, and feed freshness.
- Added an Event Calendar tool with official CIG and Bar Citizen dates from StarCitizen-Info, agenda and location filters, in-app event sources, sharing, Calendar export, and an offline last-known-good feed.
- Added clearly labeled anticipated dates for nine major annual Star Citizen events, projected from their official 2025 month/day windows.

### Changed
- Started the `1.0.9` release branch and release-note tracking for ongoing work.
- Set the app release metadata to version 1.0.9, build 45.
- Began the Early Access overhaul with a compact Settings status row and moved the profile badge preference into Manage Plans, while preserving existing StoreKit product IDs and saved entitlement keys so current access carries forward after updating.
- Removed duplicate lifetime-plan details from the Early Access status card so lifetime owners see one concise Lifetime Access line.
- Kept Manage Plans card fills and borders visible when expanding the sheet to full height.
- Shortened the Early Access notice by removing its redundant affiliation footer.
- Simplified the Early Access feature comparison labels and values for faster scanning.
- Reworded Manage Plans headings, restore controls, guidance, and StoreKit status messages to avoid purchase terminology.
- Clarified that Early Access support funds Hangar Express only, does not buy anything from CIG or RSI, and does not guarantee specific or continued app features.
- Reframed the Early Access status message around Hangar Express being free and supporter contributions being optional.
- Identified Hangar Express as open-source software in its legal disclaimer and removed the Official RSI Website link.
- Replaced the broken WBCCU store link with an in-app cart that clears the RSI cart through its authenticated cart mutation, verifies it is empty, prepares only the selected source-to-Warbond upgrades, and opens checkout inside Hangar Express.
- Simplified WBCCU deal cards by removing redundant availability and new-money labels and shortening the cart status text.
- Simplified the WBCCU footer to show only the feed's last-updated time above the cart controls.
- Hid WBCCU checkout controls for an empty cart and made them float at the bottom of the screen while the cart contains upgrades.
- Added a compact red Clear Cart action to the floating WBCCU checkout controls.
- Reorganized Tools into a compact two-column grid with icon tiles and concise titles.
- Added persistent drag reordering to the Tools grid after a deliberate one-second hold.
- Renamed the Tools grid entries with shorter, clearer English and Simplified Chinese labels.
- Moved cloud terminology generation into a durable background queue and made the app upload up to four batches in parallel, so catalog-term submissions finish quickly on the phone while generation and retry work continue in the cloud.
- Simplified the Cloud Review privacy message to clearly state that only text needing translation is uploaded and that uploads contain no personally identifiable information.
- Reduced Cloud Review upload latency by sending validated text directly to Remote Queues in batches of up to 50, leaving every database lookup and AI task to the background consumer, and hiding the upload progress bar as soon as queueing completes.

### Fixed
- Fixed tool reordering so the selected icon follows the drag while surrounding icons animate into place, instead of lifting the entire Tools section.
- Fixed the dragged tool remaining enlarged after release and removed animation lag from finger tracking. Tool tiles now grow throughout the full one-second hold, provide a haptic cue when reordering activates, use a scroll-cooperative recognizer before activation, and disable page scrolling while an icon is being dragged.
- Fixed Logged-In Device Management for valid RSI sessions whose authentication cookies are HttpOnly by supplying the native session tokens to device requests, while treating RSI's HTTP 200 `ErrNotAuthenticated` response as an expired session that requires sign-in.

## v1.0.8 (In Progress)

### Added
- Added the ability to request an RSI character repair from Hangar Express when an account is eligible.
- Added left-swipe CCU exclusions to the calculator, with immediate path recalculation and an option to restore excluded upgrades.
- Added image export actions to save or share complete CCU calculations, plus a direct Save to Photos action for Hangar share pictures.

### Changed
- Made ship selection feel smoother in the CCU calculator.
- Simplified the CCU calculator summary to clearly show destination MSRP, melt value, total savings, and the payment breakdown.
- Renamed the untranslated Item Language option from Original to English.
- Standardized displayed dates as MM/DD/YYYY in English and YYYY/MM/DD in Simplified Chinese.
- Made Hangar and Fleet images appear sooner while scrolling quickly.
- Changed Hangar Log so it opens right away and starts showing entries in groups of 10 as they load.

### Fixed
- Fixed CCU calculator totals so the source ship is valued at its owned melt value, or MSRP when it is not owned, and added a value choice when owned copies have different melt values.
- Fixed Early Access renewal and auto-renewal details getting stuck on Checking until Manage Plans was opened.
- Fixed Hangar Log refreshes that could look empty or frozen while entries were still loading.
- Reduced app slowdown during Hangar Log refreshes.

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

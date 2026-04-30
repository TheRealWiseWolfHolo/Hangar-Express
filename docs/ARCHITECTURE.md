# Hangar Express Architecture

## Product Goal

Build a clean iOS app that helps a Star Citizen player answer three questions quickly:

1. What is in my hangar right now?
2. How is that hangar organized as ships, upgrades, packs, and buy-back items?
3. What planning options do I have without touching risky account actions?

The Android app at `summerkirakira/Starcitizen-lite` is useful as a feature inventory, but not as a direct architecture template. Its scope is broad, its implementation is tightly coupled to reverse-engineered RSI endpoints, and much of the product logic is mixed into the UI layer.

## Guiding Decisions

- Use `SwiftUI + Observation` for the app layer.
- Keep domain models independent from RSI HTML or GraphQL shapes.
- Treat RSI integration as an adapter, not as the center of the app.
- Prefer a browser-backed session to direct credential entry.
- Ship a read-only organizer first.

## Recommended Module Layout

```text
Hangar Express/
  App/
    AppEnvironment.swift
    AppModel.swift
  Core/
    Domain/
      HangarModels.swift
    Protocols/
      HangarRepository.swift
      SessionStore.swift
  Features/
    Onboarding/
    Shell/
    Hangar/
    Fleet/
    Buyback/
    Settings/
  Services/
    Preview/
    Live/
      Session/
      Remote/
      Parsing/
      Cache/
  Shared/
    Formatters/
```

## Domain Model

The app should own these concepts:

- `UserSession`
  - Who is signed in
  - How the session was established
  - Session notes for support/debugging
- `HangarSnapshot`
  - Timestamped local view of the account
  - Packages
  - Fleet ships
  - Buy-back items
  - Derived metrics
- `HangarPackage`
  - Pledge/package identity
  - Original and current values
  - Gift/reclaim/upgrade flags
  - Insurance
  - Included items
- `FleetShip`
  - Ship-centric projection used for browsing by manufacturer, role, insurance, or source package
- `BuybackPledge`
  - Reclaimed items that remain useful for planning

This split matters because the live RSI pages expose hangar data in a package-oriented way, while the organizer experience is often ship-oriented.

## App Flow

1. App launches into `AppModel`.
2. `AppModel` loads any locally stored session reference.
3. If no session exists, the user sees onboarding and chooses a sign-in path.
4. `HangarRepository` fetches and normalizes remote data into `HangarSnapshot`.
5. Feature views render from normalized models only.

## Live Integration Design

As of April 17, 2026, the relevant RSI surfaces still appear to be:

- `/account/pledges`
  - Authenticated HTML page for the hangar/pledge list
- `/account/buy-back-pledges`
  - Authenticated HTML page for buy-back items
- `/graphql`
  - Live GraphQL endpoint used by the website
- `/api/account/pledgeLog`
  - Account history endpoint referenced by community tooling
- `/pledge-store/api/upgrade/graphql`
  - Upgrade metadata surface for later CCU planning

### Auth Recommendation

Do not start with email/password fields inside the app.

Preferred order:

1. Embedded browser-backed login flow that lets RSI handle 2FA/captcha.
2. Session extraction into a secure local store.
3. Optional developer-only cookie import fallback.

Why:

- The Android reference app contains credential and session-relogin logic that is brittle and high-maintenance.
- RSI account flows can require captcha, multi-step login, or launcher-specific behavior.
- Destructive actions on RSI accounts are high consequence.

### Storage Recommendation

- Keychain for session material.
- Local cache for normalized snapshots.
- Domain models should remain decoupled from the persistence layer so SwiftData, SQLite, or GRDB can be swapped later.

## Feature Phases

### Phase 1

- Browser-backed sign-in
- Read-only hangar sync
- Package list
- Fleet projection
- Buy-back list
- Search, filter, and sort

### Phase 2

- Local tags
- Personal notes
- Insurance filters
- Upgrade-chain friendly grouping
- Snapshot diffs between syncs

### Phase 3

- Alerting for important changes
- Deeper ship metadata enrichment
- Optional cloud sync for user-created organization data

### Explicitly Deferred

- Melt / reclaim
- Gifting
- Applying upgrades
- Cart manipulation
- Store checkout

Those flows should remain out of scope until the session model, legal comfort level, and UX safeguards are all solid.

## Why The Current Scaffold Looks Like This

The code in this repo intentionally starts with:

- `PreviewSessionStore`
- `PreviewHangarRepository`
- feature tabs backed by normalized models

That gives us a stable product shell while the live adapter is designed behind protocols.

## Next Implementation Steps

1. Add `LiveSessionStore` backed by Keychain.
2. Add a `WKWebView` sign-in flow and cookie bridge.
3. Implement `LiveHangarRepository`.
4. Split remote parsing into:
   - authenticated HTML parsers for pledges and buy-back
   - GraphQL clients for store and ship metadata
5. Add a persistence-backed cache layer and snapshot diffing.

# Hangar Express

SwiftUI iOS prototype for retrieving and organizing a Star Citizen hangar.

## Current Focus

- Build a safe, read-only first experience for hangar organization.
- Normalize RSI hangar data into app-owned models for packages, fleet ships, and buy-back entries.
- Keep destructive actions like melt, gift, and upgrade out of v1.

## Repo Shape

```text
Hangar Express/
  App/
  Core/
    Domain/
    Protocols/
  Features/
    Buyback/
    Fleet/
    Hangar/
    Onboarding/
    Shell/
    Settings/
  Services/
    Preview/
  Shared/
docs/
  ARCHITECTURE.md
```

## Live Integration Strategy

The app shell currently uses preview data so we can settle the product structure first. The intended live path is:

1. Sign in through a browser-backed session flow.
2. Capture an authenticated session without storing the RSI account password.
3. Sync hangar pages, buy-back pages, and selected metadata into normalized local models.
4. Organize locally with filters, grouping, notes, and future alerting.

More detail is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Legal

Hangar Express is an unofficial Star Citizen fan project and is not affiliated with the Cloud Imperium group of companies.

This repository is intentionally published without an open-source license. All rights are reserved except for the limited personal, non-commercial permission described in [PERMISSIONS.md](PERMISSIONS.md).

Star Citizen, Squadron 42, Roberts Space Industries, and related names, ships, artwork, and other game content shown or referenced by this app or repository belong to the Cloud Imperium group of companies and their respective owners.

- Fan-project notice and attribution guidance: [DISCLAIMER.md](DISCLAIMER.md)
- Limited personal-use permission notice: [PERMISSIONS.md](PERMISSIONS.md)

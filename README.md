# Hangar Express

SwiftUI iOS app for retrieving, organizing, and acting on a Star Citizen hangar.

## Current Capabilities

- Browser-backed RSI sign-in with saved sessions, local snapshot restore, and developer preview support for Xcode previews.
- Live sync for hangar pledges, fleet ships, buy-back entries, hangar logs, and account details into app-owned models.
- Hosted ship catalog and ship-detail enrichment from `https://starcitizen-info.pages.dev/`, with GitHub Pages as fallback.
- Fleet detail screens enriched with hosted ship specs such as crew, size, components, weapons, and utility entries.
- Fleet card long-press to jump from a ship to the pledges that contain it, reusing the hangar pledge detail flow.
- Melt, gift, and apply-upgrade flows, protected by local device-owner authentication before the RSI action is sent.
- Persistent local image caching for remote ship art and generated upgrade composite thumbnails, with Settings cache clear support.

## Repo Shape

```text
Hangar Express/
  App/
  Core/
    Domain/
    Protocols/
    Security/
  Features/
    Account/
    Buyback/
    Fleet/
    Hangar/
    Onboarding/
    Shell/
    Settings/
  Services/
    Auth/
    Live/
    Persistence/
    Preview/
  Shared/
docs/
  ARCHITECTURE.md
```

## Runtime Notes

The shipped app boots with `AppEnvironment.live`. The preview environment still exists for Xcode previews and demo flows, but the main runtime path is live:

1. Sign in through a browser-backed session flow.
2. Capture and reuse authenticated RSI cookies for refreshes and other read operations.
3. Sync hangar pages, fleet projections, buy-back pages, logs, account metadata, and hosted ship detail data into normalized local models.
4. Use the hosted ship feeds from `starcitizen-info.pages.dev` by default, with GitHub Pages as backup, to enrich fleet and ship-detail UI.
5. For sensitive pledge actions like melt, gift, and apply upgrade, require both local device-owner authentication and the current RSI password because RSI still gates those actions with password-confirmed requests.

More detail is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Legal

Hangar Express is an unofficial Star Citizen fan project and is not affiliated with the Cloud Imperium group of companies.

This repository is intentionally published without an open-source license. All rights are reserved except for the limited personal, non-commercial permission described in [PERMISSIONS.md](PERMISSIONS.md).

Star Citizen, Squadron 42, Roberts Space Industries, and related names, ships, artwork, and other game content shown or referenced by this app or repository belong to the Cloud Imperium group of companies and their respective owners.

- Fan-project notice and attribution guidance: [DISCLAIMER.md](DISCLAIMER.md)
- Limited personal-use permission notice: [PERMISSIONS.md](PERMISSIONS.md)
- Privacy policy for App Store submission: [PRIVACY_POLICY.md](PRIVACY_POLICY.md)
- Terms of use and subscription terms: [TERMS_OF_USE.md](TERMS_OF_USE.md)
- User support page: [SUPPORT.md](SUPPORT.md)

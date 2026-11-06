# Hangar Express

A SwiftUI iOS companion for your Star Citizen hangar. Browse saved items, plan
upgrades, and manage supported RSI account actions.

## Features

- RSI sign-in, saved accounts, and cached data for offline browsing.
- Hangar, Fleet, Buy Back, Account, and Hangar Log views with search and filters.
- Ship details, prices, insurance, package contents, and English/Chinese item names.
- CCU planning, share pictures, trusted-device management, and Character Repair.
- Gift, melt, apply-upgrade, and checkout flows with account and authentication checks.
- Profile game-access indicators that show the matching saved packages when tapped.
- Event Calendar, plus WBCCU Deals and referral rewards for Early Access users.
- Email feedback with optional logs, device details, and selected screenshots.

## Recent updates

Version 1.1.2 checks trusted pages before using RSI credentials, isolates browser
cookies, validates checkout messages, and redacts support diagnostics. Supported
Alipay and WeChat Pay HTTPS pages can stay inside checkout; payment-app links open
the installed app. Feedback attachments are optional and can be reviewed before
sending. See the [changelog](CHANGELOG.md).

## Build and configuration

Open `Hanger Express.xcodeproj` in Xcode. The shared `Hanger Express` scheme runs
the app. Tests use Xcode 27.0 and an iOS 27.0 simulator; see [testing](docs/TESTING.md).

Public configuration values are blank. Supply these settings through ignored
`Config/Local.xcconfig` or a private build configuration:

| Setting | Purpose |
| --- | --- |
| `REMOTE_PRIMARY_BASE_URL` | Primary hosted data feeds |
| `REMOTE_FALLBACK_BASE_URL` | Backup hosted data feeds |
| `REMOTE_TRANSLATION_BASE_URL` | Item dictionary and translation review |
| `REMOTE_IP_REGION_URL` | Sign-in region check |
| `REMOTE_REFERRAL_REWARDS_BASE_URL` | Public referral reward catalog |
| `SUPPORT_EMAIL_ADDRESS` | Feedback recipient shown in the app |

Release builds require all six settings. The five remote settings must use HTTPS.
A Debug build without a support address disables feedback sending. Keep real
addresses, endpoints, credentials, build logs, and private notes out of GitHub.

## Documentation

- [Support](SUPPORT.md) and [email feedback](docs/FEEDBACK.md)
- [Architecture](docs/ARCHITECTURE.md) and [account operations](docs/ACCOUNT_OPERATIONS.md)
- [Security](docs/SECURITY.md) and [network diagnostics](docs/NETWORK_DIAGNOSTICS.md)
- [Inventory presentation](docs/INVENTORY_PRESENTATION.md) and [referrals](docs/REFERRALS.md)
- [Tests](docs/TESTING.md) and [performance measurements](docs/PERFORMANCE.md)

## Project and legal notices

Hangar Express is an unofficial fan app, unaffiliated with the Cloud Imperium group
of companies. Star Citizen, Squadron 42, RSI names, artwork, and related game
content belong to their respective owners.

The source is visible, but it has no open-source license. Personal, non-commercial
use is limited to the permission in [PERMISSIONS.md](PERMISSIONS.md).

See the [disclaimer](DISCLAIMER.md), [asset sources](ASSET_SOURCES.md),
[privacy policy](PRIVACY_POLICY.md), and [terms of use](TERMS_OF_USE.md).

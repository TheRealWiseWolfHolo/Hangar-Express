# Architecture

Hangar Express uses SwiftUI and Observation. `AppEnvironment` supplies live or test
services. `AppModel` owns account state, refreshes, saved data, and account actions.

## Code layout

| Folder | Responsibility |
| --- | --- |
| `App/` | App state, service wiring, and operation ownership |
| `Core/Domain/` | Sessions, snapshots, inventory, and tool models |
| `Core/Protocols/` | Service and storage interfaces |
| `Core/Security/` | Browser origins, cookies, redirects, and diagnostic redaction |
| `Features/` | Account, authentication, checkout, feedback, inventory, and tools |
| `Services/` | RSI adapters, hosted feeds, storage, and preview services |
| `Shared/` | Reusable views, image loading, formatting, and search helpers |

## Data flow

1. Restore a saved session from Keychain and a cached account snapshot.
2. Ask the user to sign in when a session is missing or expired.
3. Fetch RSI data through live services and convert it into app-owned models.
4. Build inventory groups, lookups, and search indexes away from the UI actor.
5. Commit results only if their account, context, and operation are still current.
6. Save accepted snapshots through an ordered persistence coordinator.

`HangarSnapshot` holds packages, fleet data, buy-back entries, account information,
and logs. Each section tracks its own freshness and content revision. Partial
refresh failures keep useful cached data. Hosted catalogs enrich these models;
they do not establish account ownership.

## Accounts and actions

Credentials and reusable cookies are stored in Keychain. Read-only sign-in uses
an RSI browser session without saving a native password. Password-confirmed
account actions are unavailable for read-only accounts.

Sensitive actions use local device authentication and RSI password checks where
required. One mutation gate covers authorization, submission, and reconciliation.
An uncertain submitted action requires review before retrying. Switching accounts
invalidates old local work but cannot undo a request already sent to RSI.

See [account operations](ACCOUNT_OPERATIONS.md).

## Browser security

Login helpers and native RSI credentials are limited to trusted RSI HTTPS origins.
Checkout automation also checks the current cart document and session. Browser
stores are isolated, and authenticated HTTP redirects keep the original origin.

Supported Alipay and WeChat Pay pages may load inside checkout. They receive no
native RSI credential privileges or checkout automation. See [security](SECURITY.md).

## Hosted data and feedback

Hosted feeds share requests, validate responses, and keep usable offline data.
Referral catalogs contain public reward data; personal progress stays in the
account snapshot. See [referrals](REFERRALS.md).

Feedback prepares email through the user's chosen mail app. Optional diagnostics
are sanitized snapshots of local events. Selected images are re-encoded before
sharing. There is no feedback backend or in-app support inbox.

All six service/support settings come from private build configuration. Tracked
settings stay blank; Release builds validate them. See the [README](../README.md).

## Validation

Tests inject fake services, isolated storage, and HTTP fixtures. Offline UI and
performance workloads are opt-in. They do not make live purchases, send support
email, or prove behavior on a signed physical device. See [testing](TESTING.md).

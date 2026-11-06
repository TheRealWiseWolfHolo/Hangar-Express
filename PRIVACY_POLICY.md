# Privacy Policy

Effective date: November 5, 2026

Hangar Express is an unofficial Star Citizen companion. This policy explains what
the app handles, where data goes, and what you can choose to share.

## Data on your device

The app handles RSI sign-in details, session cookies, account/profile information,
hangar and fleet items, buy-back entries, logs, game access, and account metadata.
It also stores app preferences, cached pictures/catalogs, account snapshots, and
Apple StoreKit entitlement state.

Saved RSI credentials and reusable cookies use the iOS Keychain. Read-only sign-in
uses the RSI browser without saving a native password. Snapshots, preferences, and
caches stay in the app container. These support sign-in, offline browsing, refresh,
and account actions you request.

The app does not automatically send your RSI password, cookies, full hangar,
purchase history, or saved account snapshot to the developer.

## Network services

- **RSI and Cloud Imperium:** sign-in, account data, and actions you request.
- **Hosted feeds and image hosts:** public ship information, reward catalogs,
  approved translations, events, and artwork. Referral progress stays in your saved
  account data; the reward catalog does not receive your counts or invite code.
- **Region check:** sign-in may request a country/region for the connection. Like
  other internet services, that service can see the request's connection IP address.
- **Cloud item translation:** uploads eligible catalog terms and an app-reported
  yes/no Early Access indication. It does not upload RSI credentials, purchase
  receipts, account identity, or a full inventory. The service stores term appearance
  counts. Local mode does not submit missing terms or that indication; both modes
  may download the approved dictionary.

These services process requests under their own policies. The app's browser,
cookie, and redirect checks are described in [App security](docs/SECURITY.md).

## Optional email feedback

Feedback is available in **Account → Tools** and **Settings → Help & Feedback**.
The form shows the recipient. Your message and subject are user-entered. App/device
details and diagnostic logs start off; screenshots are included only if selected.
You can preview the body, full log, and processed pictures before continuing.

Logs are sanitized but may still contain timestamps, network, activity, or inventory
details. Reports are not anonymous. Images are resized and re-encoded without
original filenames or location metadata; personal information visible in the
picture remains visible. RSI credentials and a full snapshot are not automatically
attached.

Your chosen mail app/provider shares your sending address, display name, message,
and attachments. Replies go to that sending address. Feedback is used to investigate
and respond to your request. There is no separate feedback upload service or
in-app support inbox.

If Apple Mail is unavailable, the share sheet offers the message and selected
attachments. Enter the recipient shown in the app and check the final email.
Temporary share files are protected, excluded from backup, and cleaned up on
dismissal. Copies you save or send through another app follow that app/provider's
storage policies. Closing the feedback form discards its in-memory draft.

Copied diagnostic reports use a local-only clipboard entry that expires after ten
minutes. This cannot retract copies already saved or shared elsewhere.

## Payments

Apple handles Hangar Express Early Access purchases and subscriptions. StoreKit
checks access; the app does not receive your App Store payment card number.

RSI store purchases are separate. Checkout may show supported payment-provider
pages, including Alipay and WeChat Pay, or open a payment app. Information you enter
there is handled by RSI and the chosen payment provider under their terms.

## Retention and your choices

Local data stays until removed through app controls or app deletion. You can remove
saved accounts, clear caches, choose Local or Cloud translation, and send feedback
without logs, device details, or pictures. Optional calendar/image exports happen
when you choose those actions.

Deleting local data does not delete copies already sent to a mail provider or the
developer. Contact the developer through Feedback about information you submitted.
Other services retain data under their own policies. Manage or cancel App Store
subscriptions through your Apple Account; deleting the app does not cancel them.

## Children, changes, and contact

The app is intended for people old enough to manage an RSI account and make
purchases under Apple, RSI, and local requirements; it is not directed to children.
This policy may change with app features or data handling. The effective date above
will be updated when it changes.

Use **Feedback** in the app for private contact, or the
[GitHub issue tracker](https://github.com/TheRealWiseWolfHolo/Hangar-Express/issues)
for public issues. Do not post passwords, cookies, payment details, verification
codes, or other private information publicly.

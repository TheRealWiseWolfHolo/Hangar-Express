# App security

Version 1.1.2 adds checks around sign-in, checkout, cookies, redirects, and support
logs. These are client protections, not a guarantee that every connected service
is secure.

## Credentials and browser pages

`RSISecurityPolicy` permits native credentials only on HTTPS
`robertsspaceindustries.com` and `www.robertsspaceindustries.com`, with the default
HTTPS port and no username or password in the URL. Cookie-domain membership alone
does not grant credential privileges.

Login autofill checks both the WebView URL and the actual document. It runs in
`WKContentWorld.defaultClient`, without credential globals or persistent page
timers. Its retry task stops on navigation, completion, or dismissal. Values
entered into the trusted page's form remain visible to that page's own scripts.

Checkout automation runs only on recognized RSI cart routes. It checks the current
document before injection and authenticated requests. Its page-world script uses
only the token/device fallbacks needed by the helper; it does not inject the native
account-auth cookie. System cookie handling supplies HTTP-only cookies.

Checkout messages must match the WebView, main frame, origin, document, checkout
ID, and document ID. Messages and fields have size limits. Log text cannot report
a successful purchase, and completion is accepted only once.

## Payment navigation

Supported Alipay and WeChat Pay HTTPS domains and subdomains may stay inside
checkout. Navigation, popups, and main-frame responses use the same policy. These
pages receive no native RSI credential privileges, checkout automation, or accepted
checkout bridge messages. Payment-app schemes open externally.

Other supported payment providers open externally. User-followed HTTPS links may
also open externally; unexpected redirects and unsafe main-frame schemes are
blocked. A compromised trusted RSI page remains outside the protection offered
by an origin allowlist.

## Cookies and redirects

Cookie checks cover domain, host-only status, path, expiry, names, and values.
Refreshed deletion cookies remove matching saved cookies. Browser stores are
nonpersistent and separate; checkout never imports the shared system cookie jar.
Detach cancels browser tasks, clears native credentials, and rejects stale callbacks.

`RSIAuthenticatedRedirectDelegate` permits at most ten redirects and keeps the
original trusted HTTPS origin. It rebuilds scoped cookie/RSI headers and removes
inherited authorization headers. Redirected GET/HEAD requests do not replay a
request body. System certificate validation remains enabled.

## Diagnostics and feedback

`DiagnosticPrivacy` filters known credentials, account fields, private endpoints,
unsafe URL parts, and email addresses. Raw account HTML, arbitrary error
dictionaries, and raw authentication responses are omitted. Error chains and
fields are bounded; exported reports are capped at 64 KiB.

Copied diagnostics use the local-only clipboard option and expire after ten
minutes. This cannot retract copies already saved elsewhere. Activity, inventory
identifiers, timestamps, and other support details may remain: review before sharing.

Feedback logs and app/device details start off. Users select screenshots, preview
attachments, and send through their mail app. Images are re-encoded without
original filenames or location metadata. Pixels are not automatically redacted.
Temporary share files are protected and excluded from backup.

The support address is read from private build configuration. Public settings are
blank; tests use a synthetic address. See [feedback](FEEDBACK.md) and
[network diagnostics](NETWORK_DIAGNOSTICS.md).

## Validation limits

Tests cover hostile origins, cookies, redirects, stale messages, cancellation,
redaction, size limits, and feedback attachments. Offline WebKit tests verify
credential and frame boundaries without weakening TLS checks.

These checks do not exercise live sign-in, payments, destructive RSI actions,
native mail delivery, or signed-device behavior. See [testing](TESTING.md).

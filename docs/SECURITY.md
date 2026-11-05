# App security boundaries

Version 1.1.2 hardens the client boundaries around authentication, checkout,
cookies, redirects and support diagnostics. This is an implementation description,
not a claim that the app or the services it accesses are free of vulnerabilities.

## Browser credentials and checkout

`RSISecurityPolicy` allows native credentials only on HTTPS
`robertsspaceindustries.com` and `www.robertsspaceindustries.com`, using the default
HTTPS port and no URL user information. Cookie-domain membership does not grant
a page credential privileges. Main-frame navigation, popups and responses enforce
the origin rule; third-party verification frames never receive native credentials.

Login autofill runs in `WKContentWorld.defaultClient`, with no credential globals
or persistent page timers. The native retry task stops on navigation, completion
or dismissal. Each call checks both the native URL and the actual document URL.
Isolated JavaScript variables do not hide values deliberately entered into the
trusted page's DOM from that page's own scripts.

Checkout automation runs only on the recognized cart routes. It retains the page
world because RSI's reCAPTCHA APIs live there, and checks the document before
injection and authenticated requests. Only the token/device fallbacks needed by
the existing checkout helper enter its arguments; the native account-auth cookie
is not injected. System cookie handling supplies HTTP-only cookies to requests.
The allowlist does not protect against a compromised trusted RSI origin.

Checkout messages use bounded typed bodies, a checkout ID and a document ID.
Native handling verifies the sender WebView, main frame, security origin and
document URL. A confirmation must match the current confirmation document; log
text cannot trigger success. Completion is reported once. Existing account and
generation checks continue to protect persistence and subsequent refreshes;
navigation signals do not create synthetic purchases or ownership.

Alipay and WeChat Pay HTTPS pages may open inside checkout, including recognized
payment subdomains. Navigation actions, popups and main-frame responses use the
same browsing policy. These pages receive no native RSI credential privileges,
checkout automation or accepted checkout bridge messages. Other known payment
sites and payment app schemes open externally. Other HTTPS links may open
externally when the user follows a link. Unexpected redirects, HTTP,
file, data and JavaScript main-frame destinations are rejected. Subframe access
does not authorize automation or bridge messages.

## Cookie isolation

`RSISessionCookieSet` and `RSISecurityPolicy` validate trusted domain boundaries,
cookie names/values, expiry and path applicability. Cookie paths follow the slash
boundary rule, so `/account` does not match `/accounting`. A persisted cookie
without a leading domain dot is conservatively treated as host-only. Existing
saved-session encoding is unchanged. Valid refreshed deletion/expiry cookies
remove older values with the same storage key.

Cookie installation uses each browser's own nonpersistent store. Checkout never
imports `HTTPCookieStorage.shared`. Detach cancels pending setup/automation/export
tasks and clears native credentials; callbacks are tied to the attached browser
and current document. Native request headers and authentication values use only
cookies applicable to their destination.

## Authenticated redirects

The launcher, account lookup and direct inventory requests use a per-request
`RSIAuthenticatedRedirectDelegate`, also inherited by the metrics collector.
Allowed 301/302/303/307/308 redirects must retain the original trusted HTTPS
origin. There is a ten-hop limit. Cookie and RSI authentication headers are
rebuilt for each destination, including valid cookie rotation from the response;
inherited authorization headers are removed. A redirected GET/HEAD does not replay
the original request body. System certificate validation is preserved.

## Support diagnostics

`DiagnosticPrivacy` is shared by auth/refresh collection, error previews, report
builders and diagnostic clipboard exports. It strips credential fields, known
active-session values, account identifiers, private endpoints and unsafe URL
components. Unknown error dictionaries, raw authentication responses and account
HTML previews are omitted. Authentication fallback uses fixed verification hints
instead of retaining raw response bodies.

Fields have byte limits; error chains have depth/node and cycle limits; exported
reports have a 64 KiB limit. The in-memory redaction context retains a bounded set
of known values and resets with its diagnostic session. Copied diagnostics use
the local-only clipboard option and a ten-minute expiration. Previously copied
reports cannot be retroactively redacted. Deliberately requested card/history
diagnostics can still contain inventory identifiers and other support metadata;
users should review their contents before sharing them.

## Validation

Security tests cover adversarial origins, ports, cookie domains/paths/expiry,
foreign/stale/oversized bridge messages, shared-cookie contamination, callback
lifetime, redaction, Unicode bounds and cyclic errors. Offline WebKit tests check
actual document execution, credential-global absence and frame behavior.

Redirect tests exercise the production delegate with real unresumed URLSession
tasks and controlled redirect responses, including all five supported statuses,
cookie rotation, body handling and hop limits. They send no DNS/network traffic
and do not substitute a permissive TLS trust handler. Existing account-operation
and authentication regressions remain part of the ordinary parallel unit suite.
Live RSI sign-in, payment and destructive account operations are not test fixtures.

Reference APIs: [WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld),
[WKScriptMessage.frameInfo](https://developer.apple.com/documentation/webkit/wkscriptmessage/frameinfo)
and [URLSessionTaskDelegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate).

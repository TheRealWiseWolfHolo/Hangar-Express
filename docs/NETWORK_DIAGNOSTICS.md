# Refresh network diagnostics

The existing Copy Logs / Refresh Debug Report includes request diagnostics in
normal Release builds. No profiling launch flag or developer mode is required.
This adds observations; request URLs, timeouts, retries and system certificate
validation keep their existing behavior.

The report header identifies format 2 and records UTC generation time and the
device time-zone offset. Every direct inventory request gets its own request ID.
The log records successful first pages and failures on any page; it does not add a
large success entry for every inventory page. Entries remain bounded to the
existing 120-entry support log. A reset fences callbacks from an older log session.

## Fields

- Actual elapsed milliseconds, configured timeout, cancellation state and failure
  category distinguish an immediate TLS error from a timeout or cancelled sibling.
- Up to eight NSError nodes, with a depth limit of five, include domain/code,
  sanitized messages, failing endpoint, numeric CFStream SSL fields and available
  OSStatus descriptions. Arbitrary userInfo dictionaries are never dumped.
- Foundation task metrics include transaction/redirect counts, HTTP protocol,
  negotiated TLS version/cipher, connection reuse, proxy/cellular/expensive/
  constrained flags, phase timings and HTTP byte counts. The last six transactions
  are retained. No request/response headers or contents enter the metrics collector.
- DNS, connection, TLS, request, first-byte and response timings use available
  start/end pairs. Connection timing can include the TLS handshake. Missing phases
  say `unavailable`, not zero. A reused connection can legitimately lack DNS/TLS
  timings. Early failures or custom URLProtocol sessions may supply no metrics.
  Byte counts are Foundation HTTP counters; zero can mean unavailable and does
  not establish that no network packets were exchanged.
- A valid Cloudflare Ray ID and parsed HTTP Date can help compare edge routing
  and device/server clocks. Clock offset is only an estimate including transit.
  No raw response header dump is exported.

## Privacy and limits

Network diagnostics never export Cookie/Authorization values, passwords, raw
certificates, raw account HTML or connection IP addresses. Only numeric `page` and
`pagesize` URL parameters survive; URL credentials, fragments, other parameters and
unrecognized paths are removed. Known authentication values, credential-like fields
and email addresses in error descriptions are redacted. The existing report still
contains existing account-context fields such as the account handle; this is not a
claim that the entire legacy support report is anonymous.

A proxy flag only reflects what Foundation reported; it cannot reliably identify
all VPNs or explain a specific TLS failure. Missing metrics are not proof of a
particular failure phase. Certificate validation is not relaxed or bypassed.
Old 1.0.10 reports cannot gain these fields retrospectively; reproduce with the
updated build and copy a new report.

Tests cover nested TLS codes, redaction, bounded chains, missing timings, mocked
HTTP/TLS failures, omitted HTML and request cancellation. Benchmark-only aggregate
network profiling still receives its metrics callback through the per-request
collector.

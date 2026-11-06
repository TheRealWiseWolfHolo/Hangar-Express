# Network diagnostics

**Copy Logs** and **Refresh Debug Report** include network diagnostics in normal
Release builds. No developer mode is needed. Feedback can also attach a sanitized
snapshot of local sign-in and refresh events, but only after the user opts in.

## Recorded information

- Request IDs, elapsed time, timeout, cancellation, and failure category.
- Bounded NSError/CFStream/OSStatus codes and sanitized descriptions.
- Available DNS, connection, TLS, request, first-byte, and response timings.
- HTTP protocol, TLS version/cipher, connection reuse, connection flags, and byte counts.
- Valid Cloudflare Ray IDs and parsed HTTP dates when available.

The refresh report uses format 2, UTC generation time, and a device time-zone
offset. It logs successful first pages and failures on any page, rather than a
large success entry for every page. The refresh store retains up to 120 entries.
Resetting it rejects late callbacks from the previous log session.

Error chains contain at most eight nodes and five levels. Metrics retain the last
six transactions. Missing timings are marked unavailable, not zero. A reused
connection may have no DNS/TLS timings. Foundation byte counts are HTTP counters,
not packet totals; zero does not prove that no traffic occurred.

## Privacy and sharing

Reports exclude passwords, credential headers/cookies, raw certificates, account
HTML, connection IP addresses, and raw header/body dumps. URL credentials,
fragments, unapproved paths, and query values are removed; numeric `page` and
`pagesize` parameters may remain. Private endpoints and known account fields are
redacted through `DiagnosticPrivacy`.

Exports are capped at 64 KiB. Copied logs are local-only and expire after ten
minutes. Timestamps, request IDs, device/version information, and activity details
may remain. Reports are not anonymous; review them before sharing. Feedback offers
a separate preview and can send a message without any log or device details.

## Interpreting a report

A proxy flag cannot identify every VPN. Clock offset estimates include transit
time. Missing metrics do not identify a failure phase, and old reports cannot gain
new fields retrospectively. Reproduce the problem with the updated build.

Authenticated redirects follow the [security policy](SECURITY.md). Timeout/retry
behavior and certificate validation are not weakened. Benchmark profiling receives
metrics through the same per-request collector, but remains a separate opt-in tool.

Tests cover redaction, nested TLS errors, bounds, unavailable timings, cancellation,
and mocked HTTP failures. See [testing](TESTING.md) and [feedback](FEEDBACK.md).

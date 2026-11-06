# Testing

## Unit tests

Use the shared **Hanger Express Unit Tests** scheme. It hosts tests without
starting normal login, StoreKit, or background refresh. The reproducible setup
uses Xcode 27.0 (27A266a) and an iPhone 17 / iOS 27.0 simulator.

From the repository root, choose a fresh result-bundle path:

```sh
xcodebuild test \
  -project 'Hanger Express.xcodeproj' \
  -scheme 'Hanger Express Unit Tests' \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  -derivedDataPath /tmp/hangar-unit-tests-derived \
  -resultBundlePath /tmp/hangar-unit-tests.xcresult \
  -parallel-testing-enabled YES \
  -maximum-parallel-testing-workers 2 \
  CODE_SIGNING_ALLOWED=NO
```

Add `-only-testing:'Hanger ExpressTests/FeedbackEmailTests'` to run one suite.
Individual Swift Testing method filters need parentheses, such as
`-only-testing:'Hanger ExpressTests/FeedbackEmailTests/basicFeedbackContainsNoOptionalInformationOrAttachments()'`.
Always check the reported test count; an empty run is not evidence. Failures are
not retried automatically.

## Isolated fixtures

Each test owns `TestResources`: unique preferences, temporary files, and HTTP
sessions. Missing HTTP fixtures fail locally instead of reaching a real server.
Use `resources.session`, URL-indexed response fixtures, and `request.testBodyData()`
for streamed upload bodies. Use `TestGate` for delays rather than sleep-based races.
Teardown removes owned resources.

AppModel tests inject fake repositories, authorizers, stores, and caches. StoreKit
is disabled. Automatic refresh is off unless a test explicitly enables it.
Background fakes share mutable data through locks or actors.

## Coverage

| Area | Checks |
| --- | --- |
| Account operations | Ownership, cancellation, late results, recovery, reconciliation |
| Storage | Keychain failures, save order, coalescing, deletion, migration, damaged files |
| Inventory | Freshness, partial refresh, groups, search, translations, image dependencies |
| Hosted feeds | Shared requests, validators, offline data, invalid responses |
| Browser security | Origins, cookies, redirects, typed messages, stale callbacks, real offline WebKit |
| Diagnostics | Redaction, bounds, error chains, missing metrics, cancellation |
| Feedback | Optional-data exclusion, private recipient validation, image metadata, attachment contents |
| Referrals and profile | Counts, rewards, package matching, and game-license contents |

Tests that simulate ignored cancellation wait for the actual worker to finish.
Redirect tests use controlled delegate calls and dormant URLSession tasks. TLS is
not bypassed, and tests never submit live account actions or purchases.

## Keychain integration

Injected Security-adapter tests run in the unsigned suite. The real Keychain
round-trip test is intentionally skipped there because unsigned simulator hosts
lack the required entitlements.

For an explicitly signed test host, use a test-only entitlement file outside app
source and enable `HANGAR_RUN_KEYCHAIN_INTEGRATION=1`. Supply these overrides to
the normal test command with a new result path:

```sh
-only-testing:'Hanger ExpressTests/KeychainSessionStoreTests' \
-parallel-testing-enabled NO \
CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
CODE_SIGN_ENTITLEMENTS=/tmp/hangar-keychain-tests.entitlements \
HANGAR_RUN_KEYCHAIN_INTEGRATION=1
```

The file needs `application-identifier` and `keychain-access-groups` matching the
test host's signing prefix and bundle ID. Do not change production entitlements
or publish the signing file.

## Offline UI checks

Use the opt-in runner to test the real views with synthetic accounts:

```sh
HANGAR_BENCHMARK_UI_TEST=testEmailFeedbackPrivacyAndPreview \
  ./scripts/run_performance_baseline.sh \
  'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  /tmp/hangar-feedback-ui ui
```

The runner supplies five `.invalid` service URLs and the synthetic support address
`support@example.invalid`. Normal Release builds omit the benchmark entry point.
The feedback flow checks privacy defaults, previews, removal, cancellation,
reopening, and both entry points. It never sends email. Image conversion and
metadata checks run separately from real photo-library selection.

Check screenshots, runtime warnings, skips, and actual case counts separately.
A passing test does not mean warning-free UI, verified mail delivery, or proven
behavior on a signed physical device. Live RSI sign-in and payments are not fixtures.

## CI and Release builds

GitHub Actions runs the unit scheme and repository hygiene checks on pushes and
pull requests. The iOS job uses the `xcode-27` runner and iOS 27.0, with two workers.
It runs the offline WebKit suite in a separate phase after the other unit tests,
so busy main-actor fixtures cannot starve browser navigation callbacks. Both
phases are required and retain their test time limits. WebKit cases run serially
because they share the test host's visible view hierarchy. Cooldown tests compare
stored deadlines with captured dates instead of assuming a fast runner.
Logs and result bundles are retained for 14 days, including failed runs. Debug CI
does not need private build settings or signing credentials.

Normal Release builds require the six private settings listed in the
[README](../README.md). Public settings stay blank. Missing or malformed support
addresses fail Release validation; Debug feedback stays disabled until configured.
Never upload private build settings, real support addresses, or local test artifacts.

Performance workloads are excluded from normal unit CI. See [performance](PERFORMANCE.md).

# Unit tests

Use the shared **Hanger Express Unit Tests** scheme. It builds the app and the
unit-test target, sets English/US localization, and hosts tests without starting
the app's login, StoreKit, or background refresh tasks. The regular app scheme
is also shared explicitly and continues to launch the normal app. Its test action
uses the same isolated unit-test host; performance workloads remain opt-in.

The reproducible baseline uses **Xcode 27.0 (27A266a)** and an **iPhone 17 / iOS
27.0 simulator**. Run from the repository root, using a new result-bundle path
for each run:

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

To run a suite independently, add `-only-testing:'Hanger
ExpressTests/ImageCacheTests'`, `-only-testing:'Hanger
ExpressTests/TestInfrastructureTests'`, or another suite identifier. Test failures
are not retried automatically.

## Fixture ownership

Swift Testing creates a new suite instance for each test. Each instance owns its
`TestResources`, which supplies a unique preferences suite, temporary directory,
and HTTP sessions. Teardown invalidates those sessions, unregisters their
handlers, removes preferences, and deletes owned files.

- Use `resources.session { request in ... }` for custom HTTP responses. The
  session's unique handler identity prevents another test requesting the same URL
  from receiving its responses. Stubbed sessions intercept all requests; missing
  fixtures fail locally instead of reaching a real server.
- Use `resources.responses.register(...)` and `resources.translationSession()`
  for URL-indexed feeds. Registrations belong to that test instance.
- Read upload bodies with `request.testBodyData()`: Foundation can present an
  `httpBodyStream` to `URLProtocol` even when the original request used `httpBody`.
- Use `TestGate` to delay a response until an explicit event. It handles task
  cancellation and avoids timing assertions based on sleeps.
- AppModel tests use fake repositories, isolated preferences, a disabled StoreKit
  store, and injected image/catalog/response caches. Supply a test session cookie
  when testing authenticated refresh behavior. Configure automatic refresh
  explicitly when that behavior is under test; default test preferences disable it.
- Test fakes implement the app protocols on the main actor, matching their
  isolation in the app module. Keep HTTP response data shared across tasks behind
  a lock or an actor.

## Continuous integration

### Keychain coverage

`KeychainSessionStoreTests` uses an injected, lock-protected Security adapter for
read/update/add/delete failures, malformed data, legacy migration, multiple
accounts, protection-class preservation and a duplicate-item race. AppModel
integration tests check that failed storage does not switch/remove/sign out the
current account, erase its cached snapshot, or turn a completed fake RSI action
into an action failure. No live RSI action is sent.

The real Security adapter round-trip test uses a unique test-only service and
cleans it up. It is intentionally disabled in the unsigned CI host: simulator
Keychain returns `errSecMissingEntitlement` (-34018) without host entitlements.
Enable it only in an explicitly signed host by passing
`HANGAR_RUN_KEYCHAIN_INTEGRATION=1`. A validated simulator invocation uses the
same unit-test scheme/destination above with:

```sh
-only-testing:'Hanger ExpressTests/KeychainSessionStoreTests' \
-parallel-testing-enabled NO \
CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
CODE_SIGN_ENTITLEMENTS=/tmp/hangar-keychain-tests.entitlements \
HANGAR_RUN_KEYCHAIN_INTEGRATION=1
```

Provide a **test-only** entitlement file containing `application-identifier`
and `keychain-access-groups` for the host's signing prefix and bundle identifier.
Keep it outside app source/configuration; these command-line overrides must not
change production signing or grant extra production access. Choose a fresh result
bundle path. The injected failure tests remain enabled in the ordinary unsigned
suite; the real-adapter test is reported as intentionally skipped there.

### Hosted checks

`.github/workflows/ios-tests.yml` builds and runs this scheme on pushes and pull
requests. It uses the `xcode-27` runner, selects Xcode 27.0 explicitly, and pins
the simulator runtime to iOS 27.0. A failed build or test fails the job. The full
build log and `.xcresult` bundle are uploaded even on failure and retained for
14 days. This Debug check does not require signing credentials or private release
configuration.

The runner/toolchain availability was checked against GitHub's
[Xcode 27 announcement](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/)
and [installed software manifest](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

## Account operation races

`AccountOperationCoordinatorTests` and the tests in `AccountOperationTests.swift`
exercise account generations, tracked job lifetimes, exclusive mutation leases
and recovery markers. `IgnoringCancellationGate` intentionally keeps a backend
alive after cancellation. Tests join the actual old worker before asserting no
late state was committed; switching/sign-out itself does not wait for that worker.
Pre-authorization and submitted-request tests use injected fake authorizers and
repositories, never live RSI actions. Authentication and checkout callbacks are
bound to the originating flow/account context.

Use the full unit scheme for coverage. An individual Swift Testing method filter
must include its parentheses, for example
`-only-testing:'Hanger ExpressTests/Hanger_ExpressTests/successfulRefreshStillPersistsItsCurrentAccountSnapshot()'`.
A filter without parentheses selected the suite but no method during validation;
check the actual reported test count rather than treating an empty run as evidence.

Ownership and save-submission assertions do not promise ordered disk completion.
The recorded older-write-finishes-last scenario is the next roadmap item (#4).
See `docs/ACCOUNT_OPERATIONS.md` for the state transitions and boundary.

## Snapshot and inventory optimization coverage

`SnapshotPersistenceTests` forces old saves, coalesced pending writes, deletion
barriers, write failures, migration and corrupt/future-format preservation.
`SnapshotSectionTests` verifies independent freshness, no-op revisions and partial
section merges. `ValidatedHostedFeedTests` covers shared loads, validators,
validated offline data, cache restrictions and clear/configuration fencing.
`InventoryCPUWorkerTests` verifies executor ownership, normalization/parser parity,
cancellation and asynchronous translation-cache readiness. `ImageCacheTests`
checks selective dependencies and same-URL changes. `InventoryPresentationTests`
checks groups, stable IDs, filter flags, language/account invalidation, cache
bounds and Unicode matching.

The opt-in `PerformanceBaselineTests/testCPUIsolationWorkload` compares a
synchronous reference with actor execution using offline data.
`testPresentationIndexComparison` records one-time index build and distinct query
costs at 1,000/10,000 items, including exact result-ID parity and observed process
footprints. Both use the Benchmarks scheme; they are excluded from normal CI.
Profiling source snapshots, measurements and traces stay private local artifacts.

### Hangar Log events

`HangarLogPresentationTests` covers latest-update buffering, explicit application,
account/context resets and lookup reuse across unrelated content. Integration tests
cover same-ID log edits, no-op freshness, incremental batches and rejected late
batches after account switches. The opt-in Release UI test
`testHangarLogSearchSurvivesRefreshAndKeyboardDismissal` uses the offline dashboard
and preview log to verify refresh, search focus, keyboard dismissal and X reset.

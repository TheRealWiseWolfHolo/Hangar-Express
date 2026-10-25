# Reproducible performance measurements

Use these tools before changing algorithms or cache behavior. Run one benchmark
at a time on an otherwise idle machine/device. Simulator timings compare
algorithms; physical device timings determine responsiveness. Record OS,
Xcode/build, device, power mode, thermal state, dataset, and cache policy with
each result. Keep the raw samples and result bundle.

## Workloads and build

`BenchmarkInventory` v1 creates 100, 1,000, or 10,000 pledges. Each inventory mixes
ships, multi-ship packages/game access, upgrades, repeated templates, and unique
rows. Buyback contains one quarter as many pledges. There are 64 synthetic catalog
ships and two distinct account identities. Dates, IDs, names, prices, and aliases
are deterministic. Correctness tests check reproducibility, account separation,
and representative content.

The fixtures have no credentials, cookies, real account data, or remote images.
The UI uses image placeholders. These measurements therefore do not establish
live RSI latency, real image-cache behavior, or production network traffic.

The benchmark schemes use Release optimization with testability enabled and the
explicit `HANGAR_BENCHMARKS` compilation flag. Ordinary Release builds omit the
fixture generator and offline UI entry point. The four remote URLs supplied by
the script are nonresolving `.invalid` placeholders required by Release config
validation. No production service is used. Performance tests are excluded from
the normal unit-test scheme and require an explicit opt-in environment.

## Stage measurements

From the repository root, run with Xcode 27.0 selected and choose a new output
folder for each run:

```sh
./scripts/run_performance_baseline.sh \
  'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  /tmp/hangar-baseline-simulator

./scripts/run_performance_baseline.sh \
  'platform=iOS,id=YOUR_DEVICE_UDID' \
  /tmp/hangar-baseline-iphone
```

Physical devices must be paired, trusted for development, and unlocked. Device
builds use the project's existing development signing team. If the UI test runner
does not yet have a development profile, explicitly set
`HANGAR_ALLOW_PROVISIONING_UPDATES=1` to let Xcode provision that runner and register
the selected development device using the configured account. The script does
not change the signing account.

The harness runs one warmup and five timed samples per size/stage, consuming all
results in a checksum. It measures existing JSON coding, name normalization,
fleet projection, grouping, computed group IDs, EN/CN Buyback search pipelines,
a prebuilt Fleet text-scan kernel, CCU route calculation, full/partial fixture
refresh orchestration, account switching/grouping, and snapshot save/load.

Refresh orchestration uses fake repository results and fake persistence; network
and disk are measured separately. The fixture's developer-preview session also
bypasses the authenticated full-refresh concurrency branch. It is not an end-to-end live refresh. Snapshot
loads use warm OS caches. The two synthetic inventories remain resident at each
size, and footprint readings are sampled process physical footprint, not peak
allocations. Fixtures and translations are prepared outside stage timings.

Outputs include the build/test log, toolchain version, `.xcresult`, raw attached
JSON samples, a hash manifest of the measured source tree, and a Markdown table with median, spread, variation, disk bytes,
and process footprint. A skipped or missing measurement attachment is an error
in report generation. `HANGAR_PERFORMANCE_DERIVED` optionally changes the derived
data path for reuse across runs.

New runs also save `source.tar.gz`, containing the nonignored source under a
`source/` prefix and its manifest. Local configuration, local notes and symlinks
are excluded. Keep the archive private with the results. Older runs have hash
manifests only; a later checkpoint archive must not be represented as the exact
source for an earlier run if its file hashes differ.

## Supplemental buyback and image-cache measurements

Use the same runner with the `supplement` mode:

```sh
./scripts/run_performance_baseline.sh \
  'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  /tmp/hangar-performance-supplement supplement
```

This is a separate versioned workload; standard fixture-v1 results remain
unchanged. It has 1,000 pledges and 2,000 uniquely grouped buybacks, measuring
grouping and EN/CN search including grouping. It also exercises the actual
`URLCachedImageStore` with a generated 2,048×1,024 JPEG at 84 pt / scale 3.
The report records compressed bytes and SHA256 so the payload can be compared.

Image cases cover a stubbed miss with decode/persistence/first draw, memory hit
with first draw, persisted restore with first draw and a failing offline session,
composite miss/memory hit, and 16 concurrent identical image calls. The last case
measures the image API without drawing. All stores, handlers, and directories
are isolated. Clearing caches, replacing store instances and generating the JPEG
happen outside sample timing; there is one warmup and five measured samples.
Stub call assertions distinguish misses from hits and verify coalescing; counts
include warmup and do not describe physical network traffic. Persisted reads use
warm OS caches. Sampled process footprint is not peak allocations. Generated
images do not establish production-asset or scrolling performance.

For a separate allocation diagnostic, use `supplement-profile`. It waits 15
seconds before fixture construction so Instruments can attach to the test host.
Add Allocations plus `os_signpost`; image stage names identify each measured
operation. The attached report is marked instrumented and its durations are
excluded from latency baselines. Preserve freed allocation events when deriving
peak live bytes, and distinguish recorded heap/VM bytes from physical footprint.
Export the complete recording-options schema with `xctrace record --template
Allocations --instrument os_signpost --show-recording-options` before changing
options; a partial JSON object is rejected by Instruments 27. Verify the trace
contains the expected stage markers before attributing allocations to an image
operation. A successful recorder exit alone does not establish that coverage.
Native Allocations statistics may require opening the saved trace in Instruments;
the XML table of contents does not necessarily expose allocation events. Its
"Total Bytes" column is cumulative allocation churn, not peak live memory.

For a numeric process high-water diagnostic without allocation recording, run:

```sh
./scripts/run_performance_baseline.sh 'platform=iOS,id=DEVICE_ID' \
  /tmp/hangar-memory memory
```

This selects only `testMemoryHighWater`, uses synthetic accounts and stubbed
images, and writes `memory.json` / `memory.md`. It reads the kernel's
`TASK_VM_INFO.ledger_phys_footprint_peak` and `resident_size_peak`, validating
the returned structure length and rejecting missing counters. The workload
retains two 10,000-pledge accounts with projection, JSON and snapshot restoration,
then a 1,000-pledge/2,000-unique-buyback inventory and 16 decoded/drawn image keys.
The counters include host/framework allocations since process startup and cannot
be reset between stages. They provide a process high-water mark, not a per-stage
peak, allocated-byte total, leak diagnosis, or production memory ceiling. Repeat
in a fresh process on matched hardware before comparing a later change. Keep
this diagnostic separate from low-overhead latency baselines.

## UI measurements

```sh
HANGAR_BENCHMARK_UI_SIZE=1000 ./scripts/run_performance_baseline.sh \
  'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  /tmp/hangar-baseline-ui ui
```

Repeat for sizes 100, 1,000, and 10,000 on representative iPhone and iPad hardware.
Search submits and validates individual character prefixes because a bulk iPad
`typeText` run produced an incorrect query. Its clock includes those automation
round trips and must not be compared to the earlier bulk-input harness. Failed
query/clear assertions invalidate a performance run even if metric samples exist.
The explicit UI launch environment opens the real Hangar/Fleet/Buyback views with
an offline synthetic snapshot, isolated display preferences, and no login or
StoreKit startup. Existing saved accounts are not bootstrapped. Do not use this
screen's refresh or purchase controls as a live-service benchmark.

UI tests record five samples of process launch, resume, search typing/clearing,
and scrolling when Xcode supplies each metric. Exported sample counts and runtime
warnings must be checked: a missing native launch event is incomplete evidence.
Set `HANGAR_BENCHMARK_UI_TEST=testProcessLaunch` (or another method name) to repeat
one UI measurement independently. Launch is a new process with warm OS caches, not a cold device boot
or a cleared filesystem cache. Launch includes deterministic fixture construction.
The native launch metric waits for responsiveness. A separate `testLaunchToReady`
clock measures the automated launch-to-ready sequence, because Xcode discards
companion metrics in an iteration with a missing native launch event. Launch,
resume and search clocks include UI automation/wait overhead; use stage signposts
and Instruments to distinguish application work from that overhead. Scrolling
uses XCTest's scrolling/deceleration metric. The `.xcresult` contains the native
launch, clock, memory, and scrolling measurements.

The current English UI harness requests an ASCII-capable keyboard only for the
explicit fixture screen, verifies the typed/cleared values, and bounds each UI
test to 120–180 seconds. This changed after an iPad/Pinyin automation-service
failure. Compare only matching harness versions; these measurements do not cover
Chinese marked-text composition. The normal app's keyboard traits are unchanged.

`Memory Physical` is a change over the measured interval and may be negative;
absolute and peak physical memory are separate metrics. Variation percentages
around a near-zero delta or hitch count are not useful regression thresholds.
Preserve missing-event warnings and actual sample counts. If Xcode reports zero
Frame Count alongside a nonzero frame rate/duration, treat Frame Count as
unavailable rather than evidence that nothing rendered.

## Instruments procedure

See Apple's [Recording Performance Data](https://developer.apple.com/documentation/os/recording-performance-data)
for viewing custom signposts with the `os_signpost` instrument. Check that custom
stage events exist in the saved trace before treating an interval table as data.

Static Points of Interest intervals mark `Refresh`, `FetchHTML`,
`ParsePledgeHTML`, `ParseBuybackHTML`, `NormalizeHangar`, `NormalizeBuyback`,
`FleetProjection`, `GroupHangar`, `GroupFleet`, `GroupBuyback`, `HangarSearch`,
`FleetSearch`, `BuybackSearch`, `CCURoute`, `SnapshotLoad`, and `SnapshotSave`.
Intervals contain no account identifiers or request contents.

1. Select the physical device in Instruments and record Time Profiler and SwiftUI
   / Animation Hitches for launch, scrolling, and repeated search. Record
   Allocations separately when diagnosing allocation/retention costs; do not
   combine heavily instrumented timings with the low-overhead baseline.
2. For CPU stages, attach Time Profiler to `Hangar Express` while the benchmark
   test runs. Preserve the `.trace` and filter samples by that process and the
   stage intervals. The default Time Profiler template did not capture the app's
   custom events in validation; add the explicit signpost instrument. A CLI
   recording can use `xcrun xctrace record --template
   'Time Profiler' --instrument os_signpost --device DEVICE --attach 'Hangar Express' --time-limit 30s
   --output /tmp/hangar-cpu.trace`.
3. To measure real authenticated full and partial refresh, use the normal app and
   a separately recorded inventory size. Record Network/File Activity alongside
   stage intervals, counting requests/bytes and cache hits. Fixture timings and
   the fixture's zero request count cannot substitute for this run. Do not export
   response bodies or authentication data into benchmark artifacts.
4. Check thermal state/power settings and repeat outliers after cooling/settling.
   Use the same device and build for comparisons. Validate iPhone and iPad
   separately, including orientation and display mode.

Export raw events with `xcrun xctrace export --input recording.trace --xpath
'/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' > events.xml`,
then run `python3 scripts/summarize_signpost_trace.py events.xml /tmp/stage-report`.
The summarizer keeps only the app's static stage names, resolves XML references,
deduplicates events repeated across instrument tables, and reports incomplete
intervals. Nested/parallel durations overlap; their sums are not total refresh
wall time. A `FetchHTML` call is not proof of a network request or cache miss.

For CPU analysis inside a completed refresh, export the `time-profile` table
using the same XPath pattern, then run:

```sh
python3 scripts/summarize_cpu_trace.py cpu.xml \
  /tmp/stage-report/signpost-summary.json /tmp/cpu-report
```

An optional fourth argument selects the zero-based Refresh index. The tool
excludes startup/user waiting, reports main/worker sampled CPU separately, and
keeps inclusive app frames and leaf frames separate. CPU seconds may exceed
wall seconds under concurrency; inclusive frames overlap. Unknown/deduplicated
symbols cannot identify a particular source function.

## Opt-in live partial-refresh diagnostics

Build the regular app scheme in Release with
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=HANGAR_BENCHMARKS`, using the real local
endpoint/signing configuration. Launch that diagnostic build with:

```sh
xcrun xctrace record --template 'Time Profiler' --instrument os_signpost \
  --device DEVICE --time-limit 180s --output /tmp/partial-refresh.trace \
  --env HANGAR_NETWORK_PROFILE=1 \
  --env HANGAR_LIVE_PROFILE_SCOPES=account,hangar,buyback \
  --env HANGAR_BENCHMARK_UI_SIZE=0 --env HANGAR_UNIT_TEST_HOST=0 \
  --launch -- com.wisewolfholo.Hanger-Express
```

Use `0`, not an empty `--env` value: xctrace rejects empty values. The loaded
account is required. The runner waits for an existing refresh, runs only the
explicit allowed read-only scopes, stops on a visible error, and restores its
previous idle-timer setting. Normal bootstrap work can precede the batch.

Scalar metrics are saved at
`Library/Caches/HangerExpress/PerformanceProfile/refresh-metrics.json` in the app
data container. Request delegates capture immutable run IDs; the serial writer
keeps late callbacks attached to the correct saved run. Validate callback counts,
nonoverlapping scope intervals and `runnerState=complete`. This diagnostic
mechanism does not implement roadmap ownership or snapshot-write ordering.

Coverage is **RSIAccountHTTPPageClient URLSession tasks only**. Browser/GraphQL,
hosted-feed and image traffic is unobserved. Foundation supplies transaction,
cache type, protocol, redirect and HTTP byte counts; these are not TLS/packet
totals. Account can have zero HTML counters while performing other network work.
No URLs, cookie/header contents, response bodies, remote addresses or account
identities are retained. Ordinary Release excludes these hooks entirely. Restore
an ordinary signed Release after profiling and retain its saved data.

## Comparing changes

The largest observed sample establishes an empirical comparison envelope for the
same setup, not a production latency requirement. Treat a later median outside
that envelope as a reason to repeat and profile. High variation, different
hardware, a new fixture version, or a changed cache policy requires a new
baseline. Set release budgets only after representative physical UI recordings
and repeated stable samples establish user-visible costs.

The private optimization roadmap records progress, local artifact paths, measured
findings, proposed budgets, and any device/live-service profiling still pending.

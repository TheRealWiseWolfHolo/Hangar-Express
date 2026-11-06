# Performance measurements

Measure before changing algorithms or caches. Run one workload at a time on an
idle machine. Use simulator results to compare algorithms and physical devices
to judge responsiveness. Record toolchain, OS, device, power/thermal state,
dataset, cache policy, and source hashes. Keep traces and raw results private.

## Offline runner

`BenchmarkInventory` v1 creates deterministic inventories of 100, 1,000, or 10,000
pledges, with packages, upgrades, fleet data, and two synthetic accounts. There is
no real account data or live RSI session. Baseline UI uses image placeholders;
specific referral UI checks may opt into public test artwork.

Benchmark schemes use Release optimization, testability, and `HANGAR_BENCHMARKS`.
The runner supplies five `.invalid` service URLs and a synthetic support address.
Ordinary Release builds omit the offline entry point. These workloads do not
measure live RSI latency or production image traffic.

```sh
./scripts/run_performance_baseline.sh \
  'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  /tmp/hangar-baseline
```

Choose a fresh output folder. Set `HANGAR_PERFORMANCE_DERIVED` to reuse another
derived-data folder. Select a mode as the final argument:

| Mode | Measures |
| --- | --- |
| `stages` (default) | Coding, normalization, projection, grouping, search, CCU routes, refresh, storage |
| `supplement` | 2,000 unique buybacks and actual image-cache paths with stubbed traffic |
| `supplement-profile` | Allocation diagnostic with a 15-second attach delay |
| `memory` | Process high-water memory counters across large synthetic workloads |
| `ui` | Real views with offline fixtures: launch, resume, search, and scrolling |

Stage samples use one warmup and five measured runs. Fixtures are prepared outside
timed sections. Checksums and result assertions must pass. Snapshot reads use warm
OS caches. Fake refresh orchestration does not establish live request counts or
full-refresh concurrency behavior.

Outputs include logs, `.xcresult`, raw samples, source hashes, a private source
archive, and summaries where supported. Missing or skipped measurement attachments
invalidate a result. Do not treat a later source archive as an exact earlier build.

## Devices and UI

For a physical device, replace the destination with
`platform=iOS,id=YOUR_DEVICE_UDID`. It must be paired, trusted, unlocked, and signed
with the project's development team. Only set `HANGAR_ALLOW_PROVISIONING_UPDATES=1`
when explicitly allowing Xcode to provision/register that test device.

```sh
HANGAR_BENCHMARK_UI_SIZE=1000 \
  ./scripts/run_performance_baseline.sh \
  'platform=iOS Simulator,name=iPhone 17,OS=27.0' \
  /tmp/hangar-ui ui
```

Repeat sizes 100, 1,000, and 10,000 on representative iPhone/iPad hardware.
`HANGAR_BENCHMARK_UI_TEST` selects one method. The runner bounds UI tests to
120–180 seconds. Fixtures use isolated preferences and skip live account startup.

Search automation enters and checks each character with an ASCII keyboard. Its
clock includes automation overhead and does not cover Chinese marked text. Launch
uses a new process with warm OS caches, not a cold device or empty filesystem.
Use `testLaunchToReady` when native launch metrics omit a companion measurement.

Read exported sample counts and runtime warnings. Missing launch events or zero
Frame Count with nonzero duration do not prove that nothing rendered. `Memory
Physical` is an interval change and may be negative; it is not an absolute peak.
Do not compare different harness versions as if they were the same measurement.

## Image and memory diagnostics

Supplemental image tests use a generated 2048×1024 JPEG, isolated stores, and
stubbed sessions. Cases cover miss/decode/draw, memory hit, disk restore, composite
images, and 16 identical concurrent requests. Stub counts distinguish coalescing
and cache hits; they are not real network traffic. Disk reads use warm OS caches.

`supplement-profile` results are instrumented diagnostics, not latency baselines.
When using Allocations, preserve freed events and inspect recording options before
changing them. Cumulative allocated bytes, peak live bytes, physical footprint,
and leaks are different measurements.

`memory` uses validated kernel process high-water counters. They include framework
and host allocations since launch and cannot be reset per stage. Repeat in a fresh
process on matched hardware; do not treat the result as a production memory ceiling.

## Instruments and signposts

Use Time Profiler with explicit `os_signpost` capture for CPU work. Use SwiftUI /
Animation Hitches for UI work and a separate Allocations recording for retention.
Confirm that expected stage markers exist in the saved trace; recorder success
alone does not prove coverage.

Static stages cover refresh, HTML fetch/parse, normalization, fleet projection,
grouping, search, CCU routing, and snapshot load/save. Markers contain no account
identifiers or request contents. Nested intervals overlap and must not be summed
as total wall time. A FetchHTML marker is not proof of a network request.

```sh
xcrun xctrace export --input recording.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
  > events.xml
xcrun xctrace export --input recording.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  > cpu.xml
python3 scripts/summarize_signpost_trace.py events.xml /tmp/hangar-stages
python3 scripts/summarize_cpu_trace.py cpu.xml \
  /tmp/hangar-stages/signpost-summary.json /tmp/hangar-cpu
```

The trace must contain both signposts and a `time-profile` table. The CPU summarizer accepts
an optional zero-based Refresh index, separates main/worker samples, and keeps
inclusive/leaf frames separate. CPU seconds may exceed wall time; inclusive frames
overlap. Unknown symbols cannot identify a specific source function.

## Opt-in live read diagnostics

A diagnostic build can enable `HANGAR_BENCHMARKS` and use private service/signing
configuration. With an existing account, enable `HANGAR_NETWORK_PROFILE=1` and
`HANGAR_LIVE_PROFILE_SCOPES=account,hangar,buyback`. Use `0`, not an empty value,
for `HANGAR_BENCHMARK_UI_SIZE` and `HANGAR_UNIT_TEST_HOST` when launching via xctrace.

The runner waits for current refresh work, runs only requested read scopes, stops
on a visible error, and restores the idle-timer setting. Normal bootstrap may run
first. Validate completed scope intervals, callbacks, and `runnerState=complete`
in the private `PerformanceProfile/refresh-metrics.json` cache output.

Coverage is limited to `RSIAccountHTTPPageClient` URLSession tasks. Browser, GraphQL,
feed, and image traffic is not counted. HTTP bytes are not TLS/packet totals.
No request contents, credentials, URLs, remote addresses, or account identities
are retained by this aggregate profiler. Ordinary Release excludes these hooks;
its [support diagnostics](NETWORK_DIAGNOSTICS.md) remain a separate feature.
Restore an ordinary Release build after profiling.

## Comparisons

Compare matched hardware, toolchain, fixture version, and cache policy. Investigate
outliers after cooling the device. A slower median or wider spread is a reason to
repeat and profile, not an automatic user-facing performance claim. Set release
budgets only from repeated physical-device evidence. See [testing](TESTING.md).

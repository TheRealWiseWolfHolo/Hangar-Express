#!/bin/bash
set -euo pipefail

# Usage: run_performance_baseline.sh DESTINATION OUTPUT_DIRECTORY [stages|supplement|supplement-profile|memory|ui]
destination="${1:-platform=iOS Simulator,name=iPhone 17,OS=27.0}"
output="${2:-/tmp/hangar-baseline-$(date -u +%Y%m%dT%H%M%SZ)}"
kind="${3:-stages}"
case "$kind" in
  stages) scheme='Hanger Express Benchmarks'; test_target='Hanger ExpressTests/PerformanceBaselineTests/testInventoryStages' ;;
  supplement) scheme='Hanger Express Benchmarks'; test_target='Hanger ExpressTests/PerformanceBaselineTests/testSupplementalStages' ;;
  supplement-profile) scheme='Hanger Express Benchmarks'; test_target='Hanger ExpressTests/PerformanceBaselineTests/testSupplementalStages' ;;
  memory) scheme='Hanger Express Benchmarks'; test_target='Hanger ExpressTests/PerformanceBaselineTests/testMemoryHighWater' ;;
  ui) scheme='Hanger Express UI Benchmarks'; test_target='Hanger ExpressUITests/PerformanceUITests' ;;
  *) printf 'Expected stages, supplement, supplement-profile, memory or ui.\n' >&2; exit 2 ;;
esac
if [ "$kind" = ui ] && [ -n "${HANGAR_BENCHMARK_UI_TEST:-}" ]; then
  test_target="$test_target/$HANGAR_BENCHMARK_UI_TEST"
fi
if [ -e "$output/results.xcresult" ]; then
  printf 'Choose a new output directory; the result bundle already exists.\n' >&2
  exit 2
fi
mkdir -p "$output"
arguments=(CODE_SIGNING_ALLOWED=YES)
case "$destination" in
  *Simulator*) arguments=(CODE_SIGNING_ALLOWED=NO) ;;
  *)
    team=$(xcodebuild -showBuildSettings -project 'Hanger Express.xcodeproj' -target 'Hanger Express' -configuration Release 2>/dev/null | awk '$1 == "DEVELOPMENT_TEAM" { value=$3 } END { print value }')
    if [ -z "$team" ]; then
      printf 'The app must have an existing development signing team for device measurements.\n' >&2
      exit 2
    fi
    arguments+=("DEVELOPMENT_TEAM=$team")
    if [ "${HANGAR_ALLOW_PROVISIONING_UPDATES:-0}" = 1 ]; then
      arguments+=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
    fi
    ;;
esac
if [ "$kind" = ui ]; then
  arguments+=(-test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 180)
fi
if [ "$kind" = supplement-profile ]; then
  arguments+=(HANGAR_BENCHMARK_PROFILE_DELAY=1)
else
  arguments+=(HANGAR_BENCHMARK_PROFILE_DELAY=0)
fi
xcodebuild -version > "$output/toolchain.txt"
sw_vers > "$output/host.txt"
uname -m >> "$output/host.txt"
sysctl -n hw.model hw.memsize >> "$output/host.txt"
python3 scripts/performance_source_manifest.py --archive "$output/source.tar.gz" > "$output/source-manifest.json"
set +e
xcodebuild test \
  -project 'Hanger Express.xcodeproj' \
  -scheme "$scheme" -configuration Release \
  -destination "$destination" \
  -derivedDataPath "${HANGAR_PERFORMANCE_DERIVED:-/tmp/hangar-performance-derived}" \
  -resultBundlePath "$output/results.xcresult" \
  -only-testing:"$test_target" \
  -parallel-testing-enabled NO \
  ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=HANGAR_BENCHMARKS \
  HANGAR_BENCHMARK_UI_SIZE="${HANGAR_BENCHMARK_UI_SIZE:-1000}" \
  REMOTE_PRIMARY_BASE_URL=https://example.invalid \
  REMOTE_FALLBACK_BASE_URL=https://example.invalid \
  REMOTE_TRANSLATION_BASE_URL=https://example.invalid \
  REMOTE_IP_REGION_URL=https://example.invalid \
  REMOTE_REFERRAL_REWARDS_BASE_URL=https://example.invalid \
  "${arguments[@]}" 2>&1 | tee "$output/build-test.log"
status=${PIPESTATUS[0]}
set -e
if [ -d "$output/results.xcresult" ]; then
  xcrun xcresulttool export attachments --path "$output/results.xcresult" --output-path "$output/attachments"
fi
if [ "$status" -eq 0 ] && [ "$kind" = memory ]; then
  python3 scripts/summarize_memory_baseline.py "$output/attachments" "$output"
elif [ "$status" -eq 0 ] && [ "$kind" != ui ]; then
  python3 scripts/summarize_performance_baseline.py "$output/attachments" "$output"
fi
if [ "$status" -eq 0 ] && [ "$kind" = ui ]; then
  xcrun xcresulttool get test-results metrics --path "$output/results.xcresult" > "$output/ui-metrics.json"
  xcrun xcresulttool get test-results summary --path "$output/results.xcresult" > "$output/test-summary.json"
  python3 scripts/summarize_ui_performance.py "$output"
fi
exit "$status"

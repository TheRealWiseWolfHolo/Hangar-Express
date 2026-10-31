#!/usr/bin/env python3
"""Preserve native XCTest units and samples, without inferring frame latency."""
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
tests = json.loads((root / 'ui-metrics.json').read_text())
summary = json.loads((root / 'test-summary.json').read_text())
rows = []
for test in tests:
    for run in test['testRuns']:
        for metric in run['metrics']:
            samples = metric['measurements']
            if not samples:
                continue
            mean = statistics.mean(samples)
            cv = statistics.pstdev(samples) / abs(mean) if mean else 0
            rows.append(
                f"| {test['testIdentifier']} | {run['device']['deviceName']} | "
                f"{metric['displayName']} | {metric['unitOfMeasurement']} | "
                f"{len(samples)} | {statistics.median(samples):.3f} | "
                f"{min(samples):.3f}–{max(samples):.3f} | {cv:.1%} |"
            )
if not rows:
    raise SystemExit('No UI measurements were recorded; skipped tests are not a baseline.')
lines = [
    '# Offline UI performance baseline', '',
    f"Run outcome: **{summary['result']}**; {summary['passedTests']} passed, "
    f"{summary['failedTests']} failed, {summary['skippedTests']} skipped. "
    'Individual metrics do not establish that the entire run passed.', '',
    'Native XCTest metrics; units are preserved from Xcode. Five iterations are requested '
    'after XCTest warmup; the Samples column shows what Xcode actually returned. '
    'Fewer than five samples is incomplete evidence, not a five-sample baseline. '
    'See the result bundle and raw JSON for samples, warnings, and test failures.', '',
    '| Test | Device | Metric | Unit | Samples | Median | Min–max | CV |',
    '| --- | --- | --- | --- | ---: | ---: | ---: | ---: |',
    *rows, '',
    'Launch includes synthetic fixture construction and uses warm OS caches. '
    'Resume and search include UI automation overhead. These clocks are not '
    'keystroke-to-frame latency. Scrolling metrics describe the tested gestures '
    'and placeholder images, not production image decoding or all app screens. '
    'A missing metric is not zero cost. Compare only identical device/build/dataset '
    'conditions; largest observed samples are comparison envelopes, not release budgets.', '',
]
(root / 'ui-baseline.md').write_text('\n'.join(lines))
print(f"Wrote {root / 'ui-baseline.md'}")

#!/usr/bin/env python3
"""Summarize attached synthetic benchmark samples; never invent UI timings."""
import json
import pathlib
import sys

source, output = map(pathlib.Path, sys.argv[1:3])
reports = []
for path in source.rglob('*'):
    if not path.is_file():
        continue
    try:
        report = json.loads(path.read_text())
    except (ValueError, UnicodeError, OSError):
        continue
    if isinstance(report, dict) and report.get('fixtureVersion') and 'measurements' in report:
        reports.append(report)
if len(reports) != 1:
    raise SystemExit(f'Expected one baseline attachment, found {len(reports)}')
r = reports[0]
output.mkdir(parents=True, exist_ok=True)
(output / 'baseline.json').write_text(json.dumps(r, indent=2, sort_keys=True) + '\n')
lines = [
    '# Synthetic performance baseline', '',
    ('**Instrumented diagnostic: do not use these timings as a latency baseline.**'
     if r.get('instrumentedDiagnostic') else 'Low-overhead timing run; separate from instrumented diagnostics.'), '',
    f"Device: **{r['deviceModel']}**, iOS {r['os']}; simulator: {r['isSimulator']}.  ",
    f"Build: {r['build']}; fixture v{r['fixtureVersion']}.  ",
    f"Workload: {r.get('workloadVariant', 'standard-two-account-v1')}.  ",
    f"Five measured samples after one warmup; thermal state {r['thermalStateStart']} → {r['thermalStateEnd']}; low power: {r['lowPowerMode']}.", '',
    'All times below are milliseconds. Persistence loads use warm OS caches. '
    'Grouping and search are code-path measurements, not end-to-end UI latency. '
    + ('Generated JPEGs use an isolated URLProtocol stub; image misses include decode, persistence and first draw. '
     'Memory hits include first draw; disk restores use a new store with a failing offline session and warm OS caches. '
     'Cache setup/clearing happens outside the timed samples. One inventory is retained. '
     'The Pledges column identifies inventory context, not the number of images per operation. '
     'No physical network requests are made.' if 'imageFixture' in r else
     'Fixtures use placeholder images and make zero network requests. Two inventories '
     'are retained during each size, so process footprint includes both accounts.'), '',
    '| Stage | Pledges | Median ms | Min–max ms | CV | Observed upper envelope ms |',
    '| --- | ---: | ---: | ---: | ---: | ---: |',
]
for m in r['measurements']:
    lines.append(
        f"| {m['stage']} | {m['pledges']:,} | {m['medianMs']:.3f} | "
        f"{m['minMs']:.3f}–{m['maxMs']:.3f} | {m['coefficientOfVariation']:.1%} | {m['maxMs']:.3f} |"
    )
lines += ['', 'The upper envelope is the largest observed sample, not a production '
          'latency budget. Future comparisons must use the same fixture, hardware, '
          'OS, toolchain, build flags, thermal state, and cache policy. Repeat a '
          'measurement if a change exceeds the envelope before attributing it to a regression.', '',
          '| Pledges | Fleet | Buybacks | Hangar groups | Snapshot MiB | Footprint before/after MiB |',
          '| ---: | ---: | ---: | ---: | ---: | ---: |']
for d in r['datasets']:
    lines.append(
        f"| {d['pledges']:,} | {d['fleet']:,} | {d['buybacks']:,} | {d['hangarGroups']:,} | "
        f"{d['snapshotDiskBytes']/2**20:.3f} | "
        f"{d['physicalFootprintBeforeBytes']/2**20:.1f} / {d['physicalFootprintAfterBytes']/2**20:.1f} |"
    )
if 'imageFixture' in r:
    fixture = r['imageFixture']
    lines += ['', f"Image fixture: {fixture['width']}×{fixture['height']} JPEG, {fixture['jpegBytes']:,} bytes; "
              f"{fixture['targetPoints']} pt at scale {fixture['displayScale']}. SHA256: `{fixture['jpegSHA256']}`.", '',
              '| Image stage | Stub calls including warmup | Disk bytes after stage |', '| --- | ---: | ---: |']
    for stage, calls in r['mockRequestsByStage'].items():
        lines.append(f"| {stage} | {calls} | {r['imageDiskBytesAfterStage'][stage]:,} |")
    lines += ['', 'Stub byte counts are not production transport bytes. Generated texture/first-draw cost '
              'does not establish real asset quality, UI scrolling, cold OS caches or peak allocations. '
              'The 16-request case measures the coalesced image API without a first draw. '
              f"Buyback groups: {r['datasets'][0]['buybackGroups']:,} (all unique).", '']
lines += ['', 'Footprint is sampled process physical footprint, not a stage peak or '
          'retained allocation count. Live fetch/HTML parsing, device launch/resume, '
          'real image decoding, and animation hitch measurements require separate '
          'UI/Instruments runs; no values for them are inferred here.', '']
(output / 'baseline.md').write_text('\n'.join(lines))
print(f"Wrote {output / 'baseline.md'} and raw samples to {output / 'baseline.json'}")

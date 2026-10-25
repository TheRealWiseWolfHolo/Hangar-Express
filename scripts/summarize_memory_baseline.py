#!/usr/bin/env python3
"""Report kernel process high-water counters without inventing stage peaks."""
import json
import pathlib
import sys

source, output = map(pathlib.Path, sys.argv[1:3])
reports = []
for path in source.rglob('*'):
    if not path.is_file():
        continue
    try:
        value = json.loads(path.read_text())
    except (ValueError, UnicodeError, OSError):
        continue
    if isinstance(value, dict) and value.get('diagnostic') == 'process-memory-high-water-v1':
        reports.append(value)
if len(reports) != 1:
    raise SystemExit(f'Expected one memory attachment, found {len(reports)}')
r = reports[0]
points = r['checkpoints']
if not points:
    raise SystemExit('No memory checkpoints; a peak cannot be inferred')
last_peak = last_resident_peak = 0
for point in points:
    peak, current = point['peakPhysicalFootprintBytes'], point['physicalFootprintBytes']
    resident_peak, resident = point['peakResidentBytes'], point['residentBytes']
    if not (peak >= current > 0 and resident_peak >= resident > 0
            and peak >= last_peak and resident_peak >= last_resident_peak):
        raise SystemExit('Missing, inconsistent or nonmonotonic kernel memory counters')
    last_peak, last_resident_peak = peak, resident_peak
output.mkdir(parents=True, exist_ok=True)
(output / 'memory.json').write_text(json.dumps(r, indent=2, sort_keys=True) + '\n')
mib = lambda value: f'{value / 1048576:.3f}'
lines = [
    '# Process memory high-water diagnostic', '',
    f"Device: **{r['deviceModel']}**, iOS {r['os']}; simulator: {r['isSimulator']}.  ",
    f"Build: {r['build']}; fixture v{r['fixtureVersion']}.  ",
    f"Thermal state {r['thermalStateStart']} → {r['thermalStateEnd']}; low power: {r['lowPowerMode']}.", '',
    '**One diagnostic process run, not a timing baseline or leak test.** Kernel '
    '`TASK_VM_INFO.ledger_phys_footprint_peak` and `resident_size_peak` are lifetime '
    'high-water counters since process startup, including XCTest and frameworks. '
    'They cannot be reset at checkpoints. A later unchanged peak does not isolate '
    'the peak of that operation. Physical footprint and resident size are different '
    'accounting measures; neither is cumulative allocated bytes.', '',
    '| Checkpoint | Current footprint MiB | Lifetime peak footprint MiB | Current resident MiB | Lifetime peak resident MiB |',
    '| --- | ---: | ---: | ---: | ---: |',
]
for point in points:
    lines.append('| ' + point['checkpoint'] + ' | ' + ' | '.join(mib(point[key]) for key in [
        'physicalFootprintBytes', 'peakPhysicalFootprintBytes', 'residentBytes', 'peakResidentBytes'
    ]) + ' |')
lines += [
    '', 'Workload: two retained 10,000-pledge synthetic accounts, grouping, fleet '
    'projection, JSON encode/decode and persisted restore; after that scope, one '
    '1,000-pledge / 2,000-unique-buyback inventory plus 16 distinct image-cache keys. '
    'Images use the same generated JPEG, 84 pt at scale 3, and are retained after '
    'first draw, then released and the cache cleared. Sample checkpoints are not '
    'stage-local peaks. No production assets or signed-in account data are used.', '',
    f"JPEG: {r['imageJPEGBytes']:,} bytes; SHA256 `{r['imageJPEGSHA256']}`.  ",
    f"Stub calls: {r['imageStubRequests']}; persisted image bytes before clear: {r['imageDiskBytes']:,}; physical network requests: {r['physicalNetworkRequests']}.", '',
    'For future memory comparisons, repeat this exact workload in a fresh process '
    'on the same hardware/OS/build before claiming an improvement or regression. '
    'This single run does not establish a memory ceiling for arbitrary accounts, '
    'real-image scrolling, production refresh, or an OS jetsam threshold.',
]
(output / 'memory.md').write_text('\n'.join(lines) + '\n')
print(f'Wrote {output / "memory.md"}')

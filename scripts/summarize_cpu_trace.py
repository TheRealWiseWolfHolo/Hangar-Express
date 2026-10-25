#!/usr/bin/env python3
"""Summarize sampled CPU inside a completed Refresh interval, not user waiting."""
import collections
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

source, intervals_path, output = map(pathlib.Path, sys.argv[1:4])
refresh_index = int(sys.argv[4]) if len(sys.argv) > 4 else 0
refresh = json.loads(intervals_path.read_text())['refreshes'][refresh_index]
start = refresh['startMs'] * 1e6
end = start + refresh['durationMs'] * 1e6
root = ET.parse(source).getroot()
identities = {element.get('id'): element for element in root.iter() if element.get('id')}


def resolve(element):
    return identities[element.get('ref')] if element is not None and element.get('ref') else element


inclusive = collections.Counter()
main_frames = collections.Counter()
leaf = collections.Counter()
total = main = count = unstacked = skipped_nonrunning = 0
for row in root.findall('.//row'):
    timestamp = int(resolve(row.find('sample-time')).text)
    if not start <= timestamp <= end:
        continue
    state = resolve(row.find('thread-state'))
    if state is not None and state.text != 'Running':
        skipped_nonrunning += 1
        continue
    weight = int(resolve(row.find('weight')).text)
    total += weight
    count += 1
    is_main = 'Main Thread' in resolve(row.find('thread')).get('fmt', '')
    if is_main:
        main += weight
    stack = row.find('tagged-backtrace')
    if stack is None:
        unstacked += weight
        continue
    frames = [resolve(frame) for frame in resolve(stack).findall('frame')]
    if frames:
        leaf[frames[0].get('name', 'unknown')] += weight
    names = set()
    for frame in frames:
        binary = resolve(frame.find('binary'))
        name = frame.get('name', 'unknown')
        if binary is not None and binary.get('name') in ('Hangar Express', 'Hanger_Express'):
            if name != '<deduplicated_symbol>':
                names.add(name)
    for name in names:
        inclusive[name] += weight
        if is_main:
            main_frames[name] += weight
if not count:
    raise SystemExit('No CPU samples in the selected Refresh interval; no CPU cost can be inferred.')


def ranked(counter, limit=40):
    return [{'frame': name, 'cpuMs': weight / 1e6} for name, weight in counter.most_common(limit)]


report = {
    'schemaVersion': 1, 'refreshIndex': refresh_index, 'window': refresh,
    'sampleRows': count, 'sampledCPUMs': total / 1e6, 'mainThreadCPUMs': main / 1e6,
    'skippedNonrunningRows': skipped_nonrunning,
    'workerCPUMs': (total - main) / 1e6, 'unstackedCPUMs': unstacked / 1e6,
    'inclusiveAppFrames': ranked(inclusive), 'mainThreadAppFrames': ranked(main_frames),
    'leafFrames': ranked(leaf),
    'limits': 'Sampled active CPU, not elapsed wall time. Concurrent worker CPU can exceed wall time. Inclusive frames overlap and cannot be added. Deduplicated/unknown symbols cannot identify a specific source function. No account values, HTTP contents or signpost messages exported.',
}
output.mkdir(parents=True, exist_ok=True)
(output / 'cpu-summary.json').write_text(json.dumps(report, indent=2) + '\n')
lines = ['# CPU inside completed Refresh', '', report['limits'], '',
         f"Refresh wall time: {refresh['durationMs']:.3f} ms; sampled CPU: {total / 1e6:.0f} ms; main: {main / 1e6:.0f} ms; workers: {(total - main) / 1e6:.0f} ms.", '']
for title, key in [('Inclusive application frames', 'inclusiveAppFrames'), ('Main-thread application frames', 'mainThreadAppFrames'), ('Leaf frames (all libraries)', 'leafFrames')]:
    lines += [f'## {title}', '', '| Frame | Sampled CPU ms |', '| --- | ---: |']
    for item in report[key]:
        lines.append(f"| {item['frame'].replace('|', '/')} | {item['cpuMs']:.0f} |")
    lines.append('')
(output / 'cpu-summary.md').write_text('\n'.join(lines))
print(f"Wrote {output / 'cpu-summary.md'}")

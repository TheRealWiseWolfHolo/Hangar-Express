#!/usr/bin/env python3
"""Pair only the app's static stage events; never export signpost messages."""
import collections
import json
import pathlib
import statistics
import sys
import xml.etree.ElementTree as ET

source, output = map(pathlib.Path, sys.argv[1:3])
root = ET.parse(source).getroot()
identities = {element.get('id'): element for element in root.iter() if element.get('id')}
stages = {
    'Refresh', 'FetchHTML', 'ParsePledgeHTML', 'ParseBuybackHTML',
    'NormalizeHangar', 'NormalizeBuyback', 'FleetProjection', 'GroupHangar',
    'GroupFleet', 'GroupBuyback', 'HangarSearch', 'FleetSearch', 'BuybackSearch',
    'CCURoute', 'SnapshotLoad', 'SnapshotSave',
    'ImageMockMiss', 'ImageMemoryHit', 'ImageDiskRestore', 'ImageCompositeMiss',
    'ImageCompositeMemoryHit', 'ImageCoalescedBatch',
}


def resolve(element):
    if element is not None and element.get('ref'):
        return identities[element.get('ref')]
    return element


def value(row, tag):
    element = resolve(row.find(tag))
    return element.text if element is not None else None


events = []
seen = set()
duplicate_export_rows = 0
for row in root.findall('.//row'):
    name = value(row, 'signpost-name')
    if name not in stages or value(row, 'subsystem') != 'com.wisewolfholo.Hanger-Express':
        continue
    process = resolve(row.find('process'))
    event = (
        int(value(row, 'event-time')), value(row, 'event-type'),
        (process.get('fmt', ''), name, value(row, 'os-signpost-identifier')),
    )
    # The same event can appear in both POI and explicit os_signpost tables.
    if event in seen:
        duplicate_export_rows += 1
        continue
    seen.add(event)
    events.append((event[0], len(events), event[1], event[2]))
if not events:
    raise SystemExit('No custom stage events captured. Add --instrument os_signpost; no intervals can be inferred.')

pending = {}
intervals = []
unmatched_ends = duplicate_begins = 0
for timestamp, _, kind, key in sorted(events):
    if kind == 'Begin':
        duplicate_begins += key in pending
        pending[key] = timestamp
    elif kind == 'End':
        start = pending.pop(key, None)
        if start is None:
            unmatched_ends += 1
        elif timestamp >= start:
            intervals.append({'stage': key[1], 'startMs': start / 1e6, 'durationMs': (timestamp - start) / 1e6})
intervals.sort(key=lambda interval: interval['startMs'])


def summarize(items):
    grouped = collections.defaultdict(list)
    for item in items:
        grouped[item['stage']].append(item['durationMs'])
    return [{
        'stage': name, 'count': len(values), 'sumMs': sum(values),
        'medianMs': statistics.median(values), 'maxMs': max(values),
    } for name, values in sorted(grouped.items())]


refreshes = []
for refresh in (item for item in intervals if item['stage'] == 'Refresh'):
    start, end = refresh['startMs'], refresh['startMs'] + refresh['durationMs']
    children = [item for item in intervals if item['stage'] != 'Refresh'
                and start <= item['startMs'] and item['startMs'] + item['durationMs'] <= end]
    refreshes.append({**refresh, 'containedStages': summarize(children)})
report = {
    'schemaVersion': 1, 'eventCount': len(events), 'duplicateExportRows': duplicate_export_rows,
    'unmatchedBegins': len(pending),
    'unmatchedEnds': unmatched_ends, 'duplicateBegins': duplicate_begins,
    'stages': summarize(intervals), 'refreshes': refreshes, 'intervals': intervals,
    'limits': 'Instrumented single recording, not a repeated latency baseline. Intervals overlap and cannot be added. FetchHTML counts logical calls, not confirmed network requests/cache misses. Refresh scope/outcome needs operator confirmation. No HTTP bodies, headers, messages or account identifiers exported.',
}
output.mkdir(parents=True, exist_ok=True)
(output / 'signpost-summary.json').write_text(json.dumps(report, indent=2) + '\n')
lines = ['# Static stage intervals', '', report['limits'], '',
         f"Completed intervals: {len(intervals)}. Unmatched begins/ends: {len(pending)}/{unmatched_ends}. Duplicate begins: {duplicate_begins}.", '',
         '| Stage | Calls | Sum ms | Median ms | Max ms |', '| --- | ---: | ---: | ---: | ---: |']
for stage in report['stages']:
    lines.append(f"| {stage['stage']} | {stage['count']} | {stage['sumMs']:.3f} | {stage['medianMs']:.3f} | {stage['maxMs']:.3f} |")
lines += ['', 'A missing stage is unobserved, not zero cost. Save the trace, source/build and anonymized workload metadata with this report.', '']
(output / 'signpost-summary.md').write_text('\n'.join(lines))
print(f'Wrote {output / "signpost-summary.md"}')

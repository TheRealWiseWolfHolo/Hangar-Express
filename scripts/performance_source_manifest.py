#!/usr/bin/env python3
"""Identify and optionally archive nonignored source, excluding local config."""
import argparse
import hashlib
import io
import json
import pathlib
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument('--archive', type=pathlib.Path)
args = parser.parse_args()

files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
suffixes = {
    '.swift', '.pbxproj', '.xcconfig', '.xcscheme', '.plist', '.sh', '.py',
    '.strings', '.json', '.png', '.jpg', '.jpeg', '.svg', '.pdf',
}
manifest = {}
for name in sorted(set(files)):
    path = pathlib.Path(name)
    if path.suffix in suffixes and path.is_file() and not path.is_symlink() and path.name != 'Local.xcconfig':
        manifest[name] = hashlib.sha256(path.read_bytes()).hexdigest()
report = {
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip(),
    'filesSHA256': manifest,
    'sourceTreeSHA256': hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
}
if args.archive:
    args.archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(args.archive, 'w:gz') as archive:
        for name in manifest:
            info = archive.gettarinfo(name, arcname=f'source/{name}')
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''
            info.pax_headers = {}
            with open(name, 'rb') as contents:
                archive.addfile(info, contents)
        data = (json.dumps(report, indent=2, sort_keys=True) + '\n').encode()
        info = tarfile.TarInfo('source-manifest.json')
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
    report['sourceArchive'] = args.archive.name
    report['sourceArchiveSHA256'] = hashlib.sha256(args.archive.read_bytes()).hexdigest()
print(json.dumps(report, indent=2, sort_keys=True))

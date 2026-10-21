"""Back up verified public release assets using an already authorized Quark CLI.

Never reads authorization files or runs login/install from a CI job.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def cli(script, *arguments):
    process = subprocess.run(
        ['node', str(script), *map(str, arguments)],
        capture_output=True, text=True, encoding='utf-8', timeout=1800)
    result = None
    for line in process.stdout.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if isinstance(item, dict) and item.get('type') == 'result':
            result = item
    # Do not forward raw CLI output, account information or authentication URLs
    # into public Actions logs. Operators can diagnose through a private session.
    if result is None or process.returncode or result.get('code') != 0:
        code = result.get('code') if result else 'no-result'
        raise RuntimeError(f'Quark operation {arguments[0]} failed ({code}); check authorization privately')
    return result.get('data', {})


def packages(directory, tag):
    if not re.fullmatch(r'v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', tag):
        raise RuntimeError('Only stable version tags may be backed up')
    version = tag[1:]
    names = [f'Hongputao-Windows-{version}-Setup.exe',
             f'Hongputao-Windows-{version}.zip',
             f'Hongputao-Android-arm64-{version}.apk',
             f'Hongputao-Source-{version}.zip']
    hashes = {}
    manifest = directory / 'SHA256SUMS.txt'
    for line in manifest.read_text(encoding='utf-8-sig').splitlines():
        match = re.fullmatch(r'([a-fA-F0-9]{64})\s+\*?([^/\\]+)', line)
        if match:
            hashes[match[2]] = match[1].lower()
    for name in names:
        path = directory / name
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            raise RuntimeError('Missing or invalid release package: ' + name)
        with path.open('rb') as source:
            actual = hashlib.file_digest(source, 'sha256').hexdigest()
        if actual != hashes.get(name):
            raise RuntimeError('Release checksum mismatch: ' + name)
    return [directory / name for name in [*names, 'SHA256SUMS.txt']]


def backup(directory, tag, script, parent, scratch):
    # Validation happens before creating any remote folders.
    files = packages(directory, tag)
    if not script.is_absolute() or not script.is_file():
        raise RuntimeError('Configure QUARK_CLI_PATH to the installed official CLI script')
    if not parent or not re.fullmatch(r'[A-Za-z0-9_-]+', parent):
        raise RuntimeError('Configure an explicitly selected QUARK_PARENT_FID')
    project = cli(script, 'create-folder', '--dir-path', 'Hongguo-video-pack', '--parent-fid', parent)
    project_id = project.get('fid')
    if not project_id:
        raise RuntimeError('Quark did not return the project folder identity')
    folder = cli(script, 'create-folder', '--dir-path', tag, '--parent-fid', project_id)
    folder_id = folder.get('fid')
    if not folder_id:
        raise RuntimeError('Quark did not return the version folder identity')
    existing = cli(script, 'browse', '--parent-fid', folder_id, '--all', '--task-dir', scratch)
    if existing.get('count') != 0 or existing.get('hasMore') is not False:
        raise RuntimeError('Version folder is not confirmed empty; refusing duplicate uploads or overwrites')
    result = cli(script, 'upload', *files, '--parent-fid', folder_id)
    if result.get('successCount') != len(files) or result.get('failedCount', 0) != 0:
        raise RuntimeError('Quark did not confirm all release files uploaded')
    final = cli(script, 'browse', '--parent-fid', folder_id, '--all', '--task-dir', scratch)
    if final.get('count') != len(files) or final.get('hasMore') is not False:
        raise RuntimeError('Quark folder listing did not confirm the expected file count')
    print(f'Quark backup completed: Hongguo-video-pack/{tag} ({len(files)} files).')
    print('Source SHA256 verified; cloud upload result and file count confirmed. Remote bytes were not downloaded for hash verification.')


def main():
    if len(sys.argv) != 3:
        raise RuntimeError('Usage: quark-backup.py vVERSION DIRECTORY')
    root = os.environ.get('RUNNER_TEMP')
    if not root:
        raise RuntimeError('RUNNER_TEMP must identify the task temporary directory')
    with tempfile.TemporaryDirectory(prefix='quark-release-', dir=root) as scratch:
        backup(Path(sys.argv[2]).resolve(), sys.argv[1],
               Path(os.environ.get('QUARK_CLI_PATH', '')),
               os.environ.get('QUARK_PARENT_FID', ''), scratch)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('Quark backup failed: ' + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)

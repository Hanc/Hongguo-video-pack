"""Remove only this job's known, disposable release download directory."""
import os
from pathlib import Path
import shutil
import sys


def cleanup(workspace, name):
    if name not in ('mirror-dist', 'quark-dist'):
        raise ValueError('Unknown disposable release directory')
    root = Path(workspace).resolve(strict=True)
    target = root / name
    if target.is_symlink() or (target.exists() and target.resolve().parent != root):
        raise ValueError('Refusing cleanup outside the workspace')
    if target.exists():
        if not target.is_dir():
            raise ValueError('Expected a disposable directory')
        shutil.rmtree(target)
    print('Removed disposable release downloads: ' + name)


if __name__ == '__main__':
    if len(sys.argv) != 2 or not os.environ.get('GITHUB_WORKSPACE'):
        raise SystemExit('Requires GITHUB_WORKSPACE and a known directory name')
    cleanup(os.environ['GITHUB_WORKSPACE'], sys.argv[1])

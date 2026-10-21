import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('release_cleanup', Path(__file__).parents[1] / 'cleanup-release-downloads.py')
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class ReleaseCleanupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('RUNNER_TEMP'))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_removes_only_named_release_directory(self):
        for name in ['mirror-dist', 'quark-dist', 'credentials']:
            folder = self.root / name
            folder.mkdir()
            (folder / 'keep-or-remove').write_text(name)
        cleanup.cleanup(self.root, 'mirror-dist')
        self.assertFalse((self.root / 'mirror-dist').exists())
        self.assertTrue((self.root / 'quark-dist/keep-or-remove').exists())
        self.assertTrue((self.root / 'credentials/keep-or-remove').exists())

    def test_rejects_parent_or_unknown_directory(self):
        for name in ['..', '../mirror-dist', 'credentials', '.', '']:
            with self.assertRaises(ValueError):
                cleanup.cleanup(self.root, name)

    def test_missing_directory_is_safe_after_early_job_failure(self):
        cleanup.cleanup(self.root, 'quark-dist')
        self.assertTrue(self.root.exists())


if __name__ == '__main__':
    unittest.main()

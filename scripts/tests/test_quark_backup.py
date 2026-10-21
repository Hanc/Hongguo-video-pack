import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('quark_backup', Path(__file__).parents[1] / 'quark-backup.py')
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class QuarkBackupTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('RUNNER_TEMP'))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / 'quark-drive.cjs'
        self.script.touch()
        names = ['Hongputao-Windows-0.3.0-Setup.exe', 'Hongputao-Windows-0.3.0.zip',
                 'Hongputao-Android-arm64-0.3.0.apk', 'Hongputao-Source-0.3.0.zip']
        manifest = []
        for name in names:
            data = name.encode()
            (self.root / name).write_bytes(data)
            manifest.append(hashlib.sha256(data).hexdigest() + '  ' + name)
        (self.root / 'SHA256SUMS.txt').write_text('\n'.join(manifest), encoding='utf-8')

    def run_backup(self):
        backup.backup(self.root, 'v0.3.0', self.script, 'selected-folder', self.root)

    def test_rejects_modified_asset_before_cloud_calls(self):
        (self.root / 'Hongputao-Android-arm64-0.3.0.apk').write_bytes(b'changed')
        with patch.object(backup, 'cli') as cli:
            with self.assertRaisesRegex(RuntimeError, 'checksum'):
                self.run_backup()
            cli.assert_not_called()

    def test_rejects_prerelease(self):
        with self.assertRaisesRegex(RuntimeError, 'stable'):
            backup.packages(self.root, 'v0.3.0-rc1')

    def test_refuses_existing_files_without_upload(self):
        with patch.object(backup, 'cli', side_effect=[{'fid': 'project'}, {'fid': 'version'},
                                                    {'count': 1, 'hasMore': False}]) as cli:
            with self.assertRaisesRegex(RuntimeError, 'refusing duplicate'):
                self.run_backup()
            self.assertEqual(cli.call_count, 3)

    def test_uploads_only_verified_allowlist_to_selected_folder(self):
        (self.root / 'private.keystore').write_bytes(b'not-for-upload')
        with patch.object(backup, 'cli', side_effect=[{'fid': 'project'}, {'fid': 'version'},
                {'count': 0, 'hasMore': False}, {'successCount': 5, 'failedCount': 0},
                {'count': 5, 'hasMore': False}]) as cli:
            self.run_backup()
            arguments = cli.call_args_list[3].args
            self.assertEqual(arguments[1], 'upload')
            self.assertEqual(arguments[-2:], ('--parent-fid', 'version'))
            self.assertEqual(len(arguments[2:-2]), 5)
            self.assertNotIn('private.keystore', str(arguments))

    def test_partial_upload_is_not_success(self):
        with patch.object(backup, 'cli', side_effect=[{'fid': 'project'}, {'fid': 'version'},
                {'count': 0, 'hasMore': False}, {'successCount': 4, 'failedCount': 1}]):
            with self.assertRaisesRegex(RuntimeError, 'all release files'):
                self.run_backup()

    def test_cli_failure_does_not_expose_auth_payload(self):
        output = json.dumps({'type': 'result', 'code': -1408, 'msg': 'secret-token-here'})
        with patch.object(backup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, output, 'secret')):
            with self.assertRaises(RuntimeError) as error:
                backup.cli(self.script, 'browse')
            self.assertNotIn('secret', str(error.exception))


if __name__ == '__main__':
    unittest.main()

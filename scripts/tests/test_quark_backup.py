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
        self.names = [*names, 'SHA256SUMS.txt']
        self.listing_number = 0

    def listing(self, names):
        self.listing_number += 1
        path = self.root / f'listing-{self.listing_number}.jsonl'
        path.write_text('\n'.join(json.dumps({'filename': name, 'size': (self.root / name).stat().st_size,
                                             'file_type': '1'}) for name in names), encoding='utf-8')
        return {'count': len(names), 'hasMore': False, 'file_path': str(path)}

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
                self.listing(self.names)]) as cli:
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

    def test_completed_backup_is_idempotent(self):
        complete = self.listing(self.names)
        with patch.object(backup, 'cli', side_effect=[{'fid': 'project'}, {'fid': 'version'}, complete, complete]) as cli:
            self.run_backup()
            self.assertNotIn('upload', [call.args[1] for call in cli.call_args_list])

    def test_partial_backup_uploads_only_missing_file(self):
        with patch.object(backup, 'cli', side_effect=[{'fid': 'project'}, {'fid': 'version'},
                self.listing(self.names[1:]), {'successCount': 1}, self.listing(self.names)]) as cli:
            self.run_backup()
            self.assertEqual(cli.call_args_list[3].args[2:-2], (self.root / self.names[0],))

    def test_existing_wrong_size_cannot_be_overwritten(self):
        listing = self.listing(self.names)
        path = Path(listing['file_path'])
        path.write_text(path.read_text().replace('"size": ', '"size": 99'), encoding='utf-8')
        with self.assertRaisesRegex(RuntimeError, 'refusing overwrite'):
            backup.missing_files(listing, backup.packages(self.root, 'v0.3.0'), self.root)

    def test_cli_failure_does_not_expose_auth_payload(self):
        output = json.dumps({'type': 'result', 'code': -1408, 'msg': 'secret-token-here'})
        with patch.object(backup.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, output, 'secret')):
            with self.assertRaises(RuntimeError) as error:
                backup.cli(self.script, 'browse')
            self.assertNotIn('secret', str(error.exception))


if __name__ == '__main__':
    unittest.main()

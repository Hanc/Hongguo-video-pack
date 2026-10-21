import importlib.util
import hashlib
import io
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gitee_sync', Path(__file__).parents[1] / 'gitee-sync.py')
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)


class ReleaseFinalizationTest(unittest.TestCase):
    def test_truncated_download_retries_and_checks_full_hash(self):
        data = b'complete installer bytes'
        partial = io.BytesIO(data[:4])
        partial.headers = {'Content-Length': str(len(data))}
        complete = io.BytesIO(data)
        complete.headers = {'Content-Length': str(len(data))}
        with patch.object(mirror.urllib.request, 'urlopen', side_effect=[partial, complete]) as fetch:
            mirror.verify_public('https://gitee.com/adoin/Hongguo-video-pack/releases/download/v0.3.0/setup.exe',
                                 hashlib.sha256(data).hexdigest())
            self.assertEqual(fetch.call_count, 2)

    def test_repeated_bad_hash_never_passes(self):
        replies = [io.BytesIO(b'bad'), io.BytesIO(b'bad')]
        for reply in replies:
            reply.headers = {'Content-Length': '3'}
        with patch.object(mirror.urllib.request, 'urlopen', side_effect=replies):
            with self.assertRaisesRegex(RuntimeError, 'failed twice'):
                mirror.verify_public('https://gitee.com/adoin/Hongguo-video-pack/releases/download/v0.3.0/setup.exe',
                                     hashlib.sha256(b'expected').hexdigest())

    def run_release(self, fail_verification=False, confirmed=True):
        assets = [{'name': name, 'browser_download_url':
                   'https://gitee.com/adoin/Hongguo-video-pack/releases/download/v0.3.0/' + name}
                  for name in ['SHA256SUMS.txt', 'source.zip', 'app.apk', 'setup.exe']]
        release = {'id': 1, 'name': 'Release title', 'body': 'Existing notes',
                   'prerelease': True, 'assets': assets}
        operations = []

        def request(path, method='GET', body=None):
            operations.append((method, body))
            if method == 'PATCH':
                return {'prerelease': not confirmed}
            return release

        with patch.object(mirror, 'packages', return_value=(
                ['setup.exe', 'app.apk', 'source.zip'],
                {'setup.exe': 'a', 'app.apk': 'b', 'source.zip': 'c'})), \
             patch.object(mirror, 'digest', return_value='sums'), \
             patch.object(mirror.subprocess, 'check_output', return_value=
                b'{"isDraft":false,"isPrerelease":false,"body":"Original notes"}'), \
             patch.object(mirror, 'request', side_effect=request), \
             patch.object(mirror, 'verify_public', side_effect=
                RuntimeError('checksum mismatch') if fail_verification else None):
            try:
                mirror.mirror_release('v0.3.0', Path('unused-test-directory'))
            except RuntimeError:
                return operations, False
        return operations, True

    def test_finalization_preserves_required_metadata(self):
        operations, success = self.run_release()
        self.assertTrue(success)
        self.assertEqual(operations[-1], ('PATCH', {
            'tag_name': 'v0.3.0', 'name': 'Release title',
            'body': 'Existing notes', 'prerelease': False}))

    def test_verification_failure_cannot_publish(self):
        operations, success = self.run_release(fail_verification=True)
        self.assertFalse(success)
        self.assertFalse(any(method == 'PATCH' for method, _ in operations))

    def test_api_must_confirm_final_state(self):
        _, success = self.run_release(confirmed=False)
        self.assertFalse(success)


if __name__ == '__main__':
    unittest.main()

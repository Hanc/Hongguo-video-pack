import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'configure-ci-signing.py'

class SigningConfigurationTest(unittest.TestCase):
    def run_script(self, root, values):
        env = {k:v for k,v in os.environ.items() if not k.startswith('ANDROID_')}
        env.update(values, RUNNER_TEMP=str(root / 'temp'))
        return subprocess.run([sys.executable, str(SCRIPT)], cwd=root, env=env, capture_output=True, text=True)

    def test_missing_secrets_leave_no_configuration(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); (root/'android').mkdir(); (root/'temp').mkdir()
            result = self.run_script(root, {})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root/'android/key.properties').exists())

    def test_secret_data_is_not_printed_and_existing_config_is_preserved(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name); (root/'android').mkdir(); (root/'temp').mkdir()
            values = dict(ANDROID_KEYSTORE_BASE64=base64.b64encode(b'unit-test-fixture').decode(), ANDROID_STORE_PASSWORD='unit password', ANDROID_KEY_ALIAS='unit-alias', ANDROID_KEY_PASSWORD='unit:password')
            result = self.run_script(root, values)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root/'temp/hongputao-release.jks').read_bytes(), b'unit-test-fixture')
            text = (root/'android/key.properties').read_text()
            self.assertIn('storePassword=unit\\ password', text)
            self.assertIn('keyPassword=unit\\:password', text)
            self.assertNotIn('unit password', result.stdout + result.stderr)
            second = self.run_script(root, values)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual((root/'android/key.properties').read_text(), text)

if __name__ == '__main__':
    unittest.main()

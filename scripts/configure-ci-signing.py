"""Materialize CI signing secrets locally; never print secrets or commit keys."""
import base64
import os
from pathlib import Path

names = ['ANDROID_KEYSTORE_BASE64', 'ANDROID_STORE_PASSWORD', 'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD']
missing = [name for name in names if not os.environ.get(name)]
if missing:
    raise SystemExit('Missing repository signing secrets: ' + ', '.join(missing))

properties = Path('android/key.properties')
if properties.exists():
    raise SystemExit('Refusing to replace an existing signing configuration')

keystore = Path(os.environ['RUNNER_TEMP']) / 'hongputao-release.jks'
keystore.write_bytes(base64.b64decode(''.join(os.environ[names[0]].split()), validate=True))
keystore.chmod(0o600)

def escaped(value):
    output = ''
    for char in value:
        if char in '\\ :=#!':
            output += '\\' + char
        elif 32 <= ord(char) < 127:
            output += char
        elif ord(char) <= 0xffff:
            output += '\\u%04x' % ord(char)
        else:
            encoded = char.encode('utf-16-be')
            output += ''.join('\\u%04x' % int.from_bytes(encoded[i:i+2], 'big') for i in range(0, len(encoded), 2))
    return output

values = {'storeFile': str(keystore), 'storePassword': os.environ[names[1]],
          'keyAlias': os.environ[names[2]], 'keyPassword': os.environ[names[3]]}
properties.write_text(''.join(k + '=' + escaped(v) + '\n' for k, v in values.items()), encoding='ascii')
properties.chmod(0o600)
print('Release signing configured in runner-only files.')

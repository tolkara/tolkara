"""The public root list and its packaging (tools/package_public_roots.py)."""
import base64
import hashlib
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import package_public_roots  # noqa: E402

LIST = ROOT / 'translation/Security/PublicRoots/cacert.pem'


def pem(der):
    return '-----BEGIN CERTIFICATE-----\n' + base64.b64encode(der).decode() + '\n-----END CERTIFICATE-----\n'


class PublicRootsTests(unittest.TestCase):
    def test_list_is_the_recorded_one(self):
        # The file is third-party data, kept unchanged: its hash is in the README beside it.
        digest = hashlib.sha256(LIST.read_bytes()).hexdigest()
        self.assertIn(digest, (LIST.parent / 'README.md').read_text().replace('\n', ''))

    def test_packaging(self):
        found = package_public_roots.certificates(LIST.read_text(encoding='utf-8'))
        # The adapter's limits (translation/Security/Keychain.m): up to 1024 certificates of up to 64 KiB.
        self.assertTrue(100 <= len(found) <= 1024)
        self.assertTrue(all(c[0] == 0x30 and len(c) <= 65536 for c in found))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'roots.plist'
            sys.argv = ['package_public_roots.py', str(LIST), str(output)]
            package_public_roots.main()
            self.assertEqual(plistlib.loads(output.read_bytes()), found)
            self.assertLess(output.stat().st_size, 4 * 1024 * 1024)

    def test_malformed_lists(self):
        good = bytes([0x30]) + bytes(80)
        self.assertEqual(package_public_roots.certificates('junk\n' + pem(good) + 'more'), [good])
        for text in ('', 'no certificates here', pem(good) + pem(good), pem(bytes([0x31]) + bytes(80)), pem(b'short'),
                     pem(bytes([0x30]) + bytes(70000)),
                     '-----BEGIN CERTIFICATE-----\n!!!\n-----END CERTIFICATE-----\n'):
            with self.assertRaises(ValueError, msg=text[:40]): package_public_roots.certificates(text)


if __name__ == '__main__':
    unittest.main()

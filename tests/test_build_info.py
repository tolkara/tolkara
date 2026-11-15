"""tools/build_info.py: a Battle.net install is copied only when its executable
and its .build.info line agree."""
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import build_info

HEADER = 'Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|Version!STRING:0|KeyRing!HEX:16|Product!STRING:0'
FLAVOR = 'Product Flavor!STRING:0\nwowf\n'


def info(*lines): return '\n'.join([HEADER, *lines]) + '\n'


class BuildInfo(unittest.TestCase):
    def test_whole_install(self):
        text = info('eu|1|aa|1.15.9.70576||wow_classic_era', 'eu|1|bb|1.60.1.70938||wowf')
        self.assertIsNone(build_info.problem(text, FLAVOR, '1.60.1.70938'))
        self.assertEqual(build_info.product(FLAVOR), 'wowf')
        self.assertEqual(build_info.rows(text)[1]['Version'], '1.60.1.70938')

    def test_update_under_way(self):
        # The line still names the build before the update: the reported failure.
        message = build_info.problem(info('eu|1|bb|1.60.1.70888||wowf'), FLAVOR, '1.60.1.70938')
        self.assertIn('1.60.1.70938', message); self.assertIn('1.60.1.70888', message); self.assertIn('Battle.net', message)
        self.assertIn('not active', build_info.problem(info('eu|0|bb|1.60.1.70938||wowf'), FLAVOR, '1.60.1.70938'))

    def test_another_region_line_is_enough(self):
        text = info('us|0|bb|1.60.1.70888||wowf', 'eu|1|bb|1.60.1.70938||wowf')
        self.assertIsNone(build_info.problem(text, FLAVOR, '1.60.1.70938'))

    def test_missing_parts(self):
        self.assertIn('no installed product', build_info.problem(info('eu|1|aa|1.15.9.70576||wow_classic_era'), FLAVOR, '1.60.1.70938'))
        self.assertIn('.flavor.info', build_info.problem(info('eu|1|bb|1.60.1.70938||wowf'), '', '1.60.1.70938'))
        self.assertIsNotNone(build_info.problem('', FLAVOR, '1.60.1.70938'))
        self.assertIsNotNone(build_info.problem(info('eu|1|bb|1.60.1.70938||wowf'), FLAVOR, None))
        # A malformed line is not a product line.
        self.assertIsNotNone(build_info.problem(info('eu|1|1.60.1.70938|wowf'), FLAVOR, '1.60.1.70938'))

    def test_check_reads_the_install(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); app = root / '_forever_/Game.app/Contents'; app.mkdir(parents=True)
            self.assertIsNotNone(build_info.check(root, '_forever_', '_forever_/Game.app/Contents/Info.plist'))
            (root / '.build.info').write_text(info('eu|1|bb|1.60.1.70938||wowf'))
            (root / '_forever_/.flavor.info').write_text(FLAVOR)
            (app / 'Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleVersion</key><string>1.60.1.70938</string></dict></plist>')
            self.assertIsNone(build_info.check(root, '_forever_', '_forever_/Game.app/Contents/Info.plist'))


if __name__ == '__main__': unittest.main()

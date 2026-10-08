"""Build a real adapter whose re-export is absent from the import surface."""
import json
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class AdapterDependencyTests(unittest.TestCase):
    def test_audio_unit_builds_audio_toolbox_including_cached_builds(self):
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator',
                                       '--show-sdk-path'], text=True).strip()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            surface = root / 'surface.json'
            surface.write_text(json.dumps({'sdk': sdk, 'translation': {'AudioUnit': {
                'install_name': '@rpath/akAudioUnit.dylib',
                'symbols': [['_AudioComponentFindNext', 'func',
                             '/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox']],
                'real_tbd': None, 'provider_tbds': [
                    sdk + '/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox.tbd']}}}))
            for name in ('first', 'cached'):
                output = root / name
                subprocess.run(['python3', str(ROOT / 'tools/build_shims.py'),
                                'iossim', str(surface), str(output)], check=True,
                               capture_output=True, text=True)
                self.assertTrue((output / 'akAudioToolbox.dylib').is_file())
                commands = subprocess.check_output(['xcrun', 'otool', '-l',
                                                     str(output / 'akAudioUnit.dylib')], text=True)
                self.assertIn('LC_REEXPORT_DYLIB', commands)
                self.assertIn('@rpath/akAudioToolbox.dylib', commands)
                reexports = re.findall(r'cmd LC_REEXPORT_DYLIB\s+cmdsize \d+\s+name ([^\n]+)', commands)
                self.assertTrue(reexports)
                self.assertTrue(reexports[0].startswith('@rpath/akAudioToolbox.dylib '),
                                'Native AudioToolbox must not hide the RemoteIO adapter')


if __name__ == '__main__':
    unittest.main()

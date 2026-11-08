"""A build made for no particular application: adapters, no map."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/emulation/generic-app'
EXPERIMENTAL_OUT = ROOT / 'build/emulation/generic-app-experimental'
sys.path.insert(0, str(ROOT / 'tools'))
import classify

# The default build: no experimental adapter opted into.
os.environ.pop('TOLKARA_EXPERIMENTAL_ADAPTERS', None)


def written():
    # Hand-written frameworks with sources or only linker flags, as build_shims.py counts them.
    for leaf in sorted(classify.adapter_leaves() - classify.translation_leaves('absent')):
        directory = ROOT / 'translation' / leaf
        if leaf != 'AKSupport' and any(source.suffix in ('.c', '.m') or source.name == 'ldflags' for source in directory.iterdir()):
            yield leaf


def generic_build(out, **settings):
    shutil.rmtree(out, ignore_errors=True)
    # What an earlier build for one executable leaves behind in the same place.
    (out / 'Guest').mkdir(parents=True)
    (out / 'Guest/libraries.json').write_text('{}')
    (out / 'Guest/absent.json').write_text('["Stale"]')
    (out / 'Guest/opt-in.json').write_text('["Stale"]')
    # The build phase's own step, with no executable named.
    env = dict(os.environ, NATIVE_GUEST_SHIMS='GENERIC', PLATFORM_NAME='iphoneos', **settings)
    # The iOS SDK comes with Xcode, as for tools/run.sh and tools/install.sh.
    env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    result = subprocess.run([str(ROOT / 'tools/build_emulated_guest.sh'), str(out), ''],
                            cwd=ROOT, env=env, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('generic build failed:\n' + result.stdout + result.stderr)


def reexports(library):
    return 'LC_REEXPORT_DYLIB' in subprocess.run(['otool', '-l', str(library)],
                                                 capture_output=True, text=True, check=True).stdout


class GenericBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        generic_build(OUT)

    def test_one_adapter_per_written_framework(self):
        expected = {'ak%s.dylib' % leaf for leaf in written()}
        self.assertTrue(expected)
        present = {path.name for path in (OUT / 'Frameworks').glob('*.dylib')}
        self.assertEqual(present, expected | {'libAKSupport.dylib'})

    def test_no_library_map(self):
        self.assertFalse((OUT / 'Guest/libraries.json').exists())

    def test_nothing_presented_as_absent(self):
        self.assertFalse((OUT / 'Guest/absent.json').exists())

    def test_no_opt_in_adapters(self):
        self.assertFalse((OUT / 'Guest/opt-in.json').exists())

    def test_audio_unit_is_the_audio_toolbox_adapter(self):
        # iOS has no AudioUnit library; its adapter re-exports the AudioToolbox one.
        load = subprocess.run(['otool', '-l', str(OUT / 'Frameworks/akAudioUnit.dylib')], capture_output=True, text=True, check=True).stdout
        self.assertIn('@rpath/akAudioToolbox.dylib', load.split('LC_REEXPORT_DYLIB', 1)[-1])

    def test_experimental_adapters_left_out(self):
        self.assertFalse((OUT / 'Frameworks/akGameController.dylib').exists())
        self.assertTrue(reexports(OUT / 'Frameworks/akMetal.dylib'))


class ExperimentalGenericBuildTests(unittest.TestCase):
    """TOLKARA_EXPERIMENTAL_ADAPTERS opts into translation/<Leaf>/ marked experimental."""

    @classmethod
    def setUpClass(cls):
        generic_build(EXPERIMENTAL_OUT, TOLKARA_EXPERIMENTAL_ADAPTERS='GameController:MetalFX')

    def test_standalone_adapter_reexports_nothing(self):
        self.assertFalse(reexports(EXPERIMENTAL_OUT / 'Frameworks/akGameController.dylib'))
        self.assertTrue(reexports(EXPERIMENTAL_OUT / 'Frameworks/akMetal.dylib'))

    def test_absent_libraries_listed_for_the_runtime(self):
        self.assertEqual(json.loads((EXPERIMENTAL_OUT / 'Guest/absent.json').read_text()), ['MetalFX'])
        self.assertFalse((EXPERIMENTAL_OUT / 'Frameworks/akMetalFX.dylib').exists())
        self.assertFalse((EXPERIMENTAL_OUT / 'Guest/libraries.json').exists())

    def test_opt_in_adapters_listed_for_the_runtime(self):
        # Built, but used only for a profile whose TOLKARA_ADAPTERS names it
        # (Cyberpunk 2077's); World of Warcraft keeps iOS's GameController.
        self.assertTrue((EXPERIMENTAL_OUT / 'Frameworks/akGameController.dylib').exists())
        self.assertEqual(json.loads((EXPERIMENTAL_OUT / 'Guest/opt-in.json').read_text()), ['GameController'])
        profiles = {path.parent.name: json.loads(path.read_text()) for path in (ROOT / 'profiles').glob('*/profile.json')}
        users = {name for name, profile in profiles.items()
                 if 'GameController' in profile.get('environment', {}).get('TOLKARA_ADAPTERS', '').replace(',', ':').split(':')}
        self.assertEqual(users, {'cyberpunk-2077'})


if __name__ == '__main__':
    unittest.main()

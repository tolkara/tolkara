"""Validate native backend platform/export checks and specific/generic maps."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from embed_vulkan_runtime import embed


class EmbedVulkanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.frameworks = self.root / 'Frameworks'
        self.mapping = self.root / 'libraries.json'

    def tearDown(self):
        self.temporary.cleanup()

    def library(self, sdk='iphonesimulator', exports=True):
        source = self.root / 'fixture.c'
        source.write_text('void *vkGetInstanceProcAddr(void) { return 0; }\n' +
                          ('void vkCreateMetalSurfaceEXT(void) {}\n' if exports else ''))
        library = self.root / 'fixture.dylib'
        target = {'iphoneos': 'arm64-apple-ios17.0',
                  'iphonesimulator': 'arm64-apple-ios17.0-simulator',
                  'macosx': 'arm64-apple-macos14.0'}[sdk]
        sdkpath = subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', 'clang', '-target', target, '-isysroot', sdkpath,
                        '-dynamiclib', '-Wall', '-Wextra', '-Werror', str(source),
                        '-o', str(library)], check=True)
        return library

    def test_specific_mapping_preserves_other_libraries(self):
        self.mapping.write_text(json.dumps({'AppKit': '@rpath/akAppKit.dylib'}))
        embed(self.library(), 'iossim', self.frameworks, self.mapping)
        mapping = json.loads(self.mapping.read_text())
        self.assertEqual(mapping['AppKit'], '@rpath/akAppKit.dylib')
        self.assertEqual(mapping['@rpath/libMoltenVK.dylib'], '@rpath/aklibMoltenVK.dylib')
        identity = subprocess.check_output(['xcrun', 'otool', '-D',
                                            str(self.frameworks / 'aklibMoltenVK.dylib')], text=True)
        self.assertIn('@rpath/aklibMoltenVK.dylib', identity)

    def test_generic_build_does_not_gain_a_specific_map(self):
        embed(self.library('iphoneos'), 'ios', self.frameworks, self.mapping)
        self.assertTrue((self.frameworks / 'aklibMoltenVK.dylib').exists())
        self.assertFalse(self.mapping.exists())

    def test_wrong_platform_is_rejected_before_copying(self):
        for sdk in ('macosx', 'iphoneos'):
            with self.subTest(sdk=sdk), self.assertRaisesRegex(ValueError, 'IOSSIMULATOR'):
                embed(self.library(sdk), 'iossim', self.frameworks, self.mapping)
            self.assertFalse(self.frameworks.exists())

    def test_missing_surface_export_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'vkCreateMetalSurfaceEXT'):
            embed(self.library(exports=False), 'iossim', self.frameworks, self.mapping)
        self.assertFalse(self.frameworks.exists())


if __name__ == '__main__':
    unittest.main()

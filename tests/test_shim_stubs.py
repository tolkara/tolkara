"""Compile real logging shims for builtin, SDK and Darwin suffixed symbols."""
import ctypes
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from shim_stubs import function_stub


class FunctionStubTests(unittest.TestCase):
    def test_builtin_and_declared_names_keep_their_exports(self):
        symbols = ['___clear_cache', '_malloc', '_syslog$DARWIN_EXTSN']
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'stubs.c'
            library = Path(directory) / 'stubs.dylib'
            source.write_text('#include <stdlib.h>\n#include <syslog.h>\n'
                              'static long hits;\n'
                              'void AKStubHit(const char *name, void *caller) '
                              '{ (void)name; (void)caller; ++hits; }\n'
                              'long AKTestHits(void) { return hits; }\n' +
                              '\n'.join(function_stub(symbol) for symbol in symbols))
            subprocess.run(['xcrun', 'clang', '-dynamiclib', '-Wall', '-Wextra',
                            '-Werror', str(source), '-o', str(library)], check=True)
            exports = subprocess.check_output(['xcrun', 'nm', '-gUj', str(library)], text=True).splitlines()
            for symbol in symbols:
                self.assertIn(symbol, exports)
            loaded = ctypes.CDLL(str(library))
            for symbol in symbols:
                stub = getattr(loaded, symbol[1:])
                stub.restype = ctypes.c_long
                self.assertEqual(stub(), 0)
                self.assertEqual(stub(), 0)
            loaded.AKTestHits.restype = ctypes.c_long
            self.assertEqual(loaded.AKTestHits(), len(symbols))


if __name__ == '__main__':
    unittest.main()

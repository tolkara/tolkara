import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from check_profile import check


class ProfileTests(unittest.TestCase):
    def write(self, value):
        handle = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False)
        json.dump(value, handle); handle.close(); self.addCleanup(Path(handle.name).unlink)
        return handle.name

    def test_shipped_profiles(self):
        paths = list((ROOT / 'profiles').glob('*/profile.json'))
        self.assertTrue(paths)
        for path in paths: check(path)

    def test_rejects_escape_and_unknown_keys(self):
        good = {'id': 'a', 'name': 'A', 'workingDirectory': 'A', 'executable': 'A.app/Contents/MacOS/A'}
        check(self.write(good))
        for change in ({'executable': '/bin/sh'}, {'workingDirectory': '../x'}, {'command': 'x'}, {'name': ''}):
            with self.assertRaises(ValueError): check(self.write({**good, **change}))

    def test_case_aliases(self):
        good = {'id': 'a', 'name': 'A', 'workingDirectory': 'A', 'executable': 'A.app/Contents/MacOS/A'}
        check(self.write({**good, 'caseAliases': {'archive/mac': 'Mac', 'Data': 'data'}}))
        check(self.write({**good, 'caseAliases': {}}))
        for aliases in ([], 'archive/mac', {'archive/mac': 1}, {'archive/mac': None}, {'archive/mac': ['Mac']},
                        {'/archive/mac': 'Mac'}, {'../mac': 'Mac'}, {'archive/../mac': 'Mac'}, {'': 'Mac'},
                        {'archive//mac': 'Mac'}, {'archive/mac/': 'Mac'}, {'archive/mac': ''},
                        {'archive/mac': '../Mac'}, {'archive/mac': 'archive/Mac'}, {'archive/mac': 'mac'},
                        {'archive/mac': 'Other'}):
            with self.assertRaises(ValueError, msg=repr(aliases)): check(self.write({**good, 'caseAliases': aliases}))

    def test_runtime_command_line(self):
        # A compatibility runtime elsewhere in Documents, with its command line: data only.
        good = {'id': 'w', 'name': 'W', 'workingDirectory': 'W/game', 'runtime': 'W/Runtime', 'executable': 'bin/run',
                'arguments': ['game.exe', '--windowed'], 'environment': {'PREFIX': '${Documents}/W/prefix', '_X1': ''},
                'libraries': ['lib/core.so'], 'codePool': 64}
        check(self.write(good))
        for change in ({'runtime': '../R'}, {'runtime': '/R'}, {'runtime': 'R/'}, {'runtime': ''}, {'runtime': 'R/./bin'},
                       {'arguments': 'game.exe'}, {'arguments': [1]}, {'arguments': ['x'] * 65}, {'arguments': ['y' * 4097]},
                       {'environment': ['A=1']}, {'environment': {'1X': 'a'}}, {'environment': {'A B': 'a'}},
                       {'environment': {'A': 1}}, {'environment': {'A': 'y' * 4097}}, {'environment': {f'V{i}': '' for i in range(65)}},
                       {'libraries': 'lib/core.so'}, {'libraries': ['../core.so']}, {'libraries': ['/lib/core.so']},
                       {'libraries': ['lib/./core.so']}, {'libraries': [1]}, {'libraries': [f'l{i}.so' for i in range(65)]},
                       {'codePool': 0}, {'codePool': 1025}, {'codePool': '64'}, {'codePool': 1.5}, {'codePool': True}):
            with self.assertRaises(ValueError): check(self.write({**good, **change}))
        # A runtime's libraries only come with a runtime.
        without = {k: v for k, v in good.items() if k != 'runtime'}
        with self.assertRaises(ValueError): check(self.write(without))
        without = {k: v for k, v in good.items() if k not in ('runtime', 'libraries')}
        with self.assertRaises(ValueError): check(self.write(without))

    def test_setup(self):
        # What the Mac app reads: plain data, https links, the destination above the working directory.
        good = {'id': 'a', 'name': 'A', 'workingDirectory': 'Games/A', 'executable': 'A.app/Contents/MacOS/A',
                'setup': {'source': '/Applications/Games', 'destination': 'Games',
                          'getApp': {'name': 'Store', 'url': 'https://example.com/get', 'path': '/Applications/Store.app', 'steps': ['Install A.']},
                          'risk': {'summary': 'Online game.', 'history': [{'when': '2020', 'text': 'Tolerated.'}],
                                   'links': [{'title': 'Source', 'url': 'https://example.com/source'}]}}}
        check(self.write(good))
        check(self.write({**good, 'setup': {}}))
        check(self.write({**good, 'setup': {'destination': 'Games/A'}}))
        for setup in ([], {'command': 'x'}, {'source': 'Applications/Games'}, {'destination': 'Other'}, {'destination': 'Games/A/B'},
                      {'destination': 'Gam'}, {'destination': '../Games'}, {'installer': '../install.py'}, {'installer': 'install.sh'},
                      {'installer': 'missing.py'}, {'getApp': {'name': 'Store'}}, {'getApp': {'name': 'Store', 'url': 'http://example.com'}},
                      {'getApp': {'name': 'Store', 'url': 'https://example.com', 'path': 'Store.app'}},
                      {'getApp': {'name': 'Store', 'url': 'https://example.com', 'steps': 'Install'}},
                      {'getApp': {'name': 'Store', 'url': 'https://example.com', 'run': 'x'}},
                      {'risk': {}}, {'risk': {'summary': ''}}, {'risk': {'summary': 'x', 'history': [{'when': '2020'}]}},
                      {'risk': {'summary': 'x', 'links': [{'title': 'x', 'url': 'javascript:alert(1)'}]}},
                      {'risk': {'summary': 'x', 'history': [{'when': 'a', 'text': 'b'}] * 17}}):
            with self.assertRaises(ValueError, msg=repr(setup)): check(self.write({**good, 'setup': setup}))
        # Not for a profile run by a compatibility runtime.
        runtime = {'id': 'w', 'name': 'W', 'workingDirectory': 'W/game', 'runtime': 'W/Runtime', 'executable': 'bin/run'}
        with self.assertRaises(ValueError): check(self.write({**runtime, 'setup': {}}))

    def test_heroes3_hd_settings(self):
        # The staged copy's HD mod settings: pinned keys replaced in place, CRLF kept, defaults used on a fresh copy.
        sys.path.insert(0, str(ROOT / 'profiles' / 'heroes3-hota'))
        import install
        with tempfile.TemporaryDirectory() as directory:
            game = Path(directory)
            folder = game / '_HD3_Data' / 'Settings'
            folder.mkdir(parents=True)
            (folder / '#default#hota.ini').write_bytes(b'<Version> = 1\r\n<Update.CheckAtStart> = 1\r\n<Graphics.RenderingMode> = -1\r\n')
            install.hd_settings(game)
            lines = (folder / 'hota.ini').read_bytes().split(b'\r\n')
            self.assertEqual(lines, [b'<Version> = 1', b'<Update.CheckAtStart> = 0', b'<Graphics.RenderingMode> = 2', b''])
            (folder / 'hota.ini').write_bytes(b'<Version> = 2\r\n<Update.CheckAtStart> = 1\r\n')
            install.hd_settings(game)
            self.assertEqual((folder / 'hota.ini').read_bytes(),
                             b'<Graphics.RenderingMode> = 2\r\n<Version> = 2\r\n<Update.CheckAtStart> = 0\r\n')
            (folder / 'hota.ini').unlink(); (folder / '#default#hota.ini').unlink()
            install.hd_settings(game)
            self.assertFalse((folder / 'hota.ini').exists())

    def test_heroes3_prefix_settings(self):
        # FEX for x86 and x86-64, and the iPad keyboard: Option is Alt, Command sends nothing.
        sys.path.insert(0, str(ROOT / 'profiles' / 'heroes3-hota'))
        import install
        commands = install.registry_commands()
        self.assertIn(['reg', 'add', r'HKLM\Software\Microsoft\Wow64\x86', '/ve', '/d', 'libwow64fex.dll', '/f'], commands)
        mac = {c[4]: c[6] for c in commands if c[2] == r'HKCU\Software\Wine\Mac Driver'}
        self.assertEqual(mac, {'LeftOptionIsAlt': 'y', 'RightOptionIsAlt': 'y', 'LeftCommandIsIgnored': 'y', 'RightCommandIsIgnored': 'y'})
        self.assertTrue(all(c[:2] == ['reg', 'add'] and c[-1] == '/f' for c in commands))

    def test_heroes3_device_runtime(self):
        # The iPad gets the runtime's Unix side, data, 32-bit modules, the server library, the
        # native modules a WoW64 process loads and the placed libraries: nothing else.
        sys.path.insert(0, str(ROOT / 'profiles' / 'heroes3-hota'))
        import install
        with tempfile.TemporaryDirectory() as directory:
            runtime = Path(directory) / 'Wine'
            files = ['bin/wine', 'bin/wineserver', 'bin/wineserver.so', 'share/wine/nls/l_intl.nls',
                     'lib/wine/aarch64-unix/wine', 'lib/wine/aarch64-unix/ntdll.so',
                     'lib/wine/i386-windows/kernel32.dll', 'lib/wine/i386-windows/libkernel32.a',
                     'lib/wine/aarch64-windows/ntdll.dll', 'lib/wine/aarch64-windows/libwow64fex.dll',
                     'lib/wine/aarch64-windows/shell32.dll', 'lib/libfreetype.6.dylib', 'lib/libavcodec.63.dylib']
            for name in files:
                (runtime / name).parent.mkdir(parents=True, exist_ok=True)
                (runtime / name).write_text(name)
            staged = install.device_runtime(runtime, Path(directory) / 'stage')
            kept = sorted(str(p.relative_to(staged)) for p in staged.rglob('*') if p.is_file())
            self.assertEqual(kept, sorted(['bin/wineserver.so', 'share/wine/nls/l_intl.nls', 'lib/wine/aarch64-unix/wine',
                                           'lib/wine/aarch64-unix/ntdll.so', 'lib/wine/i386-windows/kernel32.dll',
                                           'lib/wine/aarch64-windows/ntdll.dll', 'lib/wine/aarch64-windows/libwow64fex.dll',
                                           'lib/libfreetype.6.dylib']))
            self.assertEqual((staged / 'lib/wine/aarch64-unix/ntdll.so').read_text(), 'lib/wine/aarch64-unix/ntdll.so')
            # The prefix goes without its links into this Mac and without a server's state.
            prefix = Path(directory) / 'prefix'
            for name in ['system.reg', 'volatile.reg', 'drive_c/windows/system32/kernel32.dll', '.wineserver/server-1-2/socket']:
                (prefix / name).parent.mkdir(parents=True, exist_ok=True)
                (prefix / name).write_text(name)
            (prefix / 'drive_c/game/games').mkdir(parents=True)
            (prefix / 'dosdevices').mkdir()
            os.symlink('../drive_c', prefix / 'dosdevices' / 'c:')
            (prefix / 'drive_c/users/vk').mkdir(parents=True)
            os.symlink('/Users/vk/Documents', prefix / 'drive_c/users/vk/Documents')
            staged = install.device_prefix(prefix, Path(directory) / 'prefix-stage')
            kept = sorted(str(p.relative_to(staged)) for p in staged.rglob('*') if not p.is_dir())
            self.assertEqual(kept, ['drive_c/windows/system32/kernel32.dll', 'system.reg', 'volatile.reg'])
            # An empty folder the game saves into comes along; the links' folders do not.
            self.assertTrue((staged / 'drive_c/game/games').is_dir())
            self.assertFalse((staged / 'dosdevices').exists() or (staged / '.wineserver').exists())


if __name__ == '__main__': unittest.main()

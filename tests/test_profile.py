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
        check(self.write({**good, 'codePool': 1550}))
        check(self.write({**good, 'codePool': 2048}))
        for change in ({'runtime': '../R'}, {'runtime': '/R'}, {'runtime': 'R/'}, {'runtime': ''}, {'runtime': 'R/./bin'},
                       {'arguments': 'game.exe'}, {'arguments': [1]}, {'arguments': ['x'] * 65}, {'arguments': ['y' * 4097]},
                       {'environment': ['A=1']}, {'environment': {'1X': 'a'}}, {'environment': {'A B': 'a'}},
                       {'environment': {'A': 1}}, {'environment': {'A': 'y' * 4097}}, {'environment': {f'V{i}': '' for i in range(65)}},
                       {'libraries': 'lib/core.so'}, {'libraries': ['../core.so']}, {'libraries': ['/lib/core.so']},
                       {'libraries': ['lib/./core.so']}, {'libraries': [1]}, {'libraries': [f'l{i}.so' for i in range(65)]},
                       {'codePool': 0}, {'codePool': 2049}, {'codePool': '64'}, {'codePool': 1.5}, {'codePool': True}):
            with self.assertRaises(ValueError): check(self.write({**good, **change}))
        # A runtime's libraries only come with a runtime.
        without = {k: v for k, v in good.items() if k != 'runtime'}
        with self.assertRaises(ValueError): check(self.write(without))
        without = {k: v for k, v in good.items() if k not in ('runtime', 'libraries')}
        with self.assertRaises(ValueError): check(self.write(without))

    def test_steam_cloud(self):
        # Steam Cloud saves the launcher keeps in step: data only, the folder inside Documents.
        cloud = {'appID': 3405340, 'remoteDirectory': '%WinAppDataLocalLow%Dev/Game/${SteamID}/',
                 'localDirectory': 'G/prefix/saves', 'fileNames': ['a.json', 'b.json'], 'uploadsEnabled': True, 'required': True}
        good = {'id': 'g', 'name': 'G', 'workingDirectory': 'G/game', 'runtime': 'G/Runtime', 'executable': 'bin/run',
                'steamCloud': cloud}
        check(self.write(good))
        check(self.write({**good, 'steamCloud': {k: v for k, v in cloud.items() if k not in ('uploadsEnabled', 'required')}}))
        for change in ({'appID': 0}, {'appID': 2 ** 32}, {'appID': '1'}, {'appID': True}, {'appID': 1.5},
                       {'remoteDirectory': ''}, {'remoteDirectory': 1}, {'localDirectory': '/G'}, {'localDirectory': '../G'},
                       {'localDirectory': 'G//saves'}, {'fileNames': []}, {'fileNames': 'a.json'}, {'fileNames': ['a.json', 'a.json']},
                       {'fileNames': ['d/a.json']}, {'fileNames': ['..']}, {'fileNames': [1]}, {'fileNames': [f'{i}' for i in range(65)]},
                       {'uploadsEnabled': 1}, {'required': 'yes'}, {'password': 'x'}):
            with self.assertRaises(ValueError, msg=repr(change)): check(self.write({**good, 'steamCloud': {**cloud, **change}}))
        for missing in ('appID', 'remoteDirectory', 'localDirectory', 'fileNames'):
            with self.assertRaises(ValueError, msg=missing):
                check(self.write({**good, 'steamCloud': {k: v for k, v in cloud.items() if k != missing}}))
        with self.assertRaises(ValueError): check(self.write({**good, 'steamCloud': []}))

    def test_download(self):
        # What the launcher's experimental downloader fetches: data only, inside Documents.
        block = {'service': 'blizzard', 'product': 'gamep',
                 'regions': [{'id': 'eu', 'name': 'Europe', 'portal': 'EU'}], 'locales': ['enUS'], 'tags': ['OSX', 'arm64'],
                 'folder': 'G.app', 'root': 'G',
                 'settings': {'file': 'WTF/Config.wtf', 'region': 'portal', 'text': 'textLocale', 'audio': 'audioLocale'}}
        good = {'id': 'g', 'name': 'G', 'workingDirectory': 'G/_flavor_', 'executable': 'G.app/Contents/MacOS/G', 'download': block}
        check(self.write(good))
        check(self.write({**good, 'download': {k: v for k, v in block.items() if k != 'settings'}}))
        check(self.write({**good, 'workingDirectory': 'G'}))
        # Updates in the library: an opt-in, true only.
        check(self.write({**good, 'download': {**block, 'update': True}}))
        for change in ({'update': False}, {'update': 1}, {'update': 'yes'}, {'service': 'other'}, {'product': '../x'}, {'product': 1}, {'regions': []},
                       {'regions': [{'id': 'EU', 'name': 'E', 'portal': 'EU'}]}, {'regions': [{'id': 'eu', 'name': 'E'}]},
                       {'regions': [{'id': 'eu', 'name': 'E', 'portal': 'EU', 'host': 'x'}]}, {'locales': ['english']}, {'locales': []},
                       {'tags': []}, {'tags': ['a b']}, {'folder': '../G.app'}, {'folder': 'a/b'}, {'root': '/G'}, {'root': 'Other'},
                       {'root': 'G/..'}, {'settings': {**block['settings'], 'file': '../Config.wtf'}},
                       {'settings': {**block['settings'], 'region': 'por tal'}}, {'settings': {'file': 'c'}}, {'script': 'run.sh'}):
            with self.assertRaises(ValueError, msg=repr(change)): check(self.write({**good, 'download': {**block, **change}}))
        for missing in ('service', 'product', 'regions', 'locales', 'tags', 'folder', 'root'):
            with self.assertRaises(ValueError, msg=missing):
                check(self.write({**good, 'download': {k: v for k, v in block.items() if k != missing}}))
        with self.assertRaises(ValueError): check(self.write({**good, 'download': []}))
        # Not for a compatibility runtime's profile.
        with self.assertRaises(ValueError): check(self.write({**good, 'runtime': 'G/Runtime'}))

    def test_download_steam(self):
        # The Windows Steam client and the runtime it runs in: exactly these keys, inside Documents.
        archive = {'url': 'https://releases.example/tolkara-windows-runtime-1.zip', 'sha256': 'ab' * 32, 'size': 400000000}
        block = {'service': 'steam', 'root': 'Steam', 'runtime': archive, 'client': 'steam_client_win64'}
        good = {'id': 's', 'name': 'S', 'workingDirectory': 'Steam/prefix/drive_c/Program Files (x86)/Steam', 'runtime': 'Steam/Wine',
                'executable': 'lib/wine/aarch64-unix/wine', 'download': block}
        check(self.write(good))
        check(self.write({**good, 'download': {**block, 'runtime': {**archive, 'size': 1 << 32, 'url': 'https://e.example/' + 'a' * 494}}}))
        for change in ({'root': '/Steam'}, {'root': 'Steam/..'}, {'root': 'Other'}, {'root': 1}, {'client': 'steam_client_'},
                       {'client': 'steam_client_../x'}, {'client': 'steam_cmd_win64'}, {'client': 'steam_client_WIN64'}, {'client': 7},
                       {'script': 'run.sh'}, {'product': 'steam'}, {'runtime': archive['url']},
                       {'runtime': {**archive, 'url': 'http://releases.example/r.zip'}}, {'runtime': {**archive, 'url': 'https://'}},
                       {'runtime': {**archive, 'url': 'https://releases.example/r .zip'}}, {'runtime': {**archive, 'url': 7}},
                       {'runtime': {**archive, 'url': 'https://e.example/' + 'a' * 495}},
                       {'runtime': {**archive, 'sha256': 'abc'}}, {'runtime': {**archive, 'sha256': 'AB' * 32}}, {'runtime': {**archive, 'sha256': 5}},
                       {'runtime': {**archive, 'size': 0}}, {'runtime': {**archive, 'size': -5}}, {'runtime': {**archive, 'size': 1.5}},
                       {'runtime': {**archive, 'size': True}}, {'runtime': {**archive, 'size': '12'}}, {'runtime': {**archive, 'size': (1 << 32) + 1}},
                       {'runtime': {**archive, 'mirror': 'https://other.example/r.zip'}}, {'runtime': {'url': archive['url'], 'sha256': archive['sha256']}}):
            with self.assertRaises(ValueError, msg=repr(change)): check(self.write({**good, 'download': {**block, **change}}))
        for missing in ('root', 'runtime', 'client'):
            with self.assertRaises(ValueError, msg=missing):
                check(self.write({**good, 'download': {k: v for k, v in block.items() if k != missing}}))
        # Only for a compatibility runtime's profile, with the runtime and the working directory inside the top folder.
        with self.assertRaises(ValueError): check(self.write({k: v for k, v in good.items() if k != 'runtime'}))
        for change in ({'runtime': 'Wine'}, {'runtime': 'Steam'}, {'runtime': 'Steam\\Wine'}, {'workingDirectory': 'Steam'}, {'workingDirectory': 'Other/Steam'}):
            with self.assertRaises(ValueError, msg=repr(change)): check(self.write({**good, **change}))

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

    def test_setup_first_run(self):
        # The settings file the game's first start on the Mac writes, and the keys it must hold.
        good = {'id': 'a', 'name': 'A', 'workingDirectory': 'Games/A', 'executable': 'A.app/Contents/MacOS/A'}
        first_run = {'settings': 'A/WTF/Config.wtf', 'keys': ['portal', 'textLocale'], 'steps': ['Start **A** once.']}
        check(self.write({**good, 'setup': {'firstRun': first_run}}))
        check(self.write({**good, 'setup': {'firstRun': {'settings': 'Config.wtf', 'keys': ['portal']}}}))
        for change in ({'settings': '/Applications/A/Config.wtf'}, {'settings': '../Config.wtf'}, {'settings': ''},
                       {'keys': []}, {'keys': 'portal'}, {'keys': ['por tal']}, {'keys': ['portal"']}, {'keys': [1]},
                       {'keys': [f'k{i}' for i in range(17)]}, {'steps': 'Start'}, {'steps': ['']}, {'steps': ['x'] * 17},
                       {'run': 'x'}):
            with self.assertRaises(ValueError, msg=repr(change)): check(self.write({**good, 'setup': {'firstRun': {**first_run, **change}}}))
        with self.assertRaises(ValueError): check(self.write({**good, 'setup': {'firstRun': {'keys': ['portal']}}}))
        with self.assertRaises(ValueError): check(self.write({**good, 'setup': {'firstRun': {'settings': 'Config.wtf'}}}))
        # Both WoW clients name their own Config.wtf.
        for name, folder in (('wow-classic-era', '_classic_era_'), ('wow-forever', '_forever_')):
            block = check(ROOT / 'profiles' / name / 'profile.json')['setup']['firstRun']
            self.assertEqual(block['settings'], f'{folder}/WTF/Config.wtf')
            self.assertEqual(block['keys'], ['portal', 'textLocale', 'audioLocale'])


class FirstRunTests(unittest.TestCase):
    """tools/first_run.py: the WoW copiers carry the region and languages the game saved on the Mac."""
    KEYS = ['portal', 'textLocale', 'audioLocale']
    CONFIGURED = 'SET accountName "someone@example.com"\nSET portal "eu"\nSET textLocale "deDE"\nSET audioLocale "deDE"\nSET gxApi "metal"\n'

    def setUp(self):
        import first_run
        self.first_run = first_run
        self.folder = Path(tempfile.mkdtemp()); self.addCleanup(__import__('shutil').rmtree, self.folder)

    def game(self, config):
        """A fixture 'World of Warcraft' folder whose Classic Era client has this Config.wtf (None: never started)."""
        source = self.folder / 'World of Warcraft'
        (source / '_classic_era_' / 'WTF').mkdir(parents=True, exist_ok=True)
        if config is not None: (source / '_classic_era_/WTF/Config.wtf').write_text(config)
        return source

    def test_saved(self):
        values = self.first_run.saved(self.CONFIGURED, self.KEYS)
        self.assertEqual(values, {'portal': 'eu', 'textLocale': 'deDE', 'audioLocale': 'deDE'})
        self.assertEqual(self.first_run.missing(values, self.KEYS), [])
        # Only plain values of the named keys: never the account name, never an empty or odd value.
        partial = self.first_run.saved('SET portal ""\nSET textLocale "enUS"\nSET audioLocale "en US"\n# SET portal "us"\n', self.KEYS)
        self.assertEqual(partial, {'textLocale': 'enUS'})
        self.assertEqual(self.first_run.missing(partial, self.KEYS), ['portal', 'audioLocale'])
        self.assertEqual(self.first_run.read(self.folder / 'missing.wtf', self.KEYS), {})

    def test_merge_keeps_the_devices_other_settings(self):
        device = 'SET graphicsQuality "2"\nSET portal "us"\nSET RenderScale "0.5"\nSET portal "kr"\n'
        merged = self.first_run.merge(device, {'portal': 'eu', 'textLocale': 'deDE'})
        self.assertEqual(merged, 'SET graphicsQuality "2"\nSET portal "eu"\nSET RenderScale "0.5"\nSET textLocale "deDE"\n')
        self.assertEqual(self.first_run.merge('', {'portal': 'eu'}), 'SET portal "eu"\n')

    def stage(self, source, device=''):
        stage = self.folder / 'stage'
        original = self.first_run.device_text
        self.first_run.device_text = lambda *_: device
        try: self.first_run.stage(source, stage, 'World of Warcraft', ROOT / 'profiles' / 'wow-classic-era', 'DEVICE', 'bundle')
        finally: self.first_run.device_text = original
        return stage / '_classic_era_/WTF/Config.wtf'

    def test_stage_configured(self):
        staged = self.stage(self.game(self.CONFIGURED), device='SET graphicsQuality "2"\nSET portal "us"\n')
        self.assertEqual(staged.read_text(), 'SET graphicsQuality "2"\nSET portal "eu"\nSET textLocale "deDE"\nSET audioLocale "deDE"\n')
        self.assertNotIn('accountName', staged.read_text())

    def test_stage_never_started(self):
        # The tutorial case: Battle.net installed the game, nobody started it on the Mac.
        for config in (None, 'SET gxApi "metal"\n'):
            with self.assertRaises(SystemExit) as raised: self.stage(self.game(config))
            self.assertIn('has not been started on this Mac', str(raised.exception.code))
            self.assertIn('Click Play', str(raised.exception.code))
            self.assertFalse((self.folder / 'stage/_classic_era_/WTF/Config.wtf').exists())

    def test_stage_keeps_what_the_device_has(self):
        # Copied before, the Mac's WTF folder since cleared: the device keeps its own; nothing stale is staged.
        stale = self.folder / 'stage/_classic_era_/WTF/Config.wtf'
        stale.parent.mkdir(parents=True); stale.write_text('SET portal "us"\n')
        self.assertFalse(self.stage(self.game(None), device=self.CONFIGURED).exists())

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

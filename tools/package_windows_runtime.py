#!/usr/bin/env python3
"""Pack the Windows runtime a device downloads (profiles/README.md, "steam").

    package_windows_runtime.py --runtime <Wine install> --prefix <Wine prefix>
        [--overlay <folder>] --output tolkara-windows-runtime-<n>.zip

The archive holds Wine/ (what a device needs of a Wine install built with
tools/build_windows_runtime.sh: the Unix libraries, the Windows DLLs, share/
and the libraries GnuTLS and FreeType need) and prefix/ (a Windows prefix
that Wine made on this Mac and no program was installed in; its volatile.reg
goes along, because it holds the processor description FEX reads and
wineboot never runs on a device to write it again). --overlay is
laid over the Wine install first (files rebuilt since the install).

The prefix is made anonymous and portable: no user folder, no program's
registry keys, this Mac's name and user replaced, the Mac's own fonts
dropped, Wine's Tahoma registered and standing in for Arial and Segoe UI. Files the prefix repeats from the
runtime are not stored twice: tolkara-links.txt names them and the device
copies them after unpacking. Binaries built under the user's home folder carry its
path; the user's name in it is overwritten with underscores of the same
length. The result is refused if this Mac's user or host name is still in it.

It prints the archive's size and SHA-256 for the profile's download block.
Only our own builds of open-source software go in; nothing of Steam does.
"""
import argparse
import getpass
import hashlib
import re
import socket
import stat
import sys
import zipfile
from pathlib import Path

UNIX = 'lib/wine/aarch64-unix'
WINDOWS = ('lib/wine/aarch64-windows', 'lib/wine/i386-windows')
# GnuTLS for bcrypt, crypt32 and schannel with what it links, and FreeType.
LIBRARIES = {'libgnutls.30.dylib', 'libnettle.9.dylib', 'libhogweed.7.dylib', 'libgmp.10.dylib',
             'libidn2.0.dylib', 'libunistring.5.dylib', 'libtasn1.6.dylib', 'libp11-kit.0.dylib',
             'libintl.8.dylib', 'libfreetype.6.dylib', 'libpng16.16.dylib'}
DEVICE_USER = 'mobile'
FONTS = {'tahoma.ttf': 'Tahoma (TrueType)', 'tahomabd.ttf': 'Tahoma Bold (TrueType)'}
FONT_KEYS = {'system.reg': ('Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Fonts',
                            'Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion\\\\Fonts'),
             'user.reg': ('Software\\\\Wine\\\\Fonts\\\\External Fonts',)}
REPLACED = ('Arial', 'Microsoft Sans Serif', 'sans', 'Segoe UI')
# Registry keys of programs that were run in the prefix.
PROGRAM_KEYS = re.compile(r'\\\\(Valve|Wow6432Node\\\\Valve)(\\\\|$)', re.I)
EPOCH = (2026, 1, 1, 0, 0, 0)


def runtime_wanted(relative):
    parts = relative.parts
    if relative.suffix == '.a' or relative.name == '.DS_Store': return False
    if parts[0] == 'share': return True
    if parts[0] == 'bin': return relative.name == 'wineserver.so'
    if len(parts) > 3 and '/'.join(parts[:3]) in (UNIX,) + WINDOWS: return True
    return len(parts) == 2 and parts[0] == 'lib' and relative.name in LIBRARIES


def prefix_wanted(relative):
    parts = relative.parts
    if relative.name == '.DS_Store' or parts[0] in ('dosdevices', '.wineserver', '.update-timestamp'): return False
    if parts[0] != 'drive_c': return len(parts) == 1 and relative.suffix == '.reg'
    if len(parts) == 1: return True
    if parts[1] == 'users': return len(parts) == 2 or parts[2] == 'Public'
    if parts[1] in ('Program Files', 'Program Files (x86)'):
        return len(parts) == 2 or parts[2] in ('Common Files', 'Internet Explorer', 'Windows Media Player', 'Windows NT')
    return parts[1] in ('windows', 'ProgramData')


def portable_registry(name, text, user, host):
    """Without programs' keys, this Mac's fonts, name and user."""
    out, key, skip = [], None, False
    for line in text.splitlines(True):
        if line.startswith('['):
            key = line[1:line.index(']')]
            skip = bool(PROGRAM_KEYS.search('\\\\' + key))
        if skip: continue
        if key in FONT_KEYS.get(name, ()) and re.match(r'"[^"]*"="Z:\\\\(System|Library|Users|Applications)', line): continue
        if key in FONT_KEYS.get(name, ()) and any(line.startswith(f'"{value}"=') for value in FONTS.values()): continue
        out.append(line)
        if line.startswith('[') and name == 'system.reg' and key in FONT_KEYS['system.reg']:
            out += [f'"{value}"="{file}"\n' for file, value in FONTS.items()]
    text = ''.join(out)
    # The faces programs ask for by name are not on a device: Wine's Tahoma stands in.
    if name == 'user.reg' and '[Software\\\\Wine\\\\Fonts\\\\Replacements]' not in text:
        text = text.rstrip('\n') + '\n\n[Software\\\\Wine\\\\Fonts\\\\Replacements] 1767225600\n' + ''.join(f'"{face}"="Tahoma"\n' for face in REPLACED) + '\n'
    text = re.sub(r'(?i)(users\\\\)' + re.escape(user) + r'(?=\\\\|")', lambda m: m.group(1) + DEVICE_USER, text)
    text = re.sub(r'(?i)(?<![A-Za-z0-9])' + re.escape(host) + r'(?![A-Za-z0-9])', 'TOLKARA', text)
    text = re.sub(r'(?m)^("USERNAME"=").*(")$', lambda m: m.group(1) + DEVICE_USER + m.group(2), text)
    return text


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as file:
        for block in iter(lambda: file.read(1 << 20), b''): h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--overlay', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--user', default=getpass.getuser(), help='this Mac\'s user name, removed from the prefix')
    parser.add_argument('--host', default=socket.gethostname().split('.')[0], help='this Mac\'s name, removed from the prefix')
    options = parser.parse_args()

    # Wine/: the install, with the overlay's files over it.
    runtime = {}
    for root in filter(None, (options.runtime, options.overlay)):
        for path in sorted(root.rglob('*')):
            relative = path.relative_to(root)
            if path.is_file() and not path.is_symlink() and runtime_wanted(relative): runtime[relative.as_posix()] = path
    for needed in (f'{UNIX}/wine', f'{UNIX}/ntdll.so', 'bin/wineserver.so', 'share/wine/wine.inf', 'share/wine/fonts/tahoma.ttf'):
        if needed not in runtime: sys.exit(f'{options.runtime} has no {needed}')
    by_content = {}
    for name, path in runtime.items():
        if name.startswith(WINDOWS): by_content.setdefault((path.stat().st_size, digest(path)), name)

    # prefix/: folders, registry made portable, files the runtime already has as links.
    files, folders, links = {}, [], []
    for path in sorted(options.prefix.rglob('*')):
        relative = path.relative_to(options.prefix)
        if path.is_symlink() or not prefix_wanted(relative): continue
        name = 'prefix/' + relative.as_posix()
        if path.is_dir(): folders.append(name)
        elif relative.suffix == '.reg' and len(relative.parts) == 1:
            text = path.read_text(encoding='utf-8', errors='surrogateescape')
            files[name] = portable_registry(relative.name, text, options.user, options.host).encode('utf-8', errors='surrogateescape')
        else:
            same = by_content.get((path.stat().st_size, digest(path))) if path.stat().st_size else None
            if same: links.append((name, 'Wine/' + same))
            else: files[name] = path
    if 'prefix/system.reg' not in files: sys.exit(f'{options.prefix} is not a Wine prefix')
    for file in FONTS: files[f'prefix/drive_c/windows/Fonts/{file}'] = runtime[f'share/wine/fonts/{file}']
    # Wine never runs its own prefix update on the device (it starts other programs).
    files['prefix/.update-timestamp'] = b'disable\n'
    folders += [f'prefix/drive_c/users/{DEVICE_USER}', 'prefix/drive_c/windows/temp']
    links = [link for link in links if link[0] not in files]

    # This Mac's user or name must not be in what is published.
    secret = re.compile(rb'(?i)(/Users/|users\\\\?)' + re.escape(options.user.encode()) + rb'(?![A-Za-z0-9])|(?<![A-Za-z0-9])' +
                        re.escape(options.host.encode()) + rb'(?![A-Za-z0-9])')
    # Binaries built under the user's home folder carry its path (file names
    # in Wine's debug channels, the install's own folders, which a profile's
    # WINEDLLDIR and WINEDATADIR replace). The user's name in those paths
    # becomes underscores, the same length, so nothing in a file moves.
    home = b'/Users/' + options.user.encode()
    neutral = b'/Users/' + b'_' * len(options.user)
    renamed = 0
    def published(source):
        nonlocal renamed
        data = source if isinstance(source, bytes) else source.read_bytes()
        if not isinstance(source, bytes) and home in data:
            data = re.sub(re.escape(home) + rb'(?![A-Za-z0-9])', neutral, data)
            renamed += 1
        return data
    for name, source in list(files.items()) + [('Wine/' + key, path) for key, path in runtime.items()]:
        found = secret.search(published(source))
        if found: sys.exit(f'{name} still names this Mac or its user: {found.group(0)!r}')
    for name in list(files) + folders + [link[0] for link in links]:
        if re.search(r'(?i)(^|/)' + re.escape(options.user) + r'(/|$)', name): sys.exit(f'{name} is a user folder')

    entries = len(runtime) + len(files) + len(set(folders)) + 1
    if entries >= 65535: sys.exit(f'{entries} entries: too many for a plain ZIP')
    options.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(options.output, 'w', zipfile.ZIP_DEFLATED, allowZip64=False, compresslevel=9) as archive:
        def add(name, data, mode):
            info = zipfile.ZipInfo(name, EPOCH)
            info.create_system = 3
            info.external_attr = mode << 16
            info.compress_type = zipfile.ZIP_STORED if name.endswith('/') else zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
        for name, path in sorted(runtime.items()):
            executable = path.stat().st_mode & 0o111 or name.startswith(UNIX) or name.endswith(('.so', '.dylib'))
            add('Wine/' + name, published(path), stat.S_IFREG | (0o755 if executable else 0o644))
        for name in sorted(set(folders)): add(name + '/', b'', stat.S_IFDIR | 0o755)
        # system.reg marks the prefix as complete: the device unpacks it last.
        for name, source in sorted(files.items()):
            add(name, published(source), stat.S_IFREG | 0o644)
        add('tolkara-links.txt', ''.join(f'{a}\t{b}\n' for a, b in sorted(links)).encode(), stat.S_IFREG | 0o644)
    size = options.output.stat().st_size
    if size >= 1 << 32: sys.exit('the archive is 4 GiB or more')
    if renamed: print(f'the build folder\'s user name was overwritten in {renamed // 2} files')
    print(f'{options.output}: {len(runtime)} runtime files, {len(files)} prefix files, {len(links)} copies, {len(set(folders))} folders')
    print(f'"runtime": {{ "url": "https://…/{options.output.name}", "sha256": "{digest(options.output)}", "size": {size} }}')


if __name__ == '__main__':
    main()

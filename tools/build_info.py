"""Whether a Battle.net install is whole before it is copied to the device.

A game folder's `.build.info` lists each installed product with the version
Battle.net last finished installing; `<flavour>/.flavor.info` names the product
that folder holds. While an update is under way, or after one was interrupted,
the executable and that line disagree. A client started from such a copy cannot
use the build the file names and asks Blizzard's patch service instead, for a
product of its own choosing, whose data it then rejects at start-up (World of
Warcraft: "Invalid schema ... for Table StartupFiles"). Nothing here reads more
than those two files and the bundle's version.
"""
import plistlib
from pathlib import Path

UPDATE = ('Open Battle.net, let it finish updating the game, start the game once as far as the '
          'character list, quit both, then copy again.')


def product(flavor_text):
    """The product named by a .flavor.info: the line after its header."""
    lines = [line.strip() for line in flavor_text.splitlines() if line.strip()]
    return lines[1] if len(lines) > 1 and lines[0].startswith('Product Flavor') else None


def rows(build_info_text):
    """Each line of a .build.info as {column name: value}."""
    lines = [line for line in build_info_text.splitlines() if line.strip()]
    if not lines: return []
    names = [column.split('!')[0] for column in lines[0].split('|')]
    return [dict(zip(names, line.split('|'))) for line in lines[1:] if line.count('|') == len(names) - 1]


def problem(build_info_text, flavor_text, bundle_version):
    """Why this install should not be copied yet, or None when it is whole."""
    name = product(flavor_text)
    if not name: return 'The game folder does not say which product it holds (.flavor.info). ' + UPDATE
    found = [row for row in rows(build_info_text) if row.get('Product') == name]
    if not found: return f'Battle.net lists no installed product "{name}" for this folder (.build.info). ' + UPDATE
    if any(row.get('Active') == '1' and row.get('Version') == bundle_version for row in found): return None
    listed = ', '.join(f'{row.get("Version") or "no version"}{"" if row.get("Active") == "1" else " (not active)"}' for row in found)
    return (f'The game on this Mac is version {bundle_version or "unknown"}, but Battle.net last finished installing '
            f'{listed} of "{name}": an update is under way or was interrupted. ' + UPDATE)


def check(source, flavor_folder, info_plist):
    """problem() for the install at `source`; files that cannot be read count as not whole."""
    source = Path(source)
    def text(path):
        try: return (source / path).read_text(errors='replace')
        except OSError: return ''
    try: version = plistlib.loads((source / info_plist).read_bytes()).get('CFBundleVersion')
    except (OSError, ValueError): version = None
    return problem(text('.build.info'), text(Path(flavor_folder) / '.flavor.info'), version)

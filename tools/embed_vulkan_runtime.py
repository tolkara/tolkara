#!/usr/bin/env python3
"""Bundle a builder-supplied native MoltenVK backend, never its Mac binary."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess


def embed(source, platform, frameworks, mapping):
    source, frameworks, mapping = Path(source), Path(frameworks), Path(mapping)
    expected = {'ios': 'IOS', 'iossim': 'IOSSIMULATOR'}[platform]
    build = subprocess.check_output(['xcrun', 'vtool', '-arch', 'arm64',
                                     '-show-build', str(source)], text=True)
    if re.findall(r'^\s*platform\s+(\S+)', build, re.MULTILINE) != [expected]:
        raise ValueError(f'MoltenVK must be an arm64 {expected} library')
    exports = subprocess.check_output(['xcrun', 'nm', '-arch', 'arm64', '-gUj',
                                       str(source)], text=True).splitlines()
    for symbol in ('_vkGetInstanceProcAddr', '_vkCreateMetalSurfaceEXT'):
        if symbol not in exports:
            raise ValueError(f'MoltenVK is missing {symbol}')
    libraries = json.loads(mapping.read_text()) if mapping.exists() else None
    if libraries is not None and not isinstance(libraries, dict):
        raise ValueError('Guest library map must be an object')
    frameworks.mkdir(parents=True, exist_ok=True)
    target = frameworks / 'aklibMoltenVK.dylib'
    architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(source)],
                                             text=True).split()
    if architectures == ['arm64']:
        shutil.copyfile(source, target)
    else:
        subprocess.run(['xcrun', 'lipo', str(source), '-thin', 'arm64', '-output',
                        str(target)], check=True)
    target.chmod(0o755)
    subprocess.run(['xcrun', 'install_name_tool', '-id', '@rpath/aklibMoltenVK.dylib',
                    str(target)], check=True)
    if libraries is not None:
        libraries['@rpath/libMoltenVK.dylib'] = '@rpath/aklibMoltenVK.dylib'
        mapping.write_text(json.dumps(libraries, indent=2) + '\n')
    # Generic builds discover the adapter by name. Creating a map in one would
    # accidentally disable generic unresolved-import handling.
    print(f'Bundled native {platform} MoltenVK; app signing signs the backend.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('platform', choices=('ios', 'iossim'))
    parser.add_argument('frameworks')
    parser.add_argument('mapping')
    args = parser.parse_args()
    embed(args.source, args.platform, args.frameworks, args.mapping)

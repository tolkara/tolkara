#!/usr/bin/env python3
"""Copy your own installed WoW Forever files into the Tolkara app's Documents.

The executable and bundle resources are copied unchanged. Of the settings, only
the region and languages the game saved on this Mac are copied, never account
settings or credentials. devicectl skips unchanged files on subsequent runs.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import first_run
import localenv
BUNDLE_ID=localenv.bundle_id()


def sha256(path):
    digest=hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1024*1024),b''): digest.update(chunk)
    return digest.hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device',default=localenv.load().get('DEVICE'),help='iPad UDID (default: DEVICE in local.env)')
    parser.add_argument('--source',type=Path,default=Path('/Applications/World of Warcraft'))
    parser.add_argument('--skip-data',action='store_true')
    args=parser.parse_args()
    if not args.device: parser.error('set DEVICE in local.env or pass --device')
    os.chdir(localenv.ROOT)
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    source=args.source.resolve(); stage=Path('build/game-data/World of Warcraft')
    app=Path('_forever_/World of Warcraft.app/Contents')
    executable=app/'MacOS/World of Warcraft'
    if not (source/executable).is_file(): parser.error('original WoW Forever executable not found')
    if not args.skip_data and not (source/'Data').is_dir(): parser.error('game Data directory not found')
    # Region and languages saved by the game's first start on this Mac, merged
    # into the device's own settings (first_run.py); stops here when there are none.
    first_run.stage(source,stage,'World of Warcraft',Path(__file__).parent,args.device,BUNDLE_ID)
    (stage/app/'MacOS').mkdir(parents=True,exist_ok=True)
    for name in ['.build.info','.flavor.info']:
        for parent in [Path('.'),Path('_forever_')]:
            item=source/parent/name
            if item.is_file():
                (stage/parent).mkdir(parents=True,exist_ok=True); shutil.copy2(item,stage/parent/name)
    for name in ['Info.plist','PkgInfo']: shutil.copy2(source/app/name,stage/app/name)
    shutil.copytree(source/app/'Resources',stage/app/'Resources',dirs_exist_ok=True)
    before=sha256(source/executable)
    shutil.copy2(source/executable,stage/executable)
    if sha256(stage/executable)!=before or sha256(source/executable)!=before:
        raise RuntimeError('original executable changed while staging')
    # Files beside the executable, unchanged: WoW Forever keeps its ICU
    # data there (icudt78l.dat) and reports an error at every start without it.
    for item in sorted((source/executable).parent.iterdir()):
        if item.is_file() and item.name!=executable.name: shutil.copy2(item,stage/executable.parent/item.name)
    for name in ['Logs','WTF','Cache']: (stage/'_forever_'/name).mkdir(exist_ok=True)
    def transfer(path,destination):
        subprocess.run(['xcrun','devicectl','device','copy','to','--device',args.device,
            '--domain-type','appDataContainer','--domain-identifier',BUNDLE_ID,
            '--source',str(path),'--destination',destination],check=True)
    transfer(stage,'Documents/World of Warcraft')
    nibs=Path('build/guest-module/Nibs')
    if nibs.is_dir(): transfer(nibs,'Documents/GuestCompatibility/Nibs')
    if not args.skip_data: transfer(source/'Data','Documents/World of Warcraft/Data')
    print('Original executable SHA-256:',before)
    print('Copied bundle resources'+(' and game Data' if not args.skip_data else '')+' into the iPad app container.')

if __name__=='__main__': main()

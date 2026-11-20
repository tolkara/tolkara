#!/usr/bin/env python3
"""Validate an app profile (profiles/*.json). Profiles are data only."""
import json
import re
import sys
from pathlib import Path

REQUIRED = ('id', 'name', 'workingDirectory', 'executable')
OPTIONAL = ('notes', 'tested', 'caseAliases', 'runtime', 'arguments', 'environment', 'libraries', 'codePool', 'processes', 'setup', 'steamCloud', 'download')
ENVIRONMENT_NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
INSTALLER = re.compile(r'[A-Za-z0-9_-]+\.py')
# setup is read by the Tolkara Management app on the Mac (management/), never by
# the iPad launcher. Keep management/App/Core/Profile.swift in step with this.
SETUP = ('source', 'destination', 'installer', 'getApp', 'firstRun', 'risk')
GET_APP = ('name', 'url', 'path', 'steps')
FIRST_RUN = ('settings', 'keys', 'steps')
SETTING_KEY = re.compile(r'[A-Za-z0-9_]{1,64}')
RISK = ('summary', 'history', 'links')
# steamCloud is read by the iPad launcher (launcher/Cloud/SteamCloudCoordinator.m).
STEAM_CLOUD = ('appID', 'remoteDirectory', 'localDirectory', 'fileNames', 'uploadsEnabled', 'required')
# download is read by the iPad launcher (launcher/Download/GameDownload.m): keep
# +validConfiguration:workingDirectory:runtime: there in step with check_download.
DOWNLOAD = ('service', 'product', 'regions', 'locales', 'tags', 'folder', 'root', 'settings', 'update')
DOWNLOAD_SETTINGS = ('file', 'region', 'text', 'audio')
DOWNLOAD_STEAM = ('service', 'root', 'runtime', 'client')
DOWNLOAD_RUNTIME = ('url', 'sha256', 'size')


def relative(value):
    """A non-empty relative path without empty, '.' or '..' components, as the launcher requires."""
    return (isinstance(value, str) and value and not value.startswith('/') and
            all(part not in ('', '.', '..') for part in value.split('/')))


def check_case_aliases(aliases):
    """caseAliases: {alias: target}. The launcher links each alias, a path inside the working
    directory, to target, a name in the same folder that differs from the alias's last component
    only in case: iPadOS's file system is case-sensitive, macOS's default is not."""
    if not isinstance(aliases, dict): raise ValueError('caseAliases must be an object mapping alias to target')
    for alias, target in aliases.items():
        if not relative(alias): raise ValueError(f'caseAliases: {alias!r} must stay inside the working directory')
        leaf = alias.rsplit('/', 1)[-1]
        if not relative(target) or '/' in target or target == leaf or target.lower() != leaf.lower():
            raise ValueError(f'caseAliases: {alias!r} -> {target!r} must name {leaf!r} in another case')


def check_command_line(profile):
    """A compatibility runtime's command line (arguments, environment): plain strings, no code."""
    arguments = profile.get('arguments', [])
    if not isinstance(arguments, list) or len(arguments) > 64 or any(not isinstance(a, str) or len(a) > 4096 for a in arguments):
        raise ValueError('arguments must be a list of at most 64 strings')
    environment = profile.get('environment', {})
    if not isinstance(environment, dict) or len(environment) > 64: raise ValueError('environment must be an object of at most 64 variables')
    for name, value in environment.items():
        if not ENVIRONMENT_NAME.fullmatch(name) or len(name) > 256: raise ValueError(f'environment variable name {name!r} is invalid')
        if not isinstance(value, str) or len(value) > 4096: raise ValueError(f'environment variable {name} must be a string')


def text(value, name, limit=1000):
    if not isinstance(value, str) or not value or len(value) > limit: raise ValueError(f'{name} must be a non-empty string of at most {limit} characters')


def https(value, name):
    text(value, name, 2048)
    if not value.startswith('https://') or any(c.isspace() for c in value): raise ValueError(f'{name} must be an https URL')


def entries(value, name, keys):
    """A list of at most 16 objects with exactly these string keys."""
    if not isinstance(value, list) or len(value) > 16: raise ValueError(f'{name} must be a list of at most 16 entries')
    for entry in value:
        if not isinstance(entry, dict) or set(entry) != set(keys): raise ValueError(f'{name} entries need exactly: ' + ', '.join(keys))
        for key in keys: (https if key == 'url' else text)(entry[key], f'{name}.{key}')


def check_setup(profile):
    """setup: how the Mac app sets the application up. Plain data: where the user's own copy usually
    is on the Mac, which Documents folder it becomes, the profile folder's own copy helper, where to
    get the application, the settings its first start on the Mac must have saved, and the account
    risk to show before it is set up."""
    setup = profile['setup']
    if not isinstance(setup, dict): raise ValueError('setup must be an object')
    unknown = set(setup) - set(SETUP)
    if unknown: raise ValueError('setup: unknown keys: ' + ', '.join(sorted(unknown)))
    if 'runtime' in profile: raise ValueError('setup is not available for a profile with a runtime')
    if 'source' in setup:
        text(setup['source'], 'setup.source', 1024)
        if not setup['source'].startswith('/'): raise ValueError('setup.source must be an absolute path on the Mac')
    destination = setup.get('destination', profile['workingDirectory'].split('/')[0])
    if not relative(destination) or not (profile['workingDirectory'] + '/').startswith(destination + '/'):
        raise ValueError('setup.destination must be the working directory or a folder above it')
    if 'installer' in setup and (not isinstance(setup['installer'], str) or not INSTALLER.fullmatch(setup['installer'])):
        raise ValueError('setup.installer must name a Python script in the profile folder')
    if 'getApp' in setup:
        get_app = setup['getApp']
        if not isinstance(get_app, dict) or set(get_app) - set(GET_APP) or not {'name', 'url'} <= set(get_app):
            raise ValueError('setup.getApp needs name and url, optionally path and steps')
        text(get_app['name'], 'setup.getApp.name', 100); https(get_app['url'], 'setup.getApp.url')
        if 'path' in get_app:
            text(get_app['path'], 'setup.getApp.path', 1024)
            if not get_app['path'].startswith('/'): raise ValueError('setup.getApp.path must be an absolute path on the Mac')
        steps = get_app.get('steps', [])
        if not isinstance(steps, list) or len(steps) > 16: raise ValueError('setup.getApp.steps must be a list of at most 16 strings')
        for step in steps: text(step, 'setup.getApp.steps')
    if 'firstRun' in setup:
        # A settings file the application writes when it first starts on the Mac (WoW's
        # WTF/Config.wtf, in `SET key "value"` lines), relative to the source folder, and
        # the keys it must hold. Nothing runs: the Mac app only reads the file.
        first_run = setup['firstRun']
        if not isinstance(first_run, dict) or set(first_run) - set(FIRST_RUN) or not {'settings', 'keys'} <= set(first_run):
            raise ValueError('setup.firstRun needs settings and keys, optionally steps')
        if not relative(first_run['settings']) or len(first_run['settings']) > 1024:
            raise ValueError('setup.firstRun.settings must be a path inside the source folder')
        keys = first_run['keys']
        if not isinstance(keys, list) or not 1 <= len(keys) <= 16 or not all(isinstance(k, str) and SETTING_KEY.fullmatch(k) for k in keys):
            raise ValueError('setup.firstRun.keys must be a list of 1 to 16 setting names')
        steps = first_run.get('steps', [])
        if not isinstance(steps, list) or len(steps) > 16: raise ValueError('setup.firstRun.steps must be a list of at most 16 strings')
        for step in steps: text(step, 'setup.firstRun.steps')
    if 'risk' in setup:
        risk = setup['risk']
        if not isinstance(risk, dict) or set(risk) - set(RISK) or 'summary' not in risk:
            raise ValueError('setup.risk needs summary, optionally history and links')
        text(risk['summary'], 'setup.risk.summary', 2000)
        entries(risk.get('history', []), 'setup.risk.history', ('when', 'text'))
        entries(risk.get('links', []), 'setup.risk.links', ('title', 'url'))


def plain_relative(value):
    """A relative path of plain components: no '..', no leading '/', no backslash."""
    return (isinstance(value, str) and 0 < len(value) <= 512 and not value.startswith('/') and '\\' not in value
            and all(part not in ('', '.', '..') for part in value.split('/')))


def check_download(profile):
    """download: what the launcher's experimental downloader fetches from the publisher's own
    servers for a user with no Mac. Plain data, by service. "blizzard": the product, the regions
    and languages offered, which files of the publisher's file list make up the application, and
    where they go inside Documents. "steam": see check_download_steam."""
    block = profile['download']
    if not isinstance(block, dict): raise ValueError('download must be an object')
    if block.get('service') == 'steam': return check_download_steam(profile, block)
    unknown = set(block) - set(DOWNLOAD)
    if unknown: raise ValueError('download: unknown keys: ' + ', '.join(sorted(unknown)))
    if block.get('service') != 'blizzard': raise ValueError('download.service must be "blizzard" or "steam"')
    if 'runtime' in profile: raise ValueError('a "blizzard" download is not available for a profile with a runtime')
    if not isinstance(block.get('product'), str) or not re.fullmatch(r'[a-z0-9_]{1,32}', block['product']):
        raise ValueError('download.product must be a product name')
    regions = block.get('regions')
    if not isinstance(regions, list) or not 1 <= len(regions) <= 8: raise ValueError('download.regions must list 1 to 8 regions')
    for region in regions:
        if (not isinstance(region, dict) or set(region) != {'id', 'name', 'portal'}
                or not isinstance(region['id'], str) or not re.fullmatch(r'[a-z]{2}', region['id'])
                or not isinstance(region['portal'], str) or not re.fullmatch(r'[A-Z]{2,4}', region['portal'])
                or not isinstance(region['name'], str) or not 0 < len(region['name']) <= 40):
            raise ValueError('download.regions: each needs a two-letter id, a name and a portal')
    locales = block.get('locales')
    if (not isinstance(locales, list) or not 1 <= len(locales) <= 16
            or not all(isinstance(l, str) and re.fullmatch(r'[a-z]{2}[A-Z]{2}', l) for l in locales)):
        raise ValueError('download.locales must list 1 to 16 languages such as enUS')
    tags = block.get('tags')
    if (not isinstance(tags, list) or not 1 <= len(tags) <= 8
            or not all(isinstance(t, str) and re.fullmatch(r'[A-Za-z0-9_]{1,16}', t) for t in tags)):
        raise ValueError('download.tags must list 1 to 8 tags of the file list')
    if not plain_relative(block.get('folder')) or '/' in block['folder']:
        raise ValueError('download.folder must be one folder name of the file list')
    working = profile['workingDirectory']
    if not plain_relative(block.get('root')) or not (working == block['root'] or working.startswith(block['root'] + '/')):
        raise ValueError('download.root must be the working directory or a folder above it')
    if 'update' in block and block['update'] is not True:
        raise ValueError('download.update, when present, must be true')
    if 'settings' in block:
        file = block['settings']
        if (not isinstance(file, dict) or set(file) != set(DOWNLOAD_SETTINGS) or not plain_relative(file['file'])
                or not all(isinstance(file[k], str) and re.fullmatch(r'[A-Za-z]{1,32}', file[k]) for k in ('region', 'text', 'audio'))):
            raise ValueError('download.settings needs file (inside the working directory) and the region, text and audio setting names')


def check_download_steam(profile, block):
    """A "steam" download: the Windows Steam client from Valve's public update server, and before
    it the Windows runtime it runs in. Exactly: the top folder `root` in Documents, which holds
    the profile's runtime and working directory; `runtime`, the runtime archive's https address,
    SHA-256 and size; and `client`, the name of Valve's list of the client's files."""
    if set(block) != set(DOWNLOAD_STEAM): raise ValueError('a "steam" download needs exactly: ' + ', '.join(DOWNLOAD_STEAM))
    root = block['root']
    if not plain_relative(root): raise ValueError('download.root must be a folder in Documents')
    for key in ('runtime', 'workingDirectory'):
        if not plain_relative(profile.get(key)) or not profile[key].startswith(root + '/'):
            raise ValueError(f'a "steam" download needs the profile\'s {key} inside download.root')
    archive = block['runtime']
    if not isinstance(archive, dict) or set(archive) != set(DOWNLOAD_RUNTIME): raise ValueError('download.runtime needs exactly url, sha256 and size')
    url, size = archive['url'], archive['size']
    if (not isinstance(url, str) or len(url) > 512 or not re.fullmatch(r'https://[^/\s][^\s]*', url)):
        raise ValueError('download.runtime.url must be an https URL of at most 512 characters')
    if not isinstance(archive['sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', archive['sha256']):
        raise ValueError('download.runtime.sha256 must be 64 lowercase hexadecimal digits')
    if not isinstance(size, int) or isinstance(size, bool) or not 1 <= size <= 1 << 32:
        raise ValueError('download.runtime.size must be a number of bytes up to 4 GiB')
    if not isinstance(block['client'], str) or not re.fullmatch(r'steam_client_[a-z0-9_]{1,32}', block['client']):
        raise ValueError('download.client must name a Steam client list such as steam_client_win64')


def check_steam_cloud(profile):
    """steamCloud: the Steam Cloud saves the launcher keeps in step before each start, every
    minute while the application runs and after it exits. Data only: the Steam app ID, the
    files' Steam Cloud folder, the Documents folder that holds them, their names, whether
    local changes are uploaded, and whether the application may start without a signed-in
    Steam Cloud. The sign-in itself stays in the device's Keychain, never in a profile."""
    cloud = profile['steamCloud']
    if not isinstance(cloud, dict): raise ValueError('steamCloud must be an object')
    unknown = set(cloud) - set(STEAM_CLOUD)
    if unknown: raise ValueError('steamCloud: unknown keys: ' + ', '.join(sorted(unknown)))
    app_id = cloud.get('appID')
    if not isinstance(app_id, int) or isinstance(app_id, bool) or not 1 <= app_id <= 0xFFFFFFFF:
        raise ValueError('steamCloud.appID must be a Steam app ID')
    text(cloud.get('remoteDirectory'), 'steamCloud.remoteDirectory', 1024)
    if not relative(cloud.get('localDirectory')) or len(cloud['localDirectory']) > 1024:
        raise ValueError('steamCloud.localDirectory must stay inside Documents')
    names = cloud.get('fileNames')
    if (not isinstance(names, list) or not 1 <= len(names) <= 64 or len(set(map(str, names))) != len(names) or
            not all(isinstance(n, str) and relative(n) and '/' not in n and len(n) <= 255 for n in names)):
        raise ValueError('steamCloud.fileNames must be 1 to 64 distinct file names')
    for key in ('uploadsEnabled', 'required'):
        if key in cloud and not isinstance(cloud[key], bool): raise ValueError(f'steamCloud.{key} must be true or false')


def check(path):
    profile = json.loads(Path(path).read_text())
    if not isinstance(profile, dict): raise ValueError('profile must be a JSON object')
    unknown = set(profile) - set(REQUIRED) - set(OPTIONAL)
    if unknown: raise ValueError('unknown keys: ' + ', '.join(sorted(unknown)))
    for key in REQUIRED:
        if not isinstance(profile.get(key), str) or not profile[key]: raise ValueError(f'{key} must be a non-empty string')
    for key in ('workingDirectory', 'executable', 'runtime'):
        if key in profile and not relative(profile[key]): raise ValueError(f'{key} must stay inside Documents')
    if 'caseAliases' in profile: check_case_aliases(profile['caseAliases'])
    if 'libraries' in profile:
        # A runtime's libraries it opens by path: placed with it, inside its folder.
        libraries = profile['libraries']
        if 'runtime' not in profile: raise ValueError('libraries needs a runtime')
        if not isinstance(libraries, list) or len(libraries) > 64 or not all(relative(l) for l in libraries):
            raise ValueError('libraries must be a list of at most 64 paths inside the runtime')
    if 'codePool' in profile:
        # Prepared executable memory the runtime writes its own code into, in megabytes.
        size = profile['codePool']
        if 'runtime' not in profile: raise ValueError('codePool needs a runtime')
        if not isinstance(size, int) or isinstance(size, bool) or not 1 <= size <= 2048:
            raise ValueError('codePool must be a number of megabytes from 1 to 2048')
    if 'processes' in profile:
        # How many of the runtime's processes may run at once (docs/MULTIPROCESS.md).
        count = profile['processes']
        if 'runtime' not in profile: raise ValueError('processes needs a runtime')
        if not isinstance(count, int) or isinstance(count, bool) or not 1 <= count <= 8:
            raise ValueError('processes must be a whole number from 1 to 8')
    check_command_line(profile)
    if 'setup' in profile: check_setup(profile)
    if 'steamCloud' in profile: check_steam_cloud(profile)
    if 'download' in profile: check_download(profile)
    if 'installer' in profile.get('setup', {}) and not (Path(path).parent / profile['setup']['installer']).is_file():
        raise ValueError('setup.installer is not in the profile folder')
    return profile


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit('usage: check_profile.py PROFILE.json')
    try: print('profile ok:', check(sys.argv[1])['id'])
    except (OSError, ValueError) as error: sys.exit(f'{sys.argv[1]}: {error}')

#!/usr/bin/env python3
"""Validate an app profile (profiles/*.json). Profiles are data only."""
import json
import re
import sys
from pathlib import Path

REQUIRED = ('id', 'name', 'workingDirectory', 'executable')
OPTIONAL = ('notes', 'tested', 'caseAliases', 'runtime', 'arguments', 'environment', 'libraries', 'codePool', 'setup')
ENVIRONMENT_NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
INSTALLER = re.compile(r'[A-Za-z0-9_-]+\.py')
# setup is read by the Tolkara Management app on the Mac (management/), never by
# the iPad launcher. Keep management/App/Core/Profile.swift in step with this.
SETUP = ('source', 'destination', 'installer', 'getApp', 'risk')
GET_APP = ('name', 'url', 'path', 'steps')
RISK = ('summary', 'history', 'links')


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
    get the application, and the account risk to show before it is set up."""
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
    if 'risk' in setup:
        risk = setup['risk']
        if not isinstance(risk, dict) or set(risk) - set(RISK) or 'summary' not in risk:
            raise ValueError('setup.risk needs summary, optionally history and links')
        text(risk['summary'], 'setup.risk.summary', 2000)
        entries(risk.get('history', []), 'setup.risk.history', ('when', 'text'))
        entries(risk.get('links', []), 'setup.risk.links', ('title', 'url'))


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
        if not isinstance(size, int) or isinstance(size, bool) or not 1 <= size <= 1024:
            raise ValueError('codePool must be a number of megabytes from 1 to 1024')
    check_command_line(profile)
    if 'setup' in profile: check_setup(profile)
    if 'installer' in profile.get('setup', {}) and not (Path(path).parent / profile['setup']['installer']).is_file():
        raise ValueError('setup.installer is not in the profile folder')
    return profile


if __name__ == '__main__':
    if len(sys.argv) != 2: sys.exit('usage: check_profile.py PROFILE.json')
    try: print('profile ok:', check(sys.argv[1])['id'])
    except (OSError, ValueError) as error: sys.exit(f'{sys.argv[1]}: {error}')

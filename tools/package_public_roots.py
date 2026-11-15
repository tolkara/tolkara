#!/usr/bin/env python3
"""Package a public list of root certificates as CompatibilityRootCertificates.plist.

For a build that is not made on its user's Mac (the published .ipa): the
candidates the Security adapter offers an application come from Mozilla's
public list (translation/Security/PublicRoots/cacert.pem, from curl.se), not
from a Mac. As with a Mac's own list, the device's trust store decides: the
adapter hands on only the candidates iPadOS itself trusts.
usage: tools/package_public_roots.py cacert.pem output.plist
"""
import base64
import plistlib
import re
import sys

BLOCK = re.compile(r'-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', re.S)


def certificates(text):
    out = []
    for body in BLOCK.findall(text):
        der = base64.b64decode(''.join(body.split()), validate=True)
        # A DER certificate is one SEQUENCE; the adapter refuses anything larger than 64 KiB.
        if len(der) < 64 or len(der) > 65536 or der[0] != 0x30: raise ValueError('not a DER certificate')
        out.append(der)
    # The adapter's own limits: 1 to 1024 certificates.
    if not 1 <= len(out) <= 1024: raise ValueError(f'{len(out)} certificates: expected 1 to 1024')
    if len(set(out)) != len(out): raise ValueError('the list repeats a certificate')
    return out


def main():
    if len(sys.argv) != 3: sys.exit(__doc__)
    with open(sys.argv[1], encoding='utf-8') as source: found = certificates(source.read())
    with open(sys.argv[2], 'wb') as output: plistlib.dump(found, output, fmt=plistlib.FMT_BINARY)
    print(f'Packaged {len(found)} public certificates from {sys.argv[1]}')


if __name__ == '__main__':
    main()

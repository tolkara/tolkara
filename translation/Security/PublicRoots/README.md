# Public root certificates

`cacert.pem` is Mozilla's list of public certificate authorities' root
certificates, as the curl project extracts it
(https://curl.se/docs/caextract.html), unchanged. Licence: Mozilla Public
License 2.0, see the file's own header.

It is used only by builds made with `TOLKARA_SYSTEM_ROOTS=PUBLIC`, which is
how `.github/workflows/release.yml` builds the published `.ipa`:
`tools/package_public_roots.py` packages it as the candidates the Security
adapter offers an application that reads macOS's system root certificate
store. The adapter hands on only the candidates the device's own trust store
accepts (`translation/Security/Keychain.m`), so this file adds no trust of its
own. A build made on your own Mac uses that Mac's certificates instead.

This copy: certificate data from Mozilla as of 5 November 2026, 118
certificates, SHA-256
`427c064216761a1e72a8b30f0d954d08cb6e4435a82091fb865afd20c8497285` (matching
https://curl.se/ca/cacert.pem.sha256 on 2026-11-15). To update, replace the
file with the current one from curl.se, check it against the published
SHA-256, and change this paragraph.

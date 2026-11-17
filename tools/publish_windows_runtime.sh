#!/bin/bash
# Publish the Windows runtime a device downloads (profiles/README.md, "steam")
# as the GitHub release windows-runtime-<n>, and push main with the profile
# that names it.
# usage: tools/publish_windows_runtime.sh <n> [folder]     (default: build/release)
# The folder holds what tools/package_windows_runtime.py and the builds made:
#   tolkara-windows-runtime-<n>.zip   the archive
#   wine-changes.patch                our changes to Wine (LGPL: its source goes along)
#   fex-changes.patch                 our changes to FEX
#   runtime-<n>-notes.md              the release's description
# profiles/steam-windows/profile.json must already name this archive (URL,
# size and SHA-256) in a commit on main: that commit is what gets tagged.
# Order: the tag and the release first, then the archive is downloaded again
# from the profile's URL and compared, and only then main is pushed, so main
# on GitHub never names an archive that is not there.
# Needs gh signed in with write access; git pushes with gh's credentials.
# The release is not marked "latest" and its tag does not start with v, so
# .github/workflows/release.yml does not build an app for it.
set -euo pipefail
[ $# -ge 1 ] || { sed -n '2,5p' "$0"; exit 2; }
N=$1
cd "$(dirname "$0")/.."
FOLDER=${2:-build/release}
TAG=windows-runtime-$N
ZIP=$FOLDER/tolkara-$TAG.zip
NOTES=$FOLDER/runtime-$N-notes.md
PROFILE=profiles/steam-windows/profile.json
for file in "$ZIP" "$FOLDER/wine-changes.patch" "$FOLDER/fex-changes.patch" "$NOTES"; do
    [ -f "$file" ] || { echo "missing: $file"; exit 1; }
done
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
URL=https://github.com/$REPO/releases/download/$TAG/tolkara-$TAG.zip
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
SIZE=$(stat -f %z "$ZIP")

[ "$(git branch --show-current)" = main ] || { echo "not on main"; exit 1; }
git diff --quiet HEAD -- "$PROFILE" || { echo "$PROFILE has uncommitted changes"; exit 1; }
python3 - "$PROFILE" "$URL" "$SHA" "$SIZE" <<'EOF' || exit 1
import json, sys
path, url, sha, size = sys.argv[1:]
have = json.load(open(path))['download']['runtime']
want = {'url': url, 'sha256': sha, 'size': int(size)}
if have != want:
    sys.exit(f'{path} does not name this archive. Its "runtime" must be:\n  {json.dumps(want)}')
EOF
grep -q "$SHA" "$NOTES" || { echo "$NOTES does not state the archive's SHA-256 ($SHA)"; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "release $TAG exists already; a published archive is never replaced, use the next number"; exit 1; fi

push() { git -c credential.helper= -c credential.helper='!gh auth git-credential' push "https://github.com/$REPO.git" "$@"; }
git fetch -q "https://github.com/$REPO.git" main
git merge-base --is-ancestor FETCH_HEAD HEAD || { echo "main on GitHub has commits this checkout lacks; merge them first"; exit 1; }

git tag -f "$TAG" HEAD >/dev/null
push "refs/tags/$TAG"
gh release create "$TAG" --verify-tag --latest=false --title "Windows runtime $N" --notes-file "$NOTES" \
    "$ZIP" "$FOLDER/wine-changes.patch" "$FOLDER/fex-changes.patch"

# What a device will get, from the address the profile gives it.
CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
curl -fsSL --retry 3 -o "$CHECK/archive.zip" "$URL"
GOT=$(shasum -a 256 "$CHECK/archive.zip" | cut -d' ' -f1)
[ "$GOT" = "$SHA" ] || { echo "the published archive differs: $GOT, expected $SHA. main was not pushed."; exit 1; }

push HEAD:refs/heads/main
echo "published: $URL ($SIZE bytes, SHA-256 $SHA); main pushed"

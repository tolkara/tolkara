#!/bin/bash
# Put Tolkara's own source into the Tolkara Management app, which builds it on
# the user's Mac with the user's own team. Files git tracks, plus new files it
# does not ignore, as they are on disk: a release (a clean checkout of its tag)
# carries exactly the tag, and a development build carries what you are working
# on, so profiles you changed show up in the app. Ignored files (local.env,
# build output, logs) never go in.
# usage: tools/embed_management_source.sh RESOURCES_DIR
set -euo pipefail
OUT=$1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$OUT"
rm -f "$OUT/Tolkara-source.tar.gz" "$OUT/Tolkara-source.txt"
if ! git -C "$ROOT" rev-parse --verify -q HEAD > /dev/null; then
    echo "warning: not a git checkout; Tolkara Management will ask for a Tolkara folder."; exit 0
fi
cd "$ROOT"
LIST=$(mktemp "${TMPDIR:-/tmp}/tolkara-source.XXXXXX")
trap 'rm -f "$LIST"' EXIT
# Tracked files deleted on disk are left out; so is the agent folder (.claude/).
git ls-files -z --cached --others --exclude-standard -- . ':(exclude).claude' \
    | while IFS= read -r -d '' file; do [ -f "$file" ] && printf '%s\0' "$file"; done | sort -zu > "$LIST"
tar --null -T "$LIST" -czf "$OUT/Tolkara-source.tar.gz"
# Its identity follows the content, not the commit: the app unpacks a new copy,
# and asks for a new build, whenever the source changed.
IDENTITY=$(tr '\0' '\n' < "$LIST" | while IFS= read -r file; do printf '%s  ' "$file"; shasum -a 256 < "$file"; done | shasum -a 256 | cut -c1-40)
# Lines: commit, version, content identity.
{ git rev-parse HEAD; git describe --tags --always --dirty; echo "$IDENTITY"; } > "$OUT/Tolkara-source.txt"

#!/bin/bash
# Generate Tolkara.xcodeproj with the builder's own signing team and identifiers.
# Values come from the ignored local.env (see local.env.example); none are committed.
set -euo pipefail
cd "$(dirname "$0")/.."
. tools/localenv.sh; tolkara_load_env
export DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-}
export TOLKARA_BUNDLE_ID=${TOLKARA_BUNDLE_ID:-local.tolkara.app}
export TOLKARA_KEYCHAIN_GROUP=${TOLKARA_KEYCHAIN_GROUP:-local.tolkara.authorization}
# A second build (another bundle ID) shares the first one's App Group.
export TOLKARA_GROUP_BASE=${TOLKARA_GROUP_BASE:-$TOLKARA_BUNDLE_ID}
# Optional execution-mode preselection; empty means the app asks on first launch.
export TOLKARA_MODE=${TOLKARA_MODE:-}
case "$TOLKARA_MODE" in
    ""|developer-service|local-signing|external-jit) ;;
    *) echo "TOLKARA_MODE must be empty, developer-service, local-signing or external-jit (see local.env.example)." >&2; exit 2;;
esac
xcodegen generate -q "$@"

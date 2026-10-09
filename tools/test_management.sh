#!/bin/bash
# Build Tolkara Management (the Mac setup app in management/) and run its unit tests.
# usage: tools/test_management.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export TOLKARA_VERSION=${TOLKARA_VERSION:-0.0}
mkdir -p logs; LOG=logs/management-test-$(date +%Y%m%d-%H%M%S).log
xcodegen generate -q --spec management/project.yml
xcodebuild -project management/TolkaraManagement.xcodeproj -scheme TolkaraManagement -destination 'platform=macOS' \
    -derivedDataPath build/management-test SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
    test > "$LOG" 2>&1 \
    || { grep -E "error:|failed|Failing" "$LOG" | head -30; echo "TESTS FAILED -> $LOG"; exit 1; }
grep -E "Executed [0-9]+ tests" "$LOG" | tail -1

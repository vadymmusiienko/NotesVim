#!/bin/bash
# Runs the engine unit tests.
#
# With the Command Line Tools toolchain (no Xcode), Swift Build's per-file compiles sometimes
# miss the swift-testing macro plugin ("plugin for module 'TestingMacros' not found"), failing
# about one run in three. Passing the plugin directory explicitly makes the runs reliable.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swift)")")"
PLUGINS="$TOOLCHAIN/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi

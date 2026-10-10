#!/bin/bash
# Usage: scripts/test.sh [swift test args]
# Under the Command Line Tools, swift test finds the Swift Testing macro plugin only on some clean builds.
set -euo pipefail
cd "$(dirname "$0")/.."
plugins="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"

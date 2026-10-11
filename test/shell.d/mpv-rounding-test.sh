#!/bin/bash

set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command mpv
require_command python3
python3 "$ROOT/test/shell.d/fixtures/mpv/rounding.py"
pass "mpv follows live rounding, retains valid geometry, and respects fixed overrides"

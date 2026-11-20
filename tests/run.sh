#!/usr/bin/env bash
# Runs the bats tests, in parallel when GNU parallel is installed (bats needs it
# for --jobs). Every test works in its own BATS_TEST_TMPDIR, so they can run at
# once. Arguments go to bats; with none, it runs tests/unit and tests/integration.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ "$#" -gt 0 ] || set -- tests/unit tests/integration
if command -v parallel >/dev/null; then
    exec bats --jobs "$(nproc)" "$@"
fi
echo "GNU parallel isn't installed, so the tests run one at a time." >&2
exec bats "$@"

#!/bin/bash
# A test run that leaves the player alone: no window (ODYSSEY_HIDDEN), no sound (volume 0 in the test folder's
# odyssey.ini), its own data folder ($TEST_ROOT, default ../testroot: saves, settings, shader cache, extracted\ linked
# to the project's game files) and the build-test exe, so a game the user is playing from build/ is never locked,
# overwritten or saved over.
#   SECS=90 LOG=build/t.log ODYSSEY_INPUT=... tools/hidden_run.sh [extra args]
#   EXE=build-test2/OdysseyRecomp.exe: another build (default build-test)
# Build first with: make B=build-test -j16
# The game works in the data folder, so $TEST_ROOT/build is a link to this build/ (screenshots, pass dumps).
cd "$(dirname "$0")/.."
ROOT=${TEST_ROOT:-$(cd .. && pwd)/testroot}
mkdir -p "$ROOT"
[ -e "$ROOT/build" ] || cmd //c mklink /J "$(cygpath -w "$ROOT/build")" "$(cygpath -w "$(pwd)/build")" > /dev/null
[ -e "$ROOT/extracted" ] || cmd //c mklink /J "$(cygpath -w "$ROOT/extracted")" "$(cygpath -w "$(pwd)/extracted")" > /dev/null
export PATH="/c/msys64/ucrt64/bin:$PATH"
export ODYSSEY_HIDDEN=1 ODYSSEY_DATA_ROOT="$(cygpath -w "$ROOT")"
timeout "${SECS:-60}" "${EXE:-./build-test/OdysseyRecomp.exe}" "$@" > "${LOG:-build/test.log}" 2>&1
echo "exit $? log ${LOG:-build/test.log}"

#!/bin/bash
# A hidden run per kingdom: warp in, walk and turn the camera, then a table per kingdom from the fps lines.
#   tools/bench_kingdoms.sh <tag> [kingdom stage ...]     (logs: build/bench/<tag>_<stage>.log)
# Build first with: make B=build-test -j16. Extra environment (ODYSSEY_*) passes through to every run.
# The input: A presses through the warp's flight, then four rounds of walk / camera turn / walk / camera turn.
cd "$(dirname "$0")/.."
TAG=${1:-bench}; shift
STAGES=${*:-CapWorldHomeStage WaterfallWorldHomeStage SandWorldHomeStage LakeWorldHomeStage ForestWorldHomeStage CloudWorldHomeStage ClashWorldHomeStage CityWorldHomeStage SeaWorldHomeStage SnowWorldHomeStage LavaWorldHomeStage SkyWorldHomeStage MoonWorldHomeStage PeachWorldHomeStage}
mkdir -p build/bench
IN=""
for f in $(seq 700 300 9000); do IN="$IN$f:A:6,"; done
for s in 0 1 2 3 4 5; do
    b=$((2400 + s * 900))
    IN="$IN$b:STICK_UP:300,$((b + 300)):RSTICK_RIGHT:200,$((b + 500)):STICK_LEFT:200,$((b + 700)):RSTICK_LEFT:150,"
done
for st in $STAGES; do
    SECS=${SECS:-150} LOG=build/bench/${TAG}_$st.log ODYSSEY_NO_USER_INPUT=1 ODYSSEY_VK_PROF=1 \
        ODYSSEY_WARP=$st@1600 ODYSSEY_INPUT="$IN" tools/hidden_run.sh > /dev/null
done
tools/bench_table.sh "$TAG"

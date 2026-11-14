# Pipelines built ahead (update 52 / 0.2.4, 2026-11-14)

## Problem

Nearly every report on 0.2.2 / 0.2.3 (RecompLauncher's 60 reports, GitHub #3, #5, #10, #11) is about stutter: freezes
the first time something shows up, "frequent drops", "can't get a stable 60". Several more are about objects
flickering or missing and black flashes.

## Evidence

- Players' logs (32 attached to RecompLauncher reports, read through the developer hub): GPUs on AMD's legacy driver
  (RX 580 / 570 / 550, the 5700G's Vega 8, the 5500U) have no pipeline libraries, so the precompile does nothing there
  ("no pipeline libraries on this GPU: nothing to do"). Intel (Arc B580 / B390, Core 5 120U) has no pipeline binaries,
  and one Arc log shows 15,037 compiles and 3,913 links in play, with frames up to 168 ms. AMD's Z1 Extreme driver
  refuses every binary it made ("pipeline library (part 0x2) failed: -1"), so each one is compiled again.
- Our PC (RTX 4070 Ti), a hidden run per kingdom from an empty cache after the precompile (`tools/bench_kingdoms.sh
  cold`, 0.2.3): 400-650 programs compiled and 700-1,200 pipelines linked in two minutes of each kingdom, 5-21 frames
  over 50 ms, the slowest 250-550 ms, and 30-550 draws left out while their pipeline wasn't ready. Even with every
  shader cached (Cascade, `build/c24_base.log`), entering a place linked 458 pipelines in two seconds (a 184 ms frame).

## Cause

The precompile only covers the programs' shader libraries. A draw also needs a pipeline: the program plus the vertex
layout, blending and target formats it is drawn with. That pipeline is linked from four libraries on the render thread
the first time the draw is seen. The 3 ms link budget keeps one frame from taking all of them, so a draw over the budget
is left out for a frame: an object missing or flickering. GPUs without libraries build each pipeline whole at its first
draw, 20-200 ms of driver compile, and their draws are left out meanwhile.

## Fix

`runtime/nvn/vulkan/exec.c`, "pipelines built ahead":

- Every pipeline a draw makes is remembered (`cache/pipes.bin`): its program by its SPIR-V keys, plus the rest of its key.
  A list recorded in a run through every kingdom ships next to the program (`known_pipes.bin`: hashes and render state
  only, no game data).
- When a program's shaders are ready, its remembered pipelines are linked on a worker before its first draw: libraries
  on GPUs that have them, whole pipelines (low priority) on GPUs without. The draw finds its pipeline in `pre_tab`.
  A program set up ahead with remembered pipelines gets its libraries at once. Those include the effects the game sets up
  at boot, which used to wait for their first draw.
- GPUs without pipeline libraries: the preparation's process before the start builds every remembered pipeline whole
  into the pipeline cache (`prepare_whole_pipelines`). The game's own build then hits the driver's cache.
- A driver that refuses all its own binaries gets them switched off from the next start (`cache/pbin.off`, device.c).
- `ODYSSEY_PRELINK=0` turns it all off. The stats line shows `built ahead N (M used)`.

## Verified

Every kingdom, a hidden run from an empty cache after the precompile (`tools/bench_kingdoms.sh`, 4K internal, RTX 4070
Ti), 0.2.3 against 0.2.4 with the shipped list (`build/bench/cold_*`, `build/bench/ship_*`), totals of 13-14 kingdoms:

| | 0.2.3 | 0.2.4 |
|---|---|---|
| pipelines linked in play | 13,139 | 2,696 |
| draws left out (objects missing for a frame) | 3,160 | 1,841 |
| average fps | 59.1 | 59.2 |

Per kingdom: Sand 151 -> 2 draws left out, Sky 358 -> 12, Moon 138 -> 28, Peach 425 -> 60, Cap 94 (0.2.4 without the
list) -> 22. A GPU without libraries (`ODYSSEY_NO_GPL=1`): the 4,184 remembered pipelines built whole before the start
in 9.8 s; Sand then had 9 draws left out and 5 frames over 50 ms in two minutes.

## Not verified / left

- Frames over 50 ms didn't drop: they are the first frames of a scene (entering a kingdom, after a fall), where the
  GPU itself takes 150-350 ms (hundreds of full-screen copies, `fbcopy`), not shader work.
- Real AMD and Intel GPUs: only simulated here (`ODYSSEY_NO_GPL=1`, `ODYSSEY_NO_PBIN=1`).

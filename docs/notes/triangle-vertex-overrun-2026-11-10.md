# The mist "triangle": draws reading past their vertex buffer (2026-11-10, update 45)

## Problem

Over Cascade Kingdom's waterfall mist, a translucent screen-fixed wedge with hard edges: a vertical edge at the
screen's middle from the top down to the middle, two edges to the right side (the player's screenshots and video,
updates 40-44). Updates 41-44 fixed two real bugs that were not it (mirror-clamp sampling, render targets losing
their contents when the resolution changes).

## Evidence

- The player's F9 capture (update 43's tool): in the game's own frame and its in-between, so not the interpolation;
  not in the half-resolution mist buffer or the bloom; painted into the HDR scene after the mist pass.
- A debug frame with the vertex data (`ODYSSEY_DEBUG_DATA=1 ODYSSEY_DEBUG_VB_FLOATS=40`): the mist composite is
  `mode 4 count 9` (9 vertices, a triangle list) from a 36-byte buffer: 3 vertices, one full-screen triangle
  (-1 -1, 3 -1, -1 3).
- What vertices 4-9 read past the end (logged by the fix): (0 -1 -1) (0 3 -1) (0 -1 3) (0 0 1) (0 1 0)
  (0.981 0.195 1) - the start of a circle mesh that follows in memory. Triangle 2 has no area; triangle 3 is NDC
  (0, 0), (0, 1), (0.98, 0.2): the screen's middle, the top's middle, the right edge 40% down. Drawn over the
  player's F9 image, its edges lie on the wedge's edges exactly.
- `ODYSSEY_TEST_MIST_FILL=1` (the mist buffer cleared to half grey each frame) shows the composite's coverage
  anywhere: at the Cascade start point the wedge appears with `ODYSSEY_NO_DRAW_CLAMP=1`, and not without it.

## Cause

The Switch's GPU reads zeros for vertices past a vertex buffer's end, so the extra triangles have no area there.
Our backend binds vertex streams inside the guest heap with no end, so the GPU read on into the next buffer. Every
full-screen pass of the game draws 9 vertices from that 3-vertex buffer (six programs in a run through Cascade, the
Odyssey and two kingdoms, plus one 18-from-6 draw); the copies are invisible, the mist composite blends, so its
wedge got the mist twice.

## Fix

`exec.c` draw_: a non-indexed draw is cut to the vertices its per-vertex streams hold (size, stride, the attributes'
offsets), in whole triangles / lines. Logged once per program ("a draw of N vertices ... drawn M", with what the
cut vertices would have read). `ODYSSEY_NO_DRAW_CLAMP=1` draws them all (the old behaviour, for A/B tests).

## Verified

- The forced-visibility A/B above (same frame, same place): wedge without, none with.
- Cascade start, a walk to the waterfall, the Odyssey's flight cutscene, Sand and Forest warps: 60 fps, pictures
  intact; only the full-screen draws above are cut.
- Not seen by the player yet at their spot.

## Also in update 45: the start

- Play no longer stands still while shaders are prepared: the launcher keeps drawing, its Play tile reads
  "Starting..." with a bar (`launcher.mm`, `device.c` vk_prepare_begin / step / cancel). Closing the window stops
  the preparation; what it saved stays.
- The crash guard's marker is written when the game itself boots, counts early ends in a row
  ("odyssey-start <n>"), and sets the caches aside only at the second one in a row; an older build's empty marker is
  dropped without a wipe. Tested: an early end, then the next start keeps its caches.

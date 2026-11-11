# The "triangle" in Cascade's waterfall mist (2026-11-07, update 42)

## Problem

The player's recording (Cascade Kingdom, next to the waterfall mist, Chain Chomp nearby, 120 fps): a translucent shape
with hard straight edges over the mist. The same screen position in every frame while the camera moved: a vertical edge
at exactly the middle of the screen from the top down to the middle, and edges running off to the right - the upper
right quarter of the screen. The player: "it's on the screen, not the waterfall".

## Evidence

- The player's settings: `resolution = dynamic`, and the menu showed 1280 x 720 rendering: Dynamic at 0.5 of their
  2560 x 1440 display. An edge at exactly half the screen points at a size that changed by 2.
- Dynamic resolution reallocates every screen-sized render target when it steps (`textures.c` tex_backend: destroy,
  create). The new image's contents were undefined: whatever its memory held.
- Test hook added: `ODYSSEY_DYNRES_AT=<present>:<factor>` sets Dynamic's factor at that present. A hidden run at the
  Cascade start (`ODYSSEY_WARP=WaterfallWorldHomeStage@1600`, `ODYSSEY_DYNRES_AT=2300:0.5`, window 2560x1440) showed,
  100 frames after the drop, a tilted translucent box with hard edges around the HUD's Menu / Map. A run started at
  a fixed 50% (same final size, no reallocation) had no box.

## Cause

The game keeps content across frames in some screen-sized targets (layout pieces, effect buffers it blends over the
last frame's). After a reallocation those start from stale memory - fragments of other images, hence straight edges -
and stay until the game draws that area again.

## Fix

`textures.c` `rescale_contents`: when a scaled target is made again at another size (Dynamic stepping, the Internal
resolution changed in the menu, Smooth gradients toggled), the old image is blitted into the new one (every level and
layer; linear for filterable colour formats, nearest for depth), and the old image is freed after that submission.

Verified: the same run with the fix has no box (crop of the HUD before / after). Not verified: the player's exact spot
by the waterfall (scripted walks didn't reach it), so the triangle itself wasn't seen going away here.

Also in update 42: Internal resolution's 1x-4x are named 1080p / 4K / 6K / 8K (the ini still writes `2x`, and reads
`4k` etc. too); the player's setting is 4K, a fixed size, so no reallocation happens in play at all.

## Update 43: not the triangle

The player still saw the triangle at a fixed 4K (their log: no resolution change during play), so the reallocation bug
above was a different one. The recording frame by frame (60 fps of a 120 fps output): the triangle is in every frame,
its vertical edge fixed at the screen's middle, from the top edge down to the middle, while the camera moves - a
draw whose positions don't follow the camera (screen-fixed vertices near NDC (0, 1) and (0, 0)), not a world-space
effect. Not reproduced: scripted walks from the Cascade start didn't reach the spot (mist by the waterfall, a Chain
Chomp, a golden platform on a ledge).

F9 now also saves the frame's own image and its in-between (`build/frames/f9_<n>_real.png`, `_mid.png`; test:
`ODYSSEY_F9_AT=<frame>`), so one press at the triangle tells whether it is the interpolation's, and the pass dump
which draw.

## Update 44: the player's F9 capture

Frame 3099 (the player's machine, 2560x1440, scale 1.6): the triangle is in the game's own image and in its
in-between - not the interpolation. Pass dumps: not in the half-res mist buffer (pass 31, 1280x720), not in the bloom
chain (passes 34-56); present after the tonemap (pass 58: one full-screen draw reading the 1600x900 HDR scene
`...6859E0` and the 400x225 bloom). So it is in the HDR scene, painted by passes 32-33 (one 1152-vertex draw blending
the low-res mist in multiplicatively - blend ZERO / SRC_COLOR - then 14 particle draws: instanced 4-vertex strips and
96 / 240-vertex meshes, soft particles reading the linear depth `...686480`). The PNGs clamp the HDR values, so the
edge doesn't show in them.

F9 now records a second frame without pass images: after every draw into a screen-sized target, two texels at a
quarter of the height either side of the middle (x = w/2 -+ 8) are read back and logged when either changes
(`[probe2]`, with the programs). The draw that changes one side and not the other paints the edge.

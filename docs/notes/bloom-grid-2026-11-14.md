# Grid of dots around lights (update 52 / 0.2.4, 2026-11-14)

## Problem

GitHub #4 (4K, 3440x1440) and #11 (Arc B580, 1440p): bright lights (lamps, coins, hearts, embers) have faint copies of
themselves in a square grid around them, and the night sky has soft blotches.

## Evidence

Cap Kingdom from the Odyssey's landing, the lamps on the bridge (`ODYSSEY_SHOT_AT=2900`): at 4K internal the lamps'
halos are small and the sky is speckled with soft square blotches; at the game's own size (`ODYSSEY_NO_SCALE=1`) the
halos are round and the sky is clean. With the small targets left at the game's size and everything else at 4K
(`ODYSSEY_SCALE_MIN_W=401`) the picture is sharp and the halos and sky look as at the game's size
(`scratch/lamps_compare.png`).

## Cause

The glow is made in a chain of halves of the screen (400x225 down to 12x7), blurred with texel steps the game computes
for its own sizes. Scaled up with the rest, those steps skipped texels: a bright point came out as a sparse grid.

## Fix

`runtime/nvn/output_scale.c` `output_scale_texture`: screen-shaped targets narrower than 401 game pixels stay at the
game's size (`ODYSSEY_SCALE_MIN_W=<width>`, 0: as before). Cascade checked for anything else changing: no.

## Not verified

The players' own scenes (#4's coins and hearts, #11's fog sea).

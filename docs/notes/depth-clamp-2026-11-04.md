# Depth clamp was ignored

## Seen

Walking to Cap Kingdom's cliff edges and looking down (scripted walk, frames 3400-4440): the area below the cliff was pure
black, and the cloud sea ended in a straight horizontal line.

## Evidence

`nvnCommandBufferSetDepthClamp` was an empty stub. Logging it showed the game turning it on (1) and off (0) around draws
every frame.

## Fix

The call is recorded as `CMD_SET_DEPTH_CLAMP` (`runtime/nvn/cmdbuf.c`, `nvn.h`), kept in the draw state, and stored as bit 1
of the pipeline key's `poly_fill` (so the key memo and shader-prep records carry it). It enables
`depthClampEnable` when the device supports `depthClamp` (`g_vk.depth_clamp`).

## Verified

Same walk: the area below the edge is now dark grey rather than pure black, and the frame rate is unchanged against the run
without depth clamp (the dips in both runs come from the screenshot tool). The straight edge of the cloud sea is still
there, so this is not the whole cloud problem (see `cap-fog-2026-11-04.md`).

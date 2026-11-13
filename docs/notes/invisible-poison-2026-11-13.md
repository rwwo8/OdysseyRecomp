# Invisible poison goo in the Wooded Kingdom (2026-11-13)

## Problem

Players on RecompLauncher: at the Sky Garden in the Wooded Kingdom Mario is hurt again and again by purple goo nobody
can see, and the boss there can't be played ("on both builds": this port and the upstream one).

## Evidence

- The goo is a `PaintObj` (`ForestWorldHomePaintObj000`, two in the Scenario1_2 layer of ForestWorldHomeStage near
  (0, 1400, -11500); PaintObj also in CityWorldFactory, PackunPoisonExStage, LavaWorldHomeStage, SeaWorldLavaZone,
  Special1WorldTowerFireBlower, Theater2DEx).
- Ghidra: `PaintObj::draw` paints on the GPU (agl draw context) into linear textures, `drawBlurAndNormal` makes the
  textures at +0x7988 / +0x79a8 from them. `PaintObj::attackSensor` then reads the +0x79a8 texture **on the CPU**,
  straight from its memory (the vtable call that maps it, then `row[x * 4 + 3] >> 7`), counts poisoned texels around
  Mario and sends the poison message; `al::getColorFromLinearTexture` reads +0x7968 the same way.
  `drawLabelingAndVanish` writes texels on the CPU (where Cappy cleaned) and calls `agl::GPUMemAddrBase::flushCPUCache`.
- Those textures have NVN texture flag 0x40 (linear render target, `ODYSSEY_LOG_LINEAR=1`): 512x512, 372x372, 128x128
  and 19x19 RGBA8, stride 4096. The runtime only knew 0x10 as linear, and nothing ever brought what the GPU drew into
  them back to guest memory.
- `ODYSSEY_LRT_STATS=1` (texels with alpha >= 128 in guest memory, every 2 s), the same scripted run (title, flight to
  the Wooded Kingdom, warp to the pipe exit `EX_Water_Exit` near the goo):
  - before (`ODYSSEY_LINEAR_RT_SYNC=0`): the 512x512 ones 0 (never filled), the 128x128 ones 263 / 386 / 541 / 1038
    poisoned texels of stale memory the GPU never drew - poison where the picture shows none;
  - after: the 512x512 ones ~8200 (the goo that is drawn), the 128x128 ones 0.

## Cause

On the Switch the GPU draws into the same memory the CPU reads. Here it draws into a Vulkan image, so the game's
poison check read whatever its memory held before.

## Fix

`runtime/nvn/vulkan/textures.c` "Linear render targets": a submission that drew into a linear texture (flag 0x10 or
0x40) copies it into guest memory at its end (`vkCmdCopyImageToBuffer` into the imported heap, `vk_gmem_range`: no
wait, the CPU sees it once the submission is done, as on the Switch a frame later). A CPU flush of its memory
(`nvnMemoryPoolFlushMappedRange` -> `backend_pool_written`) uploads it again before its next use. Flag 0x40 counts as
linear for the storage size and uploads too (`objects.c is_linear`). It also covers the game's other GPU results the
CPU reads: ~200 1x1 occlusion targets and 256x128 R32 height maps. `ODYSSEY_LINEAR_RT_SYNC=0` turns it off.

## Status

- Verified with the counts above. Wooded Kingdom and Cascade (walk, camera turning): 60 fps, the same draw counts and
  the same stage changes with the sync on and off.
- Not verified: the boss fight at the top of the Sky Garden by hand, Cappy cleaning goo (the CPU-write path: no flush
  of a goo texture happened in the test runs), the other PaintObj stages.

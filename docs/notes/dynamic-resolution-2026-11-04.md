# Dynamic resolution dropped the 3D view to 800x450

## Seen

The whole 3D scene rendered into 800x450 targets in Cap Kingdom (debug frame 2700), then was upscaled to 1600x900: a soft,
blurry image, and half-resolution effects such as the fog.

## Evidence

- Pass dump at frame 2700: the scene and fog passes are 800x450.
- `LARECOMP_VK_COUNTER=frozen` (every counter of a frame reads the same time): the same frame renders at 1600x900.
- Counter trace, per frame: a TIMESTAMP_TOP (type 16) start and TIMESTAMP (type 0) ends 16 bytes apart in one ring buffer
  (`72677f3000`, +0x30 per frame), a second start/end pair in another buffer, and in gameplay many occlusion queries
  (type 1, samples passed) in between.
- Game code: `al::GraphicsQualityController::update` (7000a56758) adds a step count times a per-axis reduction to the base
  resolution (`al::GraphicsQualityInfo::applyReduceParam`, 7000a58340). The step logic at 7000a56f44 compares a measured
  time against thresholds.

## Cause

Only type 0 counters got GPU timestamps. Type 16 got the host clock at translation time, and the start/end pairing broke
across the interleaved second pair and the occlusion queries. The game measured our command translation as GPU time and
stepped the resolution down.

## Fix

`runtime/nvn/vulkan/exec.c` (`vk_counter_mode`): for SMO, every counter of a frame reads that frame's time (+1 tick per
counter, in order), so the game sees a fast GPU and keeps full resolution. `LARECOMP_VK_COUNTER=gpu` restores the
measured path.

## Verified

Same scripted run, frame 2700: 26 passes at 1600x900, none at 800x450, 60 fps in the fps lines.

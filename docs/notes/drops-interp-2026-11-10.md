# Drops with frame interpolation (2026-11-10, update 46)

## Problem

The player (RTX 4070 Ti, 2560x1440 165 Hz borderless, 1440p, interpolation on): "the game has drops". Their log:
steady-play windows at 52-55 fps with 66 ms frames, no shader compiling, each right after the interpolation's brake
("the game missed its vsync in 12 of its last 120 frames with in-betweens: paused for 120 / 240 / 480 frames").
Windows with the in-betweens paused were clean (60 fps, max 17 ms).

## Council

Five advisors, peer review, chairman (scratch: council_drops*.md). Agreed: the in-betweens cause it, the brake's
switching makes it worse, an in-between must never cost a game frame. Reviews added: a lock-wait log can't tell lock
contention from GPU saturation; the 18 ms rule vs 165 Hz (three refreshes = 18.18 ms); look at the switch itself.

## Evidence (hidden runs, same PC, Call of Duty running: GPU at 98-100% around them)

Same 110 s Cascade walk with camera turns:
- interpolation off: 60.0 fps, max 20-21 ms; on: 3 of 17 windows with frames over 30 ms (69, 83 ms), brake trips.
- `ODYSSEY_INTERP_LOG=2`: the game waited only 0.8-1.7 ms a frame for replays; replays finished 9-17 ms after the
  game's present was due - GPU time, not the render lock.

## Cause

1. The in-betweens' GPU work made the game's own frames late when the GPU had no room.
2. The brake then switched the game's images from the presenter (interpolation's) to a present of their own and back:
   each switch stalled the picture (the 66-83 ms frames).

## Fix (`vulkan/device.c`)

- Per frame: no in-between when the GPU hasn't finished what it was given for the frame before (its game work and
  its in-between: `vk_completed_seq() < prev_end`). The image goes alone, the GPU catches up.
- The brake no longer switches the present path: braked frames go through the presenter without an in-between
  (`IJob.rest`).
- The brake counts frames over 20 ms (18 ms caught three 165 Hz refreshes).
- `[interp-thread]` (ODYSSEY_INTERP_LOG=2) counts in-betweens left out for a GPU behind and braked ones.

## Verified

Same run with the fix: 0 of 13 windows over 30 ms, average 59.8 fps (interpolation off: 60.0). With the GPU shared
with another game most in-betweens were left out - correct, but it means the 120 fps look itself wasn't measured on a
free GPU. Not checked: a visible window on the 165 Hz display.

## Not changed

The first minute's hitches (pipelines compiled / linked on first sight): mostly programs the shader preparation hadn't
seen yet ("absent"), 16 binaries refused in one window. First-time only.

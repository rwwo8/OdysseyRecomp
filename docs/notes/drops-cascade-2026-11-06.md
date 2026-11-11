# Drops in Cascade Kingdom, Snapshot mode, Mario's face (update 39, 2026-11-06)

## Problem

The user, after the first kingdom: drops in the Broodals boss's cutscenes, when a pole was pulled and water came, a bad
one entering Waterfall Basin (Cascade Kingdom), frame rate falling while looking at the waterfall; and with frame
interpolation on (165 Hz, window), Mario's face dark brown in some images (their video, Top Hat Tower).

## Evidence

- Their log (`build/OdysseyRecomp.log`, 30 minutes): from t=1206 to 1218 the game at 30 fps with 33 ms frames and
  `[am] ISelfController cmd 19` once a frame (the game asks the screenshot orientation: Snapshot mode). Dynamic
  resolution took the image from 1.00 to 0.50 in five steps over 8 s, then raised it back over a minute in ten steps
  (t=1222 -> 1278); the hitches at t=1238 (121 ms) and t=1244 (102 ms) came with those raises, no shader built.
- A hidden run that presses the d-pad down in play (`ODYSSEY_INPUT=...2300:DOWN:6`): `[nvn] present interval 2 (the game
  at 30 fps)` with the same cmd 19 - Snapshot mode paces itself at 30.
- Entering Waterfall Basin (t=1665-1701): frames of 100-780 ms with `skipped` draws and `link` counts of 21-297 in a
  2 s window: the place's effects seen the first time, their pipelines linked from libraries on the render thread.
- The video: 4 of 24 consecutive frames with the face in the hair / moustache brown (frame interpolation's images).
- Not usable: the hidden runs at 2560x1440 in front of the falls gave 43 fps, but `nvidia-smi` showed the GPU at 99 %
  with another game running (SB-Win64-Shipping.exe), so those runs shared the GPU. At 1280x720 the same path ran at
  60 fps. `runtime/sprof.c` (below) showed the game thread waiting for the render thread (`rq_drain`) and that in
  `vkQueuePresentKHR`: a GPU-bound picture, the other game's load included.

## Cause and fix

1. Dynamic resolution took the game's own 30 fps for a slow GPU. `objects.c` records the game's present interval;
   `output_scale.c` leaves frames the game paces at 30 alone.
2. First-time links all happened in the frame that met them. `exec.c` gives links 3 ms a frame
   (`ODYSSEY_LINK_BUDGET_MS`); past that, draws that may be left out for a frame (`g_draw_relaxed`, as a draw whose
   program is still compiling) link on the next frame. Draws drawn once (tables, full-screen passes) still link at once.
3. The parts of one model (face, hair, moustache) share their per-object vertex blocks (one skeleton), so frame
   interpolation's matcher saw one object told apart only by draw order. `interp.c` now compares their fragment-stage
   materials: a pair whose materials differ is not taken by identity, and the content distance includes the material.
   Not reproduced here (a still Mario facing the camera with Cappy); a stats line counts the refusals.

## Also

- Video tab: "Frame limiter" (60 / 120 fps, 120 = frame interpolation) replaces "Fullscreen refresh rate" and the
  "Frame interpolation" toggle; "Brightness" and "Color saturation" (a grade pass, last before the window).
- `runtime/sprof.c`: `ODYSSEY_SPROF=<from>:<to>` samples every thread about once a millisecond (with the first caller
  in our code for a waiting thread) and writes `build/sprof.txt`.

## Not verified

The Snapshot fix on the user's settings (the test folder ran Match display); the link budget against a clean baseline
(the GPU was shared); the face fix (not reproduced).

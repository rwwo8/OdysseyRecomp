# Status (update 52, 2026-11-14)

Current state only. The investigations behind each item are in `docs/notes/`.

The project builds on MIT-licensed recompilation projects (LICENSE). The whole game has been played
through on it at 60 fps.

## Working (checked here)

- Boot, title, Cap Kingdom: a steady 60 fps in a hidden scripted walk with the camera turning (i7-13700KF). The only
  pauses are level loads (about 0.25-0.4 s). Since update 38 no 30 s spikes, and Dynamic resolution no longer changes
  after one stall (`notes/hitches-2026-11-06.md`).
- The game's button pictures follow the controller (Xbox, PlayStation; update 38, `runtime/nvn/glyphs.c`), and the
  Controls tab's Button layout makes A / Cross confirm on those controllers, in the game and the menus.
- Cap Kingdom's cloud sea fills the view below the cliff edges. On the old base that area was black and the sea came and
  went (`notes/cap-fog-2026-11-04.md`).
- Depth clamp as the game asks for it (ported: `notes/depth-clamp-2026-11-04.md`).
- The launcher (update 37): the game's logo, read from the player's files, over Play / Settings / Controls / Files;
  the game boots from Play at 60 fps (`notes/launcher-2026-11-05.md`). Not checked by hand with a controller yet.
- Fullscreen on 144 / 165 Hz displays switches to the display's 60 Hz mode, and fullscreen doesn't drop out when another
  window takes the focus (ported from the old base). Not checked here: hidden test runs are never fullscreen.
- Dynamic resolution steps and Internal resolution changes keep what the screen targets held (update 42): before, the
  new targets started with stale memory - hard-edged shapes (a box behind the HUD) until the game redrew those areas (`notes/triangle-dynres-2026-11-07.md`).
- The mist "triangle" over Cascade's waterfall is gone (update 45): full-screen draws read 9 vertices from 3-vertex
  buffers, and our streams had no end (`notes/triangle-vertex-overrun-2026-11-10.md`). Not yet confirmed by the
  player at their spot.
- Play keeps the launcher alive while shaders are prepared ("Starting..." on the Play tile), and one early end no
  longer throws the prepared shaders away (update 45).
- Frame interpolation no longer costs game frames: an in-between is left out when the GPU is still on the frame before,
  and the brake no longer switches the present path (its 66 ms frames gone; `notes/drops-interp-2026-11-10.md`,
  update 46). Measured with another game sharing the GPU; not on the player's visible 165 Hz window.

- The Wooded Kingdom's poison goo hurts only where it is drawn (update 49): the game reads GPU-drawn textures on the
  CPU, and they now reach its memory (`notes/invisible-poison-2026-11-13.md`). The boss fight itself not played by hand.

- Pipelines are built ahead of their first draw from this player's and a shipped list (update 52): in a run through
  every kingdom from an empty cache, links in play fell from 13,139 to 2,696 and draws left out from 3,160 to 1,841
  (`notes/pipelines-ahead-2026-11-14.md`). GPUs without pipeline libraries get them built whole before the start.
- Lights have round halos at high internal resolutions, no grid of dots (update 52, `notes/bloom-grid-2026-11-14.md`).
- Gyro, a Shake binding, two players (second controller), mouse camera past the stick's speed, in-app updates
  (Windows, tested: download, install, restart) - update 52. Gyro and two players not tried with real controllers.

## Known problems

| Problem | State |
| --- | --- |
| A stage or effect seen for the first time can hold the picture for a moment (shader builds) | Upstream known issue; cached afterwards |
| Only game version 1.0.0 | By design |
| The first frames of a new scene (entering a kingdom, after a fall) take 150-350 ms: GPU work, not shaders | Open |
| Linux build: needs a Linux environment (WSL2 / podman) | Open |
| Not re-checked on the new base: puddle colours, the flicker by Mario's eye on the title | Open |

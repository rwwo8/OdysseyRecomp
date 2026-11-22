# Status (update 55 / 0.2.6, 2026-11-16)

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

- The shader precompile reads every shader archive of the game (update 54): 19,876 programs before the first start
  (12,820 in 0.2.4), agl's own archives paired through the programs drawn before; pipelines from a run through all
  197 stages ship with the game (`notes/update-0.2.5-2026-11-15.md`).
- Map warps: with the map open, the mouse moves its cursor and left click warps (GitHub #16; controller and keyboard
  warps checked in hidden runs, a real mouse not).
- A crash inside the Vulkan driver switches that driver to whole pipelines from the next start (GitHub #14; not tried
  on the ROG Ally).
- Updates download by themselves in the launcher and install with one click, Windows and Linux (Linux not run here).

- Shaders (update 55): one packed cache (cache/shaders.pack), only drawn programs prepared at Play behind a loading
  screen: 20.7 s and 453 MB instead of 91 s and 3.1 GB, the same in play (`notes/update-0.2.6-2026-11-16.md`).
- Frame rate 120 / 180 / 240 / Match display (replayed frames, capped by the display); motion sensitivity, DSU motion,
  Joy-Con pair and death-screen fixes; 720p default on the Steam Deck. Not tried on a fast display, a Deck or real
  motion controllers.
- Our own shader core (in the code for 0.2.8, not released; `notes/shader-core-0.2.8-plan-2026-11-17.md`): blending,
  write masks and the vertex layout set per draw (NVIDIA, RADV): 20-65 % fewer links, about 35 % fewer whole pipelines
  without libraries, half the hitches on a first run. Opening cutscene images bit-identical to the old core, no
  validation messages from it. Every hitch logs its cause; cutscene starts are logged, with the cutscene atlas. Not
  tried on AMD or Intel GPUs.
- In-betweens replay the command lists their frame ran, not the ones at the same handle now (the game records its next
  frame there meanwhile): at 240 the 2nd and 3rd in-betweens had repeated the 1st, and half-recorded lists made objects
  flicker - the Odyssey's balloon (`notes/interp-replay-lists-2026-11-20.md`). `tools/test_watch.py` reports such
  stalls.
- 0.2.9 (released 2026-11-22; `notes/update-0.2.9-2026-11-22.md`): the game's own log reaches the launcher's reports (it
  was `prepare.log` in almost every one); an AMD driver out of memory for pipeline libraries falls back to whole
  pipelines, then and at its next starts (`cache/gpl.off`); the launcher no longer needs the game files after an update
  (`keeps_copy`); 540p; menu descriptions can be turned off. AMD side not tried on AMD.

## Known problems

| Problem | State |
| --- | --- |
| A stage or effect seen for the first time can hold the picture for a moment (shader builds) | Upstream known issue; cached afterwards |
| The first frame of a new scene (entering a kingdom, after a fall) takes 110-150 ms (GPU: a noise target in our pc-state-machine translation) | In the black loading screen, not seen; the 150-280 ms frames after it were the list table: fixed (`notes/scene-start-list-table-2026-11-20.md`) |
| Linux: built on Windows (tools/linux/cross_build.sh), never run on Linux here | Open |
| AMD Windows driver (RX 9070 XT, GitHub #31): stops itself in the 2nd kingdom; texture artifacts, choppy cutscenes (RX 7800 XT / 7600) | 0.2.9: fallback on its out-of-memory answers; the cause shows in the next log (the right log now reaches reports) |
| RTX 5060 Ti / 5070 (0.2.7): black screen, no cutscene sound; RTX 2080: short freezes, pause background missing | No game log yet; not reproduced here |
| Game update 1.4.0 not supported yet (1.0.0 only) | Planned |
| Not re-checked on the new base: puddle colours, the flicker by Mario's eye on the title | Open |

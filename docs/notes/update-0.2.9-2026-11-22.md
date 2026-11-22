# Update 0.2.9 (released 2026-11-22)

What the players' reports showed (GitHub issues, the RecompLauncher store's 47 "Has problems" and 6 "Won't run"
reports, read in the developer hub) and what was done about it. The order: the
log first (every other report is a guess without it), the AMD fallback that corrects itself instead of a vendor-wide
switch, the launcher's "game files again" step, then settings.

## The wrong log in almost every report

- **Problem:** nearly every store report and GitHub #31 (the RX 9070 XT crash) carry `cache/prepare.log` (the shader
  preparation's) instead of the game's own log. The game's fatal line was never in a report.
- **Cause:** `windows.c log_to_file_without_console` kept stderr as it was whenever it was a valid handle. Started by
  RecompLauncher it is a pipe the launcher reads, so `OdysseyRecomp.log` was never written, and the launcher, given
  `folders.logs = {install}` (the manifest can only name folders), attached the only log there. The fatal message box
  (it reads the log file) never showed either. On Linux the log went to `~/.local/share/odyssey-recomp` while a
  launcher install keeps its data in `{install}` since 0.2.5.
- **Fix:** a pipe on stderr is teed (`log_tee`): a thread copies our own pipe into `OdysseyRecomp.log` and the
  launcher's pipe. `plat_log_flush` (fatal notice, exit, `plat_terminate`) waits until nothing more is read for 150 ms
  (at most 2 s). The file stops at 512 MB. `ODYSSEY_NO_LOG_TEE=1`: as before. Linux: paths.c's rule (recomplauncher.json
  two folders up, no older data in the XDG folder) for the log too.
- **Mistakes on the way (both in the first test):** the launcher's pipe handle was used after `_dup2` had closed it, and
  the freed value was handed to our own pipe's write end: the thread wrote into its own pipe, a 20 GB log in seconds
  (now `DuplicateHandle` first, and the 512 MB cap). Then `PeekNamedPipe` on the read end waited behind the thread's
  `ReadFile` (synchronous I/O on one handle goes one at a time): the process hung after a fatal error until the freeze
  watchdog.
- **Verified:** `ODYSSEY_CRASH_AT=600` with stderr piped into `cat`: the pipe's copy and `OdysseyRecomp.log` are
  byte-identical (12,893 bytes) and end with the call chain and the mods line; the process ends at once. A run with
  stderr in a file (`tools/hidden_run.sh`) writes no `OdysseyRecomp.log`, as before. linux.c: a syntax check with zig for
  x86_64-linux (no Linux build or run).

## AMD's Windows driver and pipeline libraries (GitHub #31, store reports)

- **Evidence:** the RX 9070 XT (#31) and RX 7800 XT (Spanish report: texture artifacts, cutscenes lag and fail) logs:
  `pipeline library (part 0x2 / 0x4) failed: -1` (VK_ERROR_OUT_OF_HOST_MEMORY), the driver refusing its own pipeline
  binaries, the preparation process at 2.2-2.3 GB. #31 stopped itself ("after a serious error") minutes into the 2nd
  kingdom, twice. The game's fatal line is unknown (the wrong log, above).
- **Fix:** a refused library was already soft (its program builds whole pipelines). Now the first out-of-memory answer
  (`exec.c lib_oom`) stops libraries for the rest of the run and writes `cache/gpl.off` with the driver's tag
  (vendor, driver version); `device.c` reads it at the next start and goes without pipeline libraries, like old AMD
  drivers and `cache/driver.crash`. A new driver version tries again. Not a switch for every AMD GPU: AMD GPUs that work
  keep the fast path.
- **Verified (NVIDIA, the error faked):** `ODYSSEY_TEST_LIB_OOM=50`: the log line, `cache/gpl.off` = `4318 2604892160`,
  play on at 60 fps in the Cascade Kingdom (0 skipped draws once the whole pipelines were built). The next start:
  "ran out of memory for pipeline libraries before ... whole pipelines only", 60 fps. **Not verified on AMD.**
  Whether this was the crash's cause shows in the next AMD log, which now reaches the report.

## "Won't run": the game files asked for again after every update (GitHub #18, store reports)

- **Problem:** #18 (Portuguese): after each update the launcher asks for the game files again and refuses them, even
  the folder that worked. A German and an English "won't run" report say the same.
- **Fix:** the launcher's manifest has `prepare.keeps_copy`: our setup keeps the copy in `{install}/extracted`
  (`folders.game`), `done` lists `extracted/exefs/main` and `extracted/romfs.bin`, and the copy is one argument
  (`--game={game}`) so the launcher can leave it out and run the step again without a copy. `main.c`: `--setup` takes an
  optional folder and `--game=`; `setup.mm`: no copy given and none in the install gives a plain error.
- **Verified:** `--setup` without a copy on a set-up test folder: "Ready to play", exit 0; on an empty folder: the
  error, exit 2; the old form `--setup <folder>`: unchanged. **Not verified:** the launcher itself running the step after
  an update (only after a release).

## Settings

- 540p internal resolution (a store report: "let me downscale"; weak integrated GPUs). Verified: 960 x 540, 60 fps.
- "Descriptions" (This menu): a setting's description no longer opens under it (GitHub #29: it got in the way while
  moving through the list). Built, not seen in a screenshot (the menu-scroll test hook doesn't reach that panel).
- The launcher's settings: 540p, Sharpening, Texture filtering, Debanding, Frame time graph (all were in the game's
  menu only).
- Out of graphics memory now lowers the resolution one step down the menu's list; at 720p it used to go up to 1080p
  and say it was lowered.

## Reports read (translated)

- Spanish (RX 7800 XT, 0.2.8): playable and enjoyable at 180 Hz, but texture artifacts, and cutscenes lag and fail a
  lot. -> the AMD fallback; needs the new log.
- Portuguese (RTX 3050 Laptop, 0.2.7): the Cascade Kingdom stutters on the way to the waterfall, right at the start.
  -> 0.2.8's list-lock and scene-start fixes; 0.2.7 log only.
- Portuguese (RX 7600, 0.2.7): stutters and bugged textures in the first 3 kingdoms. -> AMD, as above.
- Portuguese (RX 550, 0.2.7): ran at 40 fps with heavy stutters in parts (old AMD driver without pipeline libraries).
- Polish (RTX 5070, 0.2.7): no sound in cutscenes and a black screen instead of the game. RTX 5060 Ti (0.2.7): black
  screen, no intro. -> no game log; not reproduced here.
- Portuguese (Radeon iGPU, 0.2.6): "it doesn't use my processor properly, so it lags a lot".
- German ("won't run", RX 7900 XT): "doesn't like my Switch dump" -> the game-files check (above, and the label).
- Portuguese #18 -> above. Portuguese / Italian crash issues #1 #2 #6 #13 #20 (0.2.2-0.2.5): the old crashes while
  loading text or Mario's costume; no newer report has them.

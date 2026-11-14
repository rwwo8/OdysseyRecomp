# The first frames of a scene (2026-11-14, open)

## Problem

Entering a kingdom or starting a scene again after a fall: one frame of 150-350 ms, then a few of 50-90 ms. Seen in
every kingdom of `tools/bench_kingdoms.sh` with 0.2.3 and 0.2.4 alike.

## Evidence

- `ODYSSEY_VK_PROF=1` (`[present]`, `[submit]` lines since this note): the time is the presenting thread waiting for
  the GPU; the submission itself is quick, and no shader is built then (`compiles 0 pending` at a scene restart).
- `ODYSSEY_GPUPROF_AT=1285` in the Cascade warp run (`build/gp_casc2.log`, 1,961 marks, the whole frame): 153 ms of GPU
  work, 119 ms of it 64 draws of one fragment shader (fs hash 6005e82f2a61e98b, code 72707fea00) into 32x32 targets,
  ~2.4 ms each. Not the huge shader (fs 726b930e00): this one (`build/glsl/72707fea00_fs.glsl`, 13 blocks) is a 3D
  cellular noise - three passes of 7 x 7 x 7 neighbour cells per pixel, floor / distance / min - so its cost is its
  own work, not the translation: ordered blocks (`ODYSSEY_ORDERED_BLOCKS=8`) gave the same 119 ms. The game makes this
  noise volume again at each scene start.
- The full-screen copies (`fbcopy`) at a scene start are mostly 32x32 and 400x228 targets: ~3 ms in all.

## Next

Find the game code that draws it (Ghidra: who binds that program at a scene start) and whether the Switch makes it
once and keeps it: if the noise volume's contents are lost on our side between scenes, keeping them (or the result
once per run) removes the hitch. Tried and dropped: an optimized build of the huge shader swapped in (it isn't the one).
Side finding: 564 of 1,049 fragment shaders use the `switch (pc)` state machine (no structured if / loops yet).

# Storage snapshot table churn (gameplay hitches)

## Seen

The user's log (`smo.log`, update 31) had a 766 ms frame in gameplay. Thousands of `[snap] ... evicted (table full, bound
longest ago)` and `new: in place, CPU writes tracked` lines appeared around it (frames 1638-1652).

## Evidence

Seven compute-bound buffers (`729bc339a0` and neighbours) grow by 16 bytes every frame, from 512 to 6400+ bytes. Each size was a
new entry in the 512-entry range table, so the table filled in about 70 frames. After that it evicted and re-armed write
tracking on hundreds of ranges a second, and the allocation scan walked all the stale overlapping entries.

## Fix

`runtime/nvn/vulkan/exec.c` (`snap_storage`): an in-place compute range at the same address takes the new (larger) size
instead of becoming a new entry. The per-range log is capped at 400 lines.

## Verified

Same Cap Kingdom run: 237 snap lines in total, against more than 4,000 in the user's log. The only remaining gameplay
spikes lined up with the screenshot tool's own frames.

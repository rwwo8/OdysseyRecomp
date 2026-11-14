#!/bin/bash
# The table of tools/bench_kingdoms.sh: per log (build/bench/<tag>_*.log), from the 2-second fps lines after the first
# 1000 frames (the warp): the average fps, windows under 58 fps, the slowest frame, frames over 50 ms ([hitch] lines,
# ODYSSEY_VK_PROF), and the totals of draws skipped, shader compiles and pipeline links in play.
cd "$(dirname "$0")/.."
TAG=${1:-bench}
printf "%-26s %6s %5s %6s %6s %7s %7s %6s %7s\n" stage avgfps lt58 maxms hitch skipped compile link ramMB
for f in build/bench/${TAG}_*.log; do
    st=$(basename "$f" .log); st=${st#${TAG}_}
    grep -E "^\[vk\] t=" "$f" | awk -v st="$st" -v hz="$(grep -c '^\[hitch\]' "$f")" '
        { match($0, /frame [0-9]+/); fr = substr($0, RSTART + 6, RLENGTH - 6) + 0
          if (fr < 1000) next
          match($0, /[0-9.]+ fps/); fps = substr($0, RSTART, RLENGTH - 4) + 0
          match($0, /max [0-9]+ms/); mx = substr($0, RSTART + 4, RLENGTH - 6) + 0
          match($0, /[0-9]+ skipped/); sk += substr($0, RSTART, RLENGTH - 8)
          match($0, /compile [0-9]+/); co += substr($0, RSTART + 8, RLENGTH - 8)
          match($0, /link [0-9]+/); li += substr($0, RSTART + 5, RLENGTH - 5)
          if (match($0, /ram [0-9]+ MB/)) { r = substr($0, RSTART + 4, RLENGTH - 7) + 0; if (r > ram) ram = r }
          n++; sum += fps; if (fps < 58) low++; if (mx > m) m = mx }
        END { if (n) printf "%-26s %6.1f %5d %6d %6d %7d %7d %6d %7d\n", st, sum / n, low, m, hz, sk, co, li, ram
              else printf "%-26s (no frames past the warp)\n", st }'
done

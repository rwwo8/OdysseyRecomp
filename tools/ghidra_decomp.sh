#!/bin/bash
# Decompile game functions with Ghidra (headless, no auto-analysis: seconds per run).
#   tools/ghidra_decomp.sh out.c 7000a56758 [more hex addresses...]
# First run sets up ../ghidra: the decompressed main image with relative relocations applied (main.bin, loaded at
# 0x7000000000), the symbol list (main_syms.txt) and the project. GHIDRA: the Ghidra install folder.
set -e
cd "$(dirname "$0")/.."
GHIDRA=${GHIDRA:-/e/ghidra_12.1.4_PUBLIC_20260921/ghidra_12.1.4_PUBLIC}
W=$(cd .. && pwd)/ghidra
mkdir -p "$W"
if [ ! -f "$W/main.bin" ]; then
    tools/venv/Scripts/python.exe -I - "$W" <<'PY'
import sys, struct
sys.path.insert(0, 'tools')
from nso import Nso
w = sys.argv[1]
n = Nso('Extracted/exefs/main')
img = bytearray(n.image)
for off, typ, sym, add in n.relocs:
    if typ == 1027 and off + 8 <= len(img):  # R_AARCH64_RELATIVE
        struct.pack_into('<Q', img, off, 0x7000000000 + add)
open(w + '/main.bin', 'wb').write(img)
with open(w + '/main_syms.txt', 'w') as f:
    for s in n.exports():
        if s[3]: f.write('%x %s\n' % (0x7000000000 + s[3], s[0]))
PY
fi
OUT=$(cygpath -w "$(realpath -m "$1")"); shift
WW=$(cygpath -w "$W"); SCR=$(cygpath -w "$(pwd)/tools/ghidra")
if [ ! -d "$W/smo.rep" ]; then
    IMPORT=(-import "$WW\main.bin" -loader BinaryLoader -loader-baseAddr 0x7000000000 -processor AARCH64:LE:64:v8A)
else
    IMPORT=(-process main.bin -readOnly)
fi
cmd //c "$(cygpath -w "$GHIDRA/support/analyzeHeadless.bat")" "$WW" smo "${IMPORT[@]}" -noanalysis \
    -scriptPath "$SCR" -postScript Decomp.java "$WW\main_syms.txt" "$OUT" "$@" > "$W/run.log" 2>&1
echo "wrote $OUT"

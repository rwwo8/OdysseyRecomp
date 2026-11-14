"""The Linux release, put together on Windows (no Linux machine): build/dist/Odyssey Recomp-<version>-linux-x86_64.tar.gz.

    python tools/linux/cross_package.py <cross dir>

<cross dir> holds what tools/linux/cross_build.sh made: deps/lib (SDL3, FFmpeg, shaderc .so), py/py.tar.gz (a portable
CPython 3.12 for Linux, python-build-standalone) and py/wheels (capstone, unicorn, lz4 for it), zig/zig.tar.xz (zig
for Linux, the setup's compiler). The app itself: build/linux-x/OdysseyRecomp. Laid out as the AppImage is
(tools/linux/package.sh): usr/bin (the program and what it ships next to it: rt_resource), usr/lib (the libraries,
by their sonames: the program's rpath is $ORIGIN/../lib); OdysseyRecomp.sh at the top starts it. The tar file carries
the Unix modes (executables 755) that a Windows folder can't. No game files, no game code.
"""
import ast
import io
import lzma
import os
import re
import sys
import tarfile
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS = os.path.join(REPO, 'tools')
TOP = 'Odyssey Recomp'


def version():
    rc = open(os.path.join(REPO, 'runtime', 'platform', 'windows.rc'), encoding='utf-8').read()
    return re.search(r'"ProductVersion", "([^"]+)"', rc).group(1)


def local_modules(script):  # tools/*.py the generator imports (as tools/pyembed.py)
    todo, seen = [script], set()
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.add(path)
        tree = ast.parse(open(path, encoding='utf-8').read(), path)
        for node in ast.walk(tree):
            names = [a.name for a in node.names] if isinstance(node, ast.Import) else \
                    [node.module] if isinstance(node, ast.ImportFrom) and node.module and not node.level else []
            for name in names:
                cand = os.path.join(TOOLS, name.split('.')[0] + '.py')
                if os.path.exists(cand):
                    todo.append(cand)
    return sorted(seen)


class Out:
    def __init__(self, path):
        self.tar = tarfile.open(path, 'w:gz', compresslevel=9)
        self.dirs = set()

    def _dir(self, name):
        parts = name.split('/')
        for i in range(1, len(parts)):
            d = '/'.join(parts[:i])
            if d not in self.dirs:
                self.dirs.add(d)
                ti = tarfile.TarInfo(d)
                ti.type, ti.mode = tarfile.DIRTYPE, 0o755
                self.tar.addfile(ti)

    def data(self, name, data, mode=0o644):
        name = f'{TOP}/{name}'
        self._dir(name)
        ti = tarfile.TarInfo(name)
        ti.size, ti.mode = len(data), mode
        self.tar.addfile(ti, io.BytesIO(data))

    def file(self, name, src, mode=None):
        data = open(src, 'rb').read()
        if mode is None:
            mode = 0o755 if data[:4] == b'\x7fELF' and b'.so' not in os.path.basename(src).encode() or data[:2] == b'#!' else 0o644
        self.data(name, data, mode)

    def link(self, name, target):
        name = f'{TOP}/{name}'
        self._dir(name)
        ti = tarfile.TarInfo(name)
        ti.type, ti.linkname, ti.mode = tarfile.SYMTYPE, target, 0o777
        self.tar.addfile(ti)


def main():
    X = sys.argv[1]
    ver = version()
    os.makedirs(os.path.join(REPO, 'build', 'dist'), exist_ok=True)
    path = os.path.join(REPO, 'build', 'dist', f'Odyssey Recomp-{ver}-linux-x86_64.tar.gz')
    o = Out(path)
    B = 'usr/bin'
    # the start script (the folder can be anywhere: it finds itself)
    o.data('OdysseyRecomp.sh', b'#!/bin/sh\n# Odyssey Recomp: starts the game (its files are in ~/.local/share/odyssey-recomp)\n'
                               b'HERE=$(dirname "$(readlink -f "$0")")\nexec "$HERE/usr/bin/OdysseyRecomp" "$@"\n', 0o755)
    o.file(f'{B}/OdysseyRecomp', os.path.join(REPO, 'build', 'linux-x', 'OdysseyRecomp'), 0o755)
    o.file(f'{B}/icon.png', os.path.join(REPO, 'docs', 'icon', 'icon_512.png'))
    for f in ['third_party/imgui/misc/fonts/Roboto-Medium.ttf', 'runtime/nvn/vulkan/known_programs.txt',
              'runtime/nvn/vulkan/known_pipes.bin', 'README.md', 'LICENSE']:
        o.file(f'{B}/{os.path.basename(f)}', os.path.join(REPO, f))
    for f in ['runtime/cpu.h', 'runtime/simd.h', 'runtime/simd_fp.h', 'runtime/gamelib.h', 'tools/gamelib_entry.c',
              'runtime/hle/hle_symbols.txt']:
        o.file(f'{B}/gamelib-src/{os.path.basename(f)}', os.path.join(REPO, f))
    o.file('odysseyrecomp.desktop', os.path.join(TOOLS, 'linux', 'odysseyrecomp.desktop'))
    o.file('odysseyrecomp.png', os.path.join(REPO, 'docs', 'icon', 'icon_512.png'))
    # libraries, by soname (the program's NEEDED entries)
    lib = os.path.join(X, 'deps', 'lib')
    for so in ['libSDL3.so.0', 'libavformat.so.63', 'libavcodec.so.63', 'libavutil.so.61', 'libswscale.so.10',
               'libshaderc_shared.so.1']:
        o.file(f'usr/lib/{so}', os.path.join(lib, so), 0o755)
    # the game code generator: a portable CPython with the generator's packages, started by odysseygen/python
    # (runtime/gamebuild.c: odysseygen/python -B odysseygen/tools/gen.py <args>)
    G = f'{B}/odysseygen'
    o.data(f'{G}/python', b'#!/bin/sh\nHERE=$(dirname "$(readlink -f "$0")")\nexec "$HERE/py/bin/python3.12" "$@"\n', 0o755)
    with tarfile.open(os.path.join(X, 'py', 'py.tar.gz')) as t:
        for m in t.getmembers():
            n = m.name[len('python/'):] if m.name.startswith('python/') else None
            if not n or n.startswith(('share/', 'include/')) or '/test/' in n or '/tests/' in n or '/idlelib/' in n or \
                    '/tkinter/' in n or '/ensurepip/' in n or '__pycache__' in n:
                continue
            if m.issym():
                o.link(f'{G}/py/{n}', m.linkname)
            elif m.isfile():
                o.data(f'{G}/py/{n}', t.extractfile(m).read(), 0o755 if m.mode & 0o111 else 0o644)
    site = f'{G}/py/lib/python3.12/site-packages'
    for w in sorted(os.listdir(os.path.join(X, 'py', 'wheels'))):
        with zipfile.ZipFile(os.path.join(X, 'py', 'wheels', w)) as z:
            for n in z.namelist():
                if n.endswith('/'):
                    continue
                d = z.read(n)
                o.data(f'{site}/{n}', d, 0o755 if d[:4] == b'\x7fELF' else 0o644)
    for f in local_modules(os.path.join(TOOLS, 'gen.py')):
        o.file(f'{G}/tools/{os.path.basename(f)}', f, 0o644)
    # zig for Linux, slimmed as tools/fetch_zig.sh does (C for this machine: glibc headers and sources)
    with tarfile.open(fileobj=lzma.open(os.path.join(X, 'zig', 'zig.tar.xz'))) as t:
        for m in t.getmembers():
            n = m.name.split('/', 1)[1] if '/' in m.name else ''
            if not n or n.startswith(('doc/', 'lib/libcxx', 'lib/libcxxabi', 'lib/libtsan', 'lib/docs')):
                continue
            parts = n.split('/')
            if n.startswith('lib/libc/include/') and len(parts) > 3 and not re.search('linux|glibc', parts[3]):
                continue
            if n.startswith('lib/libc/') and len(parts) > 2 and parts[2] not in ('include', 'glibc'):
                continue
            if m.issym():
                o.link(f'{B}/zig/{n}', m.linkname)
            elif m.isfile():
                o.data(f'{B}/zig/{n}', t.extractfile(m).read(), 0o755 if m.mode & 0o111 else 0o644)
    # licences: as the Windows release's (licenses/), plus the ones only this one carries
    wl = os.path.join(REPO, 'build', 'dist', 'Odyssey Recomp', 'licenses')
    for f in sorted(os.listdir(wl)):
        if os.path.isfile(os.path.join(wl, f)):
            o.file(f'{B}/licenses/{f}', os.path.join(wl, f), 0o644)
    work = os.path.join(X, 'work')
    for src, dst in [('SDL3-3.4.16/LICENSE.txt', 'SDL3-zlib.txt'), ('ffmpeg-9.0.2/COPYING.LGPLv2.1', 'FFmpeg-LGPL-2.1.txt'),
                     ('shaderc-2026.3/LICENSE', 'shaderc-Apache-2.0.txt')]:
        o.file(f'{B}/licenses/{dst}', os.path.join(work, src), 0o644)
    o.data(f'{B}/licenses/README-linux.txt',
           b'The Linux build carries, besides what README.txt lists: SDL 3.4.16 (zlib), an LGPL-only FFmpeg 9.0.2 built\n'
           b'as tools/linux/cross_build.sh configures it, shaderc 2026.3 (Apache 2.0) in usr/lib; a portable CPython 3.12\n'
           b'(python-build-standalone, PSF licence: usr/bin/odysseygen/py) with capstone (BSD), unicorn (GPL 2.0) and lz4\n'
           b'(BSD); zig 0.17.0 for Linux (MIT, with LLVM: Apache 2.0 with LLVM exception) in usr/bin/zig.\n', 0o644)
    o.tar.close()
    print(path, os.path.getsize(path) // (1 << 20), 'MB')


if __name__ == '__main__':
    main()

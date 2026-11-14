#!/bin/bash
# The Linux release built on Windows, with no Linux machine or container (MSYS2 UCRT64 shell, Python 3.12):
#   tools/linux/cross_build.sh [cross dir]     -> build/dist/Odyssey Recomp-<version>-linux-x86_64.tar.gz
# zig (a full Windows zig 0.17.0: its glibc 2.35 headers and stubs) compiles for x86_64-linux-gnu.2.35; an Ubuntu 22.04
# sysroot of -dev packages (tools/linux/cross_sysroot.py) gives SDL3 the X11 / audio / input headers. Each part is
# skipped when its output exists (delete it to redo). Not tested on Linux here (no Linux machine): see docs/linux.md.
# The cross dir (default ../scratch/linux-x) holds: bin/ (zig wrappers), sysroot/, src/, work/, deps/, py/, zig/.
set -euo pipefail
cd "$(dirname "$0")/../.."
X=${1:-$(cd .. && pwd)/scratch/linux-x}
XW=$(cygpath -m "$X")
ZIGDIR=${ZIGDIR:-$(cd .. && pwd)/scratch/zigfull/zig-x86_64-windows-0.17.0}
ZW=$(cygpath -w "$ZIGDIR/zig.exe")
PY=${PY:-$(command -v py.exe >/dev/null && py.exe -3.12 -c "import sys;print(sys.executable)" | tr -d "" || echo python3)}
export PATH=/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH TMPDIR=$X/tmp TMP=$X/tmp TEMP=$X/tmp
mkdir -p "$X"/{bin,src,work,deps/include,py,zig,zigcache,tmp}

# zig wrappers (its cache on this drive): sh ones for configure scripts, .cmd ones for CMake
CW=$(cygpath -w "$X/zigcache")
for n in "zcc cc -target x86_64-linux-gnu.2.35" "zcxx c++ -target x86_64-linux-gnu.2.35" "zar ar" "zranlib ranlib"; do
    set -- $n; f=$1; shift
    printf '#!/bin/sh\nexport ZIG_GLOBAL_CACHE_DIR="%s" ZIG_LOCAL_CACHE_DIR="%s"\nexec "%s" %s "$@"\n' "$X/zigcache" "$X/zigcache" "$ZIGDIR/zig.exe" "$*" > "$X/bin/$f"
    printf '@set ZIG_GLOBAL_CACHE_DIR=%s\r\n@set ZIG_LOCAL_CACHE_DIR=%s\r\n@"%s" %s %%*\r\n' "$CW" "$CW" "$ZW" "$*" > "$X/bin/$f.cmd"
    chmod +x "$X/bin/$f"
done

[ -d "$X/sysroot/usr/include/X11" ] || PYTHONPATH=$X/pylib "$PY" tools/linux/cross_sysroot.py "$XW/sysroot"
S=$XW/sysroot
INC="-isystem $S/usr/include -isystem $XW/deps/include -isystem $S/usr/include/dbus-1.0 -isystem $S/usr/lib/x86_64-linux-gnu/dbus-1.0/include -isystem $S/usr/include/pipewire-0.3 -isystem $S/usr/include/spa-0.2"
cat > "$X/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_LIBRARY_ARCHITECTURE x86_64-linux-gnu)
set(CMAKE_C_COMPILER "$XW/bin/zcc.cmd")
set(CMAKE_CXX_COMPILER "$XW/bin/zcxx.cmd")
set(CMAKE_AR "$XW/bin/zar.cmd")
set(CMAKE_RANLIB "$XW/bin/zranlib.cmd")
set(CMAKE_C_FLAGS_INIT "$INC")
set(CMAKE_CXX_FLAGS_INIT "$INC")
set(CMAKE_FIND_ROOT_PATH "$S;$XW/deps")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

# sources: the same pinned releases as tools/linux/build_deps.sh
fetch() { [ -f "$X/src/$3" ] || curl -fsSL -o "$X/src/$3" "$1"; echo "$2 *$X/src/$3" | sha256sum -c --quiet; }
fetch https://github.com/libsdl-org/SDL/releases/download/release-3.4.16/SDL3-3.4.16.tar.gz \
      7322236cd12090c3eb40b9728be4d49c76f66ad17d04369584d4ecad5cf77c68 SDL3-3.4.16.tar.gz
fetch https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e ffmpeg-9.0.2.tar.xz
fetch https://github.com/google/shaderc/archive/refs/tags/v2026.3.tar.gz \
      ee493ccf1b3038b4ef2fe024664c5eb2dc4bcc1f6b05b33e3909de0e19c81024 shaderc-2026.3.tar.gz
fetch https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-1.4.350.1.tar.gz \
      6d1bb65e49520344cc0a48af3dc02e993781efff14c7ebdcb8ae9fa23ddf7e83 Vulkan-Headers-1.4.350.1.tar.gz
fetch https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/archive/refs/tags/v3.3.0.tar.gz \
      c4f6bbe6b5a45c2eb610ca9d231158e313086d5b1a40c9922cb42b597419b14e VulkanMemoryAllocator-3.3.0.tar.gz
fetch https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz \
      1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 zig-x86_64-linux-0.17.0.tar.xz
cp -u "$X/src/zig-x86_64-linux-0.17.0.tar.xz" "$X/zig/zig.tar.xz"
W=$X/work
cd "$W"
for t in Vulkan-Headers-1.4.350.1 VulkanMemoryAllocator-3.3.0 SDL3-3.4.16; do ls -d ${t%%-1.4*}* >/dev/null 2>&1 || tar -xf "$X/src/$t.tar.gz"; done
cp -R Vulkan-Headers-*/include/vulkan Vulkan-Headers-*/include/vk_video "$X/deps/include/"
mkdir -p "$X/deps/include/vma" && cp VulkanMemoryAllocator-3.3.0/include/vk_mem_alloc.h "$X/deps/include/vma/"

# SDL3: X11 (and XWayland), PulseAudio / PipeWire / ALSA, udev, D-Bus - loaded at run time; no Wayland (its scanner
# would have to run on the build machine) and no OpenGL / KMSDRM (the game draws with Vulkan in a window)
if [ ! -f "$X/deps/lib/libSDL3.so.0" ]; then
    PKG_CONFIG_LIBDIR="$S/usr/lib/x86_64-linux-gnu/pkgconfig;$S/usr/share/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$S" \
    cmake -S SDL3-3.4.16 -B sdl-build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$X/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$XW/deps" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON -DSDL_SHARED=ON \
        -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_RPATH=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF -DSDL_OPENGL=OFF \
        -DSDL_OPENGLES=OFF -DSDL_IBUS=OFF -DSDL_HIDAPI_LIBUSB=OFF -DSDL_JACK=OFF -DSDL_SNDIO=OFF
    cmake --build sdl-build -j16 && cmake --install sdl-build
fi

# FFmpeg, LGPL only, the movies' codecs (as tools/build_deps_windows.sh). zig on Windows can't link -l<name> against
# a .so it finds itself (it passes lld an absolute -l: path): FFmpeg's own libraries go to the linker by path.
if [ ! -f "$X/deps/lib/libavcodec.so.63" ]; then
    [ -d ffmpeg-9.0.2 ] || tar -xf "$X/src/ffmpeg-9.0.2.tar.xz"
    (cd ffmpeg-9.0.2 && ./configure --prefix="$XW/deps" --enable-cross-compile --target-os=linux --arch=x86_64 \
        --cc="$X/bin/zcc" --cxx="$X/bin/zcxx" --ld="$X/bin/zcc" --ar="$X/bin/zar" --ranlib="$X/bin/zranlib" --nm=nm \
        --strip=strip --host-cc=gcc --enable-shared --disable-static --enable-pic --disable-autodetect --disable-programs \
        --disable-doc --disable-network --disable-avdevice --disable-avfilter --disable-swresample --disable-everything \
        --enable-protocol=file --enable-demuxer=matroska,mov --enable-decoder=vp9,vp8,vorbis,opus,h264,aac \
        --enable-parser=vp9,vp8,vorbis,opus,h264,aac \
     && sed -i 's/#define HAVE_SYSCTL 1/#define HAVE_SYSCTL 0/' config.h \
     && sed -i 's/ -latomic//g' ffbuild/config.mak \
     && sed -i 's#^FFEXTRALIBS := $(LDLIBS:%=$(LD_LIB))#FFEXTRALIBS := $(foreach l,$(LDLIBS),lib$(l)/lib$(l).so)#' ffbuild/common.mak \
     && make -j16 && make install)
fi

# shaderc as one shared library, its DEPS pinned glslang / SPIRV-Tools / SPIRV-Headers
if [ ! -f "$X/deps/lib/libshaderc_shared.so.1" ]; then
    [ -d shaderc-2026.3 ] || tar -xf "$X/src/shaderc-2026.3.tar.gz"
    (cd shaderc-2026.3 && "$PY" utils/git-sync-deps)
    cmake -S shaderc-2026.3 -B sc-build -G Ninja -DCMAKE_TOOLCHAIN_FILE="$X/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$XW/deps" -DCMAKE_INSTALL_LIBDIR=lib -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
        -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DENABLE_GLSLANG_BINARIES=OFF \
        -DSPIRV_TOOLS_BUILD_STATIC=ON -DBUILD_SHARED_LIBS=OFF -DPython3_EXECUTABLE="$(cygpath -m "$PY")" \
        -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON
    cmake --build sc-build --target shaderc_shared -j16
    mkdir -p "$X/deps/include/shaderc" && cp shaderc-2026.3/libshaderc/include/shaderc/*.h "$X/deps/include/shaderc/"
    cp sc-build/libshaderc/libshaderc_shared.so* "$X/deps/lib/"
fi
cd - >/dev/null

# the generator's Python for Linux (python-build-standalone) and its packages
[ -f "$X/py/py.tar.gz" ] || curl -fsSL -o "$X/py/py.tar.gz" \
    "https://github.com/astral-sh/python-build-standalone/releases/download/20261110/cpython-3.12.16%2B20261110-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz"
ls "$X/py/wheels"/unicorn-* >/dev/null 2>&1 || "$PY" -m pip download -q --only-binary=:all: --platform manylinux2014_x86_64 \
    --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64 --python-version 3.12 --implementation cp --abi cp312 \
    --abi abi3 --abi none -d "$X/py/wheels" capstone==5.0.9 unicorn==2.1.4 lz4==4.4.5

# the app (no game code: the player's setup builds it). The rpath is linked as XORIGIN and patched to $ORIGIN (the
# shells between here and the linker ate a literal $ORIGIN)
D=$XW/deps/lib
APPINC="-isystem $XW/deps/include -isystem $S/usr/include"  # (our Vulkan headers before Ubuntu 22.04's older ones)
rm -f build/linux-x/OdysseyRecomp
make PLATFORM=linux ARCH=x86_64 HOSTARCH=x86_64 B=build/linux-x CC="$X/bin/zcc $APPINC" CXX="$X/bin/zcxx $APPINC" DEPS="$XW/deps" \
    LDFLAGS="-fuse-ld=lld -rdynamic $D/libSDL3.so $D/libavformat.so $D/libavcodec.so $D/libavutil.so $D/libswscale.so $S/usr/lib/x86_64-linux-gnu/libvulkan.so.1 $D/libshaderc_shared.so -lpthread -ldl -lm -Wl,-rpath,XORIGIN/../lib" \
    -j16 build/linux-x/OdysseyRecomp
"$PY" -c "
p='build/linux-x/OdysseyRecomp'; d=open(p,'rb').read(); assert d.count(b'XORIGIN/../lib') == 1
open(p,'wb').write(d.replace(b'XORIGIN/../lib', b'\$ORIGIN/../lib'))"
"$PY" -I tools/linux/cross_package.py "$XW"

"""Linux build from Windows (no Linux machine, no containers): an Ubuntu 22.04 sysroot of the -dev packages the
Linux build compiles against (SDL3's video / audio / input backends, Vulkan), from the Ubuntu archive's .deb files,
unpacked into build/linux-x/sysroot. glibc itself comes with zig (-target x86_64-linux-gnu.2.35). See
tools/linux/cross_build.sh.

    python tools/linux/cross_sysroot.py <sysroot dir>
"""
import io
import lzma
import os
import sys
import tarfile
import urllib.request

MIRROR = 'http://archive.ubuntu.com/ubuntu/'
DISTS = ['jammy-updates', 'jammy']
COMPONENTS = ['main', 'universe']
PKGS = [
    # X11 (SDL loads the libraries at run time: the headers decide what it can use)
    'libx11-dev', 'x11proto-dev', 'libxext-dev', 'libxrandr-dev', 'libxrender-dev', 'libxcursor-dev', 'libxi-dev',
    'libxfixes-dev', 'libxss-dev', 'libxtst-dev', 'libxkbcommon-dev', 'libxcb1-dev', 'libxau-dev', 'libxdmcp-dev',
    'xtrans-dev',
    # audio, input, desktop
    'libpulse-dev', 'libasound2-dev', 'libpipewire-0.3-dev', 'libspa-0.2-dev', 'libdbus-1-dev', 'libudev-dev',
    'libdecor-0-dev', 'libwayland-dev', 'wayland-protocols', 'libibus-1.0-dev',
    # Vulkan: the headers come from Vulkan-Headers; the loader to link against (libvulkan.so.1)
    'libvulkan-dev', 'libvulkan1',
    # the libraries the -dev packages' .so links point at (SDL finds their sonames; the app links against libvulkan)
    'libx11-6', 'libxext6', 'libxrandr2', 'libxrender1', 'libxcursor1', 'libxi6', 'libxfixes3', 'libxss1', 'libxtst6',
    'libxkbcommon0', 'libxcb1', 'libxau6', 'libxdmcp6', 'libasound2', 'libpulse0', 'libpipewire-0.3-0',
    'libdbus-1-3', 'libudev1', 'libdecor-0-0', 'libwayland-client0', 'libwayland-cursor0', 'libwayland-egl1',
]


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def index():
    pk = {}
    for d in DISTS:
        for c in COMPONENTS:
            data = lzma.decompress(fetch(f'{MIRROR}dists/{d}/{c}/binary-amd64/Packages.xz')).decode('utf-8', 'replace')
            for block in data.split('\n\n'):
                f = {}
                for line in block.splitlines():
                    if ':' in line and not line.startswith(' '):
                        k, v = line.split(':', 1)
                        f[k] = v.strip()
                if 'Package' in f and f['Package'] not in pk:
                    pk[f['Package']] = f
    return pk


def ar_members(data):
    assert data[:8] == b'!<arch>\n'
    o = 8
    while o + 60 <= len(data):
        h = data[o:o + 60]
        name = h[:16].decode().strip().rstrip('/')
        size = int(h[48:58].decode().strip())
        yield name, data[o + 60:o + 60 + size]
        o += 60 + size + (size & 1)


def unpack_deb(data, root):
    for name, body in ar_members(data):
        if not name.startswith('data.tar'):
            continue
        if name.endswith('.zst'):
            import zstandard
            body = zstandard.ZstdDecompressor().decompressobj().decompress(body)
            mode = 'r:'
        else:
            mode = 'r:xz' if name.endswith('.xz') else 'r:gz' if name.endswith('.gz') else 'r:'
        with tarfile.open(fileobj=io.BytesIO(body), mode=mode) as t:
            for m in t.getmembers():
                if not (m.name.startswith('./usr/include') or m.name.startswith('./usr/lib') or
                        m.name.startswith('./usr/share/pkgconfig') or m.name.startswith('./usr/share/wayland')):
                    continue
                dst = os.path.join(root, m.name[2:])
                if m.isdir():
                    os.makedirs(dst, exist_ok=True)
                elif m.issym():  # (links as copies of what they point at, later: Windows has no symlinks here)
                    links.append((dst, m.linkname))
                elif m.isfile():
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    with open(dst, 'wb') as out:
                        out.write(t.extractfile(m).read())


links = []


def main():
    root = sys.argv[1]
    os.makedirs(root, exist_ok=True)
    pk = index()
    for p in PKGS:
        f = pk.get(p)
        if not f:
            print('missing', p)
            continue
        print('unpacking', p, f['Version'])
        unpack_deb(fetch(MIRROR + f['Filename']), root)
    import shutil
    for _ in range(3):  # (links to links)
        for dst, target in list(links):
            src = target if target.startswith('/') else os.path.join(os.path.dirname(dst), target)
            src = os.path.join(root, src.lstrip('/')) if target.startswith('/') else src
            if os.path.isfile(src) and not os.path.exists(dst):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(src, dst)
    print('sysroot:', root)


if __name__ == '__main__':
    main()

// The game's title logo from the player's own files (game_logo.h): LayoutData/TitleLogoParts.szs (Yaz0) holds
// layout.lyarc (SARC), which holds timg/__Combined.bntx with one texture, CmTitleLogo^w: 760x470, ASTC 4x4 sRGB,
// block-linear. Unswizzled (nvn/tegra.c) and decoded (nvn/astc.c) with the runtime's own code.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "game_logo.h"
#include "nvn/astc.h"
#include "nvn/tegra.h"
#include "romfs_read.h"
#include "rt.h"

#define LOGO_FILE "LayoutData/TitleLogoParts.szs"

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t rd64(const uint8_t *p) { return rd32(p) | (uint64_t)rd32(p + 4) << 32; }

static uint8_t *read_loose(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = sz > 0 && sz < (64 << 20) ? malloc((size_t)sz) : NULL;
    if (d && fread(d, 1, (size_t)sz, f) != (size_t)sz) free(d), d = NULL;
    fclose(f);
    if (d) *n = (size_t)sz;
    return d;
}

// The BNTX's first texture whose name starts with "CmTitleLogo", decoded to RGBA8
static bool decode_bntx(const uint8_t *b, size_t n, uint8_t **rgba, int *w_out, int *h_out) {
    if (n < 0x40 || memcmp(b, "BNTX", 4) || memcmp(b + 0x20, "NX  ", 4)) return false;
    uint32_t count = rd32(b + 0x24);
    uint64_t arr = rd64(b + 0x28);
    for (uint32_t i = 0; i < count && i < 64; i++) {
        if (arr + 8 * (i + 1) > n) return false;
        uint64_t o = rd64(b + arr + 8 * i);
        if (o + 0x80 > n || memcmp(b + o, "BRTI", 4)) return false;
        const uint8_t *t = b + o;
        uint64_t name = rd64(t + 0x60), ptrs = rd64(t + 0x70);
        if (name + 2 > n || ptrs + 8 > n) return false;
        uint32_t nl = (uint32_t)b[name] | (uint32_t)b[name + 1] << 8;
        if (name + 2 + nl > n || nl < 11 || memcmp(b + name + 2, "CmTitleLogo", 11)) continue;
        uint32_t fmt = rd32(t + 0x1c), w = rd32(t + 0x24), h = rd32(t + 0x28), bh_log2 = rd32(t + 0x34) & 7;
        uint32_t size = rd32(t + 0x50);
        uint64_t data = rd64(b + ptrs);
        // ASTC 4x4 only (0x2d01 linear, 0x2d06 sRGB): what every version of the game has here
        if ((fmt >> 8) != 0x2d || w == 0 || h == 0 || w > 4096 || h > 4096) {
            LOG("[logo] %.*s: format %#x, %ux%u not handled\n", (int)nl, b + name + 2, fmt, w, h);
            return false;
        }
        uint32_t wb = (w + 3) / 4, hb = (h + 3) / 4;
        uint64_t gob_rows = 8u << bh_log2, need = (uint64_t)((wb * 16 + 63) / 64) * 512 * (1u << bh_log2) *
                                                   ((hb + gob_rows - 1) / gob_rows);
        if (need > size || data + need > n) return false;
        uint8_t *lin = malloc((size_t)wb * hb * 16), *px = malloc((size_t)w * h * 4);
        if (!lin || !px) { free(lin); free(px); return false; }
        tegra_deswizzle(b + data, lin, wb, hb, 1, 16, bh_log2, 0);
        astc_decode_ldr(lin, w, h, 4, 4, (fmt & 0xff) == 0x06, px);
        free(lin);
        // cropped to what isn't see-through (a little margin for the filtering at the edge)
        int x0 = (int)w, y0 = (int)h, x1 = -1, y1 = -1;
        for (int y = 0; y < (int)h; y++)
            for (int x = 0; x < (int)w; x++)
                if (px[((size_t)y * w + x) * 4 + 3] > 8) {
                    if (x < x0) x0 = x;
                    if (x > x1) x1 = x;
                    if (y < y0) y0 = y;
                    if (y > y1) y1 = y;
                }
        if (x1 < 0) { free(px); return false; }
        x0 = x0 > 2 ? x0 - 2 : 0, y0 = y0 > 2 ? y0 - 2 : 0;
        x1 = x1 + 2 < (int)w ? x1 + 2 : (int)w - 1, y1 = y1 + 2 < (int)h ? y1 + 2 : (int)h - 1;
        int cw = x1 - x0 + 1, ch = y1 - y0 + 1;
        uint8_t *out = malloc((size_t)cw * ch * 4);
        if (!out) { free(px); return false; }
        for (int y = 0; y < ch; y++) memcpy(out + (size_t)y * cw * 4, px + ((size_t)(y + y0) * w + x0) * 4, (size_t)cw * 4);
        free(px);
        // see-through texels take the colour of a visible neighbour: filtering at the logo's edge then blends
        // toward the logo's own colour instead of the black the encoder left there (a dark fringe when scaled)
        for (int pass = 0; pass < 4; pass++)
            for (int y = 0; y < ch; y++)
                for (int x = 0; x < cw; x++) {
                    uint8_t *p = out + ((size_t)y * cw + x) * 4;
                    if (p[3] > 8) continue;
                    static const int dx[4] = {1, -1, 0, 0}, dy[4] = {0, 0, 1, -1};
                    for (int k = 0; k < 4; k++) {
                        int nx = x + dx[k], ny = y + dy[k];
                        if (nx < 0 || ny < 0 || nx >= cw || ny >= ch) continue;
                        const uint8_t *q = out + ((size_t)ny * cw + nx) * 4;
                        if (q[3] > 8) { memcpy(p, q, 3); break; }
                    }
                }
        *rgba = out, *w_out = cw, *h_out = ch;
        return true;
    }
    return false;
}

bool game_logo_load(const char *game_dir, uint8_t **rgba, int *w, int *h) {
    char p[1100];
    size_t zn = 0, n = 0, ln = 0, bn = 0;
    snprintf(p, sizeof p, "%s/romfs.bin", game_dir);
    uint8_t *z = romfs_read_file(p, LOGO_FILE, &zn);
    if (!z) {  // (a source checkout before its RomFS image is made: the folder)
        snprintf(p, sizeof p, "%s/romfs/" LOGO_FILE, game_dir);
        z = read_loose(p, &zn);
    }
    if (!z) return false;
    uint8_t *d = yaz0_decode(z, zn, &n);
    free(z);
    if (!d) return false;
    const uint8_t *ly = sarc_find(d, n, "layout.lyarc", &ln);
    const uint8_t *bntx = ly ? sarc_find(ly, ln, "timg/__Combined.bntx", &bn) : NULL;
    bool ok = bntx && decode_bntx(bntx, bn, rgba, w, h);
    free(d);
    LOG("[logo] %s\n", ok ? "the game's title logo, from its files" : "not found in the game files (the name as text)");
    return ok;
}

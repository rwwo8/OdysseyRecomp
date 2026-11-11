// The game's button pictures, drawn as the player's controller's buttons (Controls tab "Button icons in the game").
//
// Super Mario Odyssey draws every button it names in text (prompts, menus, the pause screen) from one font:
// LocalizedData/<language>/LayoutData/FontData.szs : DeviceFont80.bffnt (the same in every language). Its one sheet is
// 512 x 1024, BC4 (one channel: the shapes, coloured by the text), cells 80 x 84 on an 81 x 85 grid, stored bottom-up.
// The pictures are white shapes with the letter cut out: a disc for A B X Y and Plus / Minus, tabs for L R ZL ZR.
//
// On the sheet's upload (vulkan/textures.c) the cells of the Switch buttons whose label changes are redrawn: the
// original shape with its cut-out filled, and the new label cut out of it - the label of the controller button bound
// to that Switch button (bindings.c, the Button layout applied) in the chosen family's words (Xbox: A B X Y, LB RB
// LT RT, Menu / View; PlayStation: Cross Circle Square Triangle, L1 R1 L2 R2, Options / Create). Letters come from
// Roboto Medium (shipped for the menu); the PlayStation symbols are drawn. The game's own bytes stay as they are.
#include <SDL3/SDL.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../input_bind.h"
#include "../paths.h"
#include "../romfs_read.h"
#include "../rt.h"
#include "../settings.h"
#include "glyphs.h"
#include "tegra.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wsign-compare"
#define STBTT_STATIC
#define STB_TRUETYPE_IMPLEMENTATION
#include "../../third_party/imgui/imstb_truetype.h"
#pragma clang diagnostic pop

#define SHEET_W 512
#define SHEET_H 1024
#define CELL_SX 81  // (the grid: an 80 x 84 cell and a pixel between)
#define CELL_SY 85
#define FONT_FILE "LocalizedData/USen/LayoutData/FontData.szs"

// Where the pictures are on the sheet (upright: row 0 at the top), measured: the grid starts at the top left.
typedef struct {
    int slot, col, row;  // Switch input, its cell
    const char *orig;    // what the game draws there (bind_pad_label of the default binding, family 0)
} Cell;
static const Cell k_cells[] = {
    {BIND_A, 2, 1, "A"},  {BIND_B, 3, 1, "B"},  {BIND_X, 4, 1, "X"},   {BIND_Y, 5, 1, "Y"},
    {BIND_L, 0, 2, "L"},  {BIND_R, 1, 2, "R"},  {BIND_ZL, 2, 2, "ZL"}, {BIND_ZR, 3, 2, "ZR"},
    {BIND_PLUS, 4, 3, "Plus"}, {BIND_MINUS, 5, 3, "Minus"},
};
enum { NCELLS = sizeof k_cells / sizeof *k_cells };

// ------------------------------------------------------------------ the game's own sheet (to recognise it)
static uint8_t *g_ref;
static size_t g_ref_n;
static bool g_ref_tried;

static uint32_t rd16(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }
static uint32_t rd32(const uint8_t *p) { return rd16(p) | rd16(p + 2) << 16; }

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

static void load_ref(void) {
    if (g_ref_tried) return;
    g_ref_tried = true;
    size_t zn = 0, n = 0, fn = 0;
    uint8_t *z = romfs_read_file("extracted/romfs.bin", FONT_FILE, &zn);
    if (!z) z = read_loose("extracted/romfs/" FONT_FILE, &zn);
    uint8_t *d = z ? yaz0_decode(z, zn, &n) : NULL;
    free(z);
    const uint8_t *f = d ? sarc_find(d, n, "DeviceFont80.bffnt", &fn) : NULL;
    if (f && fn > 0x20 && !memcmp(f, "FFNT", 4)) {
        for (size_t o = rd16(f + 6); o + 32 <= fn;) {  // the sections, after the header
            uint32_t sz = rd32(f + o + 4);
            if (!memcmp(f + o, "TGLP", 4)) {
                uint32_t ssz = rd32(f + o + 12), fmt = rd16(f + o + 18), w = rd16(f + o + 24), h = rd16(f + o + 26);
                uint32_t dat = rd32(f + o + 28);
                // (the sheet is a BNTX of its own: its texture's level 0 is what the game puts in GPU memory)
                const uint8_t *s = f + dat;
                uint64_t sn = ssz;
                if (w == SHEET_W && h == SHEET_H && dat + ssz <= fn && sn > 0x40 && !memcmp(s, "BNTX", 4)) {
                    uint64_t arr = rd32(s + 0x28) | (uint64_t)rd32(s + 0x2c) << 32;
                    uint64_t ti = arr + 8 <= sn ? (rd32(s + arr) | (uint64_t)rd32(s + arr + 4) << 32) : sn;
                    if (ti + 0x80 <= sn && !memcmp(s + ti, "BRTI", 4)) {
                        uint64_t ptrs = rd32(s + ti + 0x70) | (uint64_t)rd32(s + ti + 0x74) << 32;
                        uint64_t data = ptrs + 8 <= sn ? (rd32(s + ptrs) | (uint64_t)rd32(s + ptrs + 4) << 32) : sn;
                        uint64_t isz = rd32(s + ti + 0x50);
                        if (data + isz <= sn && isz > 4096 && (g_ref = malloc(isz))) {
                            memcpy(g_ref, s + data, isz);
                            g_ref_n = isz;
                        }
                    }
                }
                (void)fmt;
                break;
            }
            if (!sz) break;
            o += sz;
        }
    }
    free(d);
    if (!g_ref) LOG("[glyphs] the game's button font wasn't readable: its pictures stay as they are\n");
}

bool glyphs_is_sheet(const NvnTexture *t, const uint8_t *mem, uint64_t size) {
    const FormatInfo *fi = t->layout.fmt;
    if (t->width != SHEET_W || t->height != SHEET_H) return false;
    static int nlog;
    if (!fi || fi->bpb != 8 || fi->bw != 4 || fi->bh != 4) {
        if (nlog++ < 8) LOG("[glyphs] a %ux%u texture, format %#x: not BC4\n", t->width, t->height, t->format);
        return false;
    }
    load_ref();
    if (!g_ref) return false;
    uint64_t n = size < g_ref_n ? size : g_ref_n;
    bool yes = n > 4096 && !memcmp(mem, g_ref, n);
    if (!yes && nlog++ < 8) {
        uint64_t same = 0;
        while (same < n && mem[same] == g_ref[same]) same++;
        LOG("[glyphs] a %ux%u BC4 texture (%llu bytes, the font's sheet %zu): the same for %llu bytes (block height "
            "2^%u; %02x%02x%02x%02x vs %02x%02x%02x%02x)\n", t->width, t->height, (unsigned long long)size, g_ref_n,
            (unsigned long long)same, t->layout.block_height_log2, mem[0], mem[1], mem[2], mem[3], g_ref[0], g_ref[1],
            g_ref[2], g_ref[3]);
    }
    if (yes) LOG("[glyphs] the game's button font: its pictures follow the controller (Controls tab)\n");
    return yes;
}

// ------------------------------------------------------------------ which pictures
static int icon_family(void) {
    switch (g_settings.button_icons) {
    case ICONS_NINTENDO: return 0;
    case ICONS_XBOX: return 1;
    case ICONS_PLAYSTATION: return 2;
    default: {
        static _Atomic int fam = -1;
        static _Atomic uint64_t at;
        uint64_t now = SDL_GetTicks();  // (looked up twice a second at most: the sheet is checked every frame it's drawn)
        if (fam < 0 || now - at > 500) { fam = bind_label_family(); at = now; }
        return fam;
    }
    }
}

uint32_t glyphs_generation(void) {
    uint32_t h = 2166136261u ^ (uint32_t)icon_family();
    for (int i = 0; i < NCELLS; i++) h = (h ^ (uint32_t)(bind_prompt_host(k_cells[i].slot) + 1)) * 16777619u;
    return h;
}

// ------------------------------------------------------------------ BC4
static void bc4_palette(uint8_t a0, uint8_t a1, uint8_t p[8]) {
    p[0] = a0, p[1] = a1;
    if (a0 > a1) for (int i = 1; i <= 6; i++) p[i + 1] = (uint8_t)(((7 - i) * a0 + i * a1 + 3) / 7);
    else {
        for (int i = 1; i <= 4; i++) p[i + 1] = (uint8_t)(((5 - i) * a0 + i * a1 + 2) / 5);
        p[6] = 0, p[7] = 255;
    }
}
static void bc4_decode(const uint8_t *b, uint8_t out[16]) {
    uint8_t p[8];
    bc4_palette(b[0], b[1], p);
    uint64_t bits = 0;
    for (int i = 0; i < 6; i++) bits |= (uint64_t)b[2 + i] << (8 * i);
    for (int i = 0; i < 16; i++) out[i] = p[(bits >> (3 * i)) & 7];
}
static void bc4_encode(const uint8_t v[16], uint8_t *b) {
    uint8_t lo = 255, hi = 0;
    for (int i = 0; i < 16; i++) { if (v[i] < lo) lo = v[i]; if (v[i] > hi) hi = v[i]; }
    uint8_t p[8];
    if (hi == lo) { b[0] = hi, b[1] = lo; memset(b + 2, 0, 6); return; }
    b[0] = hi, b[1] = lo;  // (a0 > a1: eight levels from hi down to lo)
    bc4_palette(hi, lo, p);
    uint64_t bits = 0;
    for (int i = 0; i < 16; i++) {
        int best = 0, bd = 1 << 30;
        for (int k = 0; k < 8; k++) {
            int d = abs((int)p[k] - (int)v[i]);
            if (d < bd) bd = d, best = k;
        }
        bits |= (uint64_t)best << (3 * i);
    }
    for (int i = 0; i < 6; i++) b[2 + i] = (uint8_t)(bits >> (8 * i));
}

// ------------------------------------------------------------------ drawing
static stbtt_fontinfo g_font;
static uint8_t *g_font_data;
static bool g_font_tried;

static bool font_ready(void) {
    if (!g_font_tried) {
        g_font_tried = true;
        char p[1100];
        size_t n = 0;
        if (rt_resource("Roboto-Medium.ttf", "third_party/imgui/misc/fonts/Roboto-Medium.ttf", p, sizeof p))
            g_font_data = read_loose(p, &n);
        if (g_font_data && !stbtt_InitFont(&g_font, g_font_data, stbtt_GetFontOffsetForIndex(g_font_data, 0))) {
            free(g_font_data);
            g_font_data = NULL;
        }
        if (!g_font_data) LOG("[glyphs] Roboto-Medium.ttf not found: letters can't be drawn\n");
    }
    return g_font_data != NULL;
}

// text cut into cov (w x h, 0..255), its box centred on (cx, cy), at most max_w wide and max_h tall
static bool draw_text(float *cov, int w, int h, const char *t, float cx, float cy, float max_w, float max_h) {
    if (!font_ready()) return false;
    int n = (int)strlen(t);
    float px = max_h * 1.35f, scale;  // (a capital is ~0.7 of the pixel height)
    int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
    for (int pass = 0; pass < 2; pass++) {  // measure, shrink to fit, measure again
        scale = stbtt_ScaleForPixelHeight(&g_font, px);
        float pen = 0;
        x0 = y0 = 1 << 20, x1 = y1 = -(1 << 20);
        for (int i = 0; i < n; i++) {
            int adv, lsb, bx0, by0, bx1, by1;
            stbtt_GetCodepointHMetrics(&g_font, t[i], &adv, &lsb);
            stbtt_GetCodepointBitmapBox(&g_font, t[i], scale, scale, &bx0, &by0, &bx1, &by1);
            int gx = (int)lroundf(pen);
            if (gx + bx0 < x0) x0 = gx + bx0;
            if (gx + bx1 > x1) x1 = gx + bx1;
            if (by0 < y0) y0 = by0;
            if (by1 > y1) y1 = by1;
            pen += adv * scale;
            if (i + 1 < n) pen += stbtt_GetCodepointKernAdvance(&g_font, t[i], t[i + 1]) * scale;
        }
        float k = fminf(max_w / (float)(x1 - x0), max_h / (float)(y1 - y0));
        if (k >= 1 || pass == 1) break;
        px *= k;
    }
    int ox = (int)lroundf(cx - (x0 + x1) * 0.5f), oy = (int)lroundf(cy - (y0 + y1) * 0.5f);
    float pen = 0;
    for (int i = 0; i < n; i++) {
        int adv, lsb, bw, bh, xo, yo;
        stbtt_GetCodepointHMetrics(&g_font, t[i], &adv, &lsb);
        uint8_t *g = stbtt_GetCodepointBitmap(&g_font, scale, scale, t[i], &bw, &bh, &xo, &yo);
        int gx = ox + (int)lroundf(pen) + xo, gy = oy + yo;
        for (int y = 0; g && y < bh; y++)
            for (int x = 0; x < bw; x++) {
                int X = gx + x, Y = gy + y;
                if (X < 0 || Y < 0 || X >= w || Y >= h) continue;
                float c = g[y * bw + x] / 255.0f;
                if (c > cov[Y * w + X]) cov[Y * w + X] = c;
            }
        stbtt_FreeBitmap(g, NULL);
        pen += adv * scale;
        if (i + 1 < n) pen += stbtt_GetCodepointKernAdvance(&g_font, t[i], t[i + 1]) * scale;
    }
    return true;
}

static float seg_dist(float px, float py, float ax, float ay, float bx, float by) {
    float vx = bx - ax, vy = by - ay, wx = px - ax, wy = py - ay;
    float t = (wx * vx + wy * vy) / (vx * vx + vy * vy);
    t = t < 0 ? 0 : t > 1 ? 1 : t;
    float dx = wx - t * vx, dy = wy - t * vy;
    return sqrtf(dx * dx + dy * dy);
}

enum { SYM_CROSS, SYM_CIRCLE, SYM_SQUARE, SYM_TRIANGLE, SYM_MENU, SYM_VIEW };
// inside a symbol of size d at the origin (y down)?
static bool sym_inside(int sym, float x, float y, float d) {
    float t = 0.09f * d;
    switch (sym) {
    case SYM_CROSS: {
        float a = 0.17f * d;
        return seg_dist(x, y, -a, -a, a, a) < t * 0.6f || seg_dist(x, y, -a, a, a, -a) < t * 0.6f;
    }
    case SYM_CIRCLE: return fabsf(sqrtf(x * x + y * y) - 0.19f * d) < t * 0.5f;
    case SYM_SQUARE: {
        float s = 0.16f * d, m = fmaxf(fabsf(x), fabsf(y));
        return fabsf(m - s) < t * 0.5f;
    }
    case SYM_TRIANGLE: {
        float ax = 0, ay = -0.2f * d, bx = -0.21f * d, by = 0.15f * d, cx = 0.21f * d, cy = 0.15f * d;
        float e = fminf(seg_dist(x, y, ax, ay, bx, by), fminf(seg_dist(x, y, bx, by, cx, cy), seg_dist(x, y, cx, cy, ax, ay)));
        return e < t * 0.5f;
    }
    case SYM_MENU:  // three bars (Xbox Menu, PlayStation Options)
        for (int k = -1; k <= 1; k++)
            if (fabsf(y - k * 0.12f * d) < 0.04f * d && fabsf(x) < 0.19f * d) return true;
        return false;
    case SYM_VIEW: {  // two overlapping squares (Xbox View, PlayStation Create)
        float s = 0.11f * d, w = 0.035f * d;
        float m1 = fmaxf(fabsf(x + 0.05f * d), fabsf(y + 0.05f * d)), m2 = fmaxf(fabsf(x - 0.05f * d), fabsf(y - 0.05f * d));
        return fabsf(m2 - s) < w || (fabsf(m1 - s) < w && m2 > s + w);
    }
    }
    return false;
}

static void draw_symbol(float *cov, int w, int h, int sym, float cx, float cy, float d) {
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            int in = 0;
            for (int sy = 0; sy < 4; sy++)  // (4 x 4 samples a pixel: smooth edges)
                for (int sx = 0; sx < 4; sx++)
                    in += sym_inside(sym, x + (sx + 0.5f) / 4 - cx, y + (sy + 0.5f) / 4 - cy, d);
            float c = in / 16.0f;
            if (c > cov[y * w + x]) cov[y * w + x] = c;
        }
}

// One cell (upright, w x h) redrawn with `label`: false = a label this can't draw (the cell stays the game's)
static bool redraw(uint8_t *cell, int w, int h, const char *label) {
    static const struct { const char *name; int sym; } syms[] = {
        {"Cross", SYM_CROSS}, {"Circle", SYM_CIRCLE}, {"Square", SYM_SQUARE}, {"Triangle", SYM_TRIANGLE},
        {"Menu", SYM_MENU}, {"Options", SYM_MENU}, {"View", SYM_VIEW}, {"Create", SYM_VIEW},
    };
    static const char *const texts[] = {"A", "B", "X", "Y", "L", "R", "ZL", "ZR", "LB", "RB", "LT", "RT",
                                        "L1", "R1", "L2", "R2"};
    int sym = -1;
    const char *text = NULL;
    for (size_t i = 0; i < sizeof syms / sizeof *syms; i++) if (!strcmp(label, syms[i].name)) sym = syms[i].sym;
    for (size_t i = 0; i < sizeof texts / sizeof *texts; i++) if (!strcmp(label, texts[i])) text = texts[i];
    if (!strcmp(label, "Plus")) text = "+";
    if (!strcmp(label, "Minus")) text = "-";
    if (sym < 0 && !text) return false;
    // the shape: the cell's pixels the outside reaches (dark ones, from the border) keep their value, the rest is
    // filled - the old label's cut-out with it
    int n = w * h;
    uint8_t *ext = calloc((size_t)n, 1);
    int *q = malloc(sizeof(int) * (size_t)n), qh = 0, qt = 0;
    float *cov = calloc((size_t)n, sizeof(float));
    if (!ext || !q || !cov) { free(ext); free(q); free(cov); return false; }
    for (int i = 0; i < n; i++) {
        int x = i % w, y = i / w;
        if ((x == 0 || y == 0 || x == w - 1 || y == h - 1) && cell[i] < 128) ext[i] = 1, q[qt++] = i;
    }
    while (qh < qt) {
        int i = q[qh++], x = i % w, y = i / w;
        static const int dx[4] = {1, -1, 0, 0}, dy[4] = {0, 0, 1, -1};
        for (int k = 0; k < 4; k++) {
            int nx = x + dx[k], ny = y + dy[k];
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            int j = ny * w + nx;
            if (!ext[j] && cell[j] < 128) ext[j] = 1, q[qt++] = j;
        }
    }
    int bx0 = w, by0 = h, bx1 = -1, by1 = -1;
    for (int i = 0; i < n; i++) {
        if (!ext[i]) cell[i] = 255;
        if (cell[i] >= 128) {
            int x = i % w, y = i / w;
            if (x < bx0) bx0 = x;
            if (x > bx1) bx1 = x;
            if (y < by0) by0 = y;
            if (y > by1) by1 = y;
        }
    }
    bool ok = bx1 > bx0 && by1 > by0;
    if (ok) {
        float cx = (bx0 + bx1 + 1) * 0.5f, cy = (by0 + by1 + 1) * 0.5f, bw = (float)(bx1 - bx0 + 1), bh = (float)(by1 - by0 + 1);
        float d = fminf(bw, bh);
        if (sym >= 0) draw_symbol(cov, w, h, sym, cx, cy, d);
        else if (strlen(text) == 1) ok = draw_text(cov, w, h, text, cx, cy, bw * 0.5f, d * (text[0] == '+' || text[0] == '-' ? 0.42f : 0.46f));
        else ok = draw_text(cov, w, h, text, cx, cy, bw * 0.66f, bh * 0.42f);
        for (int i = 0; ok && i < n; i++) cell[i] = (uint8_t)lroundf(cell[i] * (1.0f - cov[i]));
    }
    free(ext);
    free(q);
    free(cov);
    return ok;
}

// The sheet (8-bit, as stored: bottom-up) with the cells for `fam` redrawn; dirty: one byte per 4 x 4 block
static void patch_image(uint8_t *img, uint8_t *dirty, int fam) {
    for (int c = 0; c < NCELLS; c++) {
        const Cell *k = &k_cells[c];
        const char *label = bind_pad_label(bind_prompt_host(k->slot), fam);
        if (!strcmp(label, k->orig)) continue;  // (the game's own picture already)
        int x0 = k->col * CELL_SX, uy0 = k->row * CELL_SY, w = CELL_SX, h = CELL_SY;
        if (x0 + w > SHEET_W) w = SHEET_W - x0;
        uint8_t cell[CELL_SX * CELL_SY];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) cell[y * w + x] = img[(SHEET_H - 1 - (uy0 + y)) * SHEET_W + x0 + x];
        if (!redraw(cell, w, h, label)) continue;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                int Y = SHEET_H - 1 - (uy0 + y);
                img[Y * SHEET_W + x0 + x] = cell[y * w + x];
                dirty[(Y / 4) * (SHEET_W / 4) + (x0 + x) / 4] = 1;
            }
    }
}

void glyphs_patch(uint8_t *blocks, uint32_t wb, uint32_t hb) {
    if (wb * 4 != SHEET_W || hb * 4 != SHEET_H) return;
    int fam = icon_family();
    uint8_t *img = malloc(SHEET_W * SHEET_H), *dirty = calloc(wb * hb, 1);
    if (!img || !dirty) { free(img); free(dirty); return; }
    for (uint32_t by = 0; by < hb; by++)
        for (uint32_t bx = 0; bx < wb; bx++) {
            uint8_t v[16];
            bc4_decode(blocks + (by * wb + bx) * 8, v);
            for (int i = 0; i < 16; i++) img[(by * 4 + i / 4) * SHEET_W + bx * 4 + i % 4] = v[i];
        }
    patch_image(img, dirty, fam);
    int changed = 0;
    for (uint32_t by = 0; by < hb; by++)
        for (uint32_t bx = 0; bx < wb; bx++) {
            if (!dirty[by * wb + bx]) continue;
            uint8_t v[16];
            for (int i = 0; i < 16; i++) v[i] = img[(by * 4 + i / 4) * SHEET_W + bx * 4 + i % 4];
            bc4_encode(v, blocks + (by * wb + bx) * 8);
            changed++;
        }
    static int last_fam = -1, last_changed = -1;
    if (fam != last_fam || changed != last_changed)
        LOG("[glyphs] button pictures: %s (%d blocks redrawn)\n", fam == 1 ? "Xbox" : fam == 2 ? "PlayStation" : "Nintendo", changed);
    last_fam = fam, last_changed = changed;
    free(img);
    free(dirty);
}

void glyphs_selftest(const char *dir) {
    load_ref();
    if (!g_ref) return;
    uint32_t wb = SHEET_W / 4, hb = SHEET_H / 4;
    uint8_t *lin = malloc(wb * hb * 8), *px = malloc(SHEET_W * SHEET_H * 4);
    static const struct { int icons, layout; const char *name; } sets[] = {
        {ICONS_XBOX, FACE_NAME, "xbox"}, {ICONS_XBOX, FACE_POSITION, "xbox_by_position"},
        {ICONS_PLAYSTATION, FACE_NAME, "playstation"}};
    int keep = g_settings.button_icons, keep_layout = g_settings.face_layout;
    for (int set = 0; set < 3 && lin && px; set++) {
        g_settings.button_icons = sets[set].icons;
        g_settings.face_layout = sets[set].layout;
        tegra_deswizzle(g_ref, lin, wb, hb, 1, 8, tegra_default_block_height_log2(hb), 0);
        glyphs_patch(lin, wb, hb);
        for (uint32_t by = 0; by < hb; by++)
            for (uint32_t bx = 0; bx < wb; bx++) {
                uint8_t v[16];
                bc4_decode(lin + (by * wb + bx) * 8, v);
                for (int i = 0; i < 16; i++) {
                    uint32_t y = SHEET_H - 1 - (by * 4 + i / 4), x = bx * 4 + i % 4;  // (upright)
                    uint8_t *o = px + ((size_t)y * SHEET_W + x) * 4;
                    o[0] = o[1] = o[2] = v[i], o[3] = 255;
                }
            }
        char path[1200];
        snprintf(path, sizeof path, "%s/glyphs_%s.png", dir, sets[set].name);
        SDL_Surface *s = SDL_CreateSurfaceFrom(SHEET_W, SHEET_H, SDL_PIXELFORMAT_ABGR8888, px, SHEET_W * 4);
        if (s && SDL_SavePNG(s, path)) LOG("[glyphs] wrote %s\n", path);
        SDL_DestroySurface(s);
    }
    g_settings.button_icons = keep, g_settings.face_layout = keep_layout;
    free(lin);
    free(px);
}

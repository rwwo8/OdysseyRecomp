// The game's button pictures (runtime/nvn/glyphs.c): its button font's sheet, redrawn for the player's controller.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "nvn.h"

// The texture is the button font's sheet (checked once, on its first upload, against the game's own file)
bool glyphs_is_sheet(const NvnTexture *t, const uint8_t *mem, uint64_t size);
// The look the sheet should have now (settings, controller, bindings): a change means upload it again
uint32_t glyphs_generation(void);
// The sheet's blocks (BC4, wb x hb, linear), from the game's own: the pictures that differ are redrawn
void glyphs_patch(uint8_t *blocks, uint32_t wb, uint32_t hb);
// Test: the sheet for each icon set as <dir>/glyphs_<set>.png (upright), from the game's file
void glyphs_selftest(const char *dir);

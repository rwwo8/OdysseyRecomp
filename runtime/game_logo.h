// The game's title logo, read from the player's own game files when the app starts. It is never shipped with the app
// (it is Nintendo's), so a copy without game files set up shows the name as text instead (runtime/ui/launcher.mm).
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// game_dir: the data root's extracted/ (romfs.bin, or a source checkout's romfs/ folder). On success *rgba is a
// malloc'd w*h*4 image (straight alpha, sRGB values), cropped to the logo itself.
bool game_logo_load(const char *game_dir, uint8_t **rgba, int *w, int *h);

#ifdef __cplusplus
}
#endif

// First start: the player's own game files (runtime/ui/setup.mm). Shown before the game boots when the data root
// has no game files yet, or no game code built for this version of the app.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// The game files under root (the data root's extracted/) are Super Mario Odyssey 1.0.0 with their RomFS image (or the
// romfs folder it is made from) and game code built for this version.
bool setup_ready(const char *root);
// The setup page until it's done (true: start the game) or the window is closed (false). Main thread.
bool setup_run(const char *root);
// The same, opened on purpose (the launcher's Game page): SETUP_CHANGE another game folder (with a Back button: true,
// nothing changed), SETUP_REBUILD the game code made again from the files there. SETUP_FIRST: setup_run.
enum { SETUP_FIRST = 0, SETUP_CHANGE = 1, SETUP_REBUILD = 2 };
bool setup_run_mode(const char *root, int mode);
// --setup <folder> (RecompLauncher's Easy Setup: recomplauncher.json "prepare"): the setup page's work without a window,
// "progress <0..1> <step>" lines on stdout. 0 when done, else 2 (the failure's heading and hint printed first).
int setup_headless(const char *root, const char *game);
// Setup mode of the menu (menu.mm): it draws the setup page and takes every input while on.
void menu_setup_mode(bool on);
// The page itself, drawn by the menu while setup mode is on: its fonts (ImFont *; the output scale is set already).
void setup_draw(float scale, void *font, void *font_big);

#ifdef __cplusplus
}
#endif

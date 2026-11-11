// The launcher (runtime/ui/launcher.mm): the start screen before the game boots. The game's own title logo (read from
// the player's files: runtime/game_logo.c) over a row of big tiles - Play, Settings, Controls, Files - made for the
// controller as much as the mouse and keyboard.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Main thread, once the game files are set up: the launcher until Play (true) or Quit / the window closed (false).
// Skipped (true at once) for scripted test runs and ODYSSEY_LAUNCHER=0; ODYSSEY_LAUNCHER=1 shows it even then.
int launcher_run(const char *root);
enum { LAUNCH_QUIT = 0, LAUNCH_PLAY = 1, LAUNCH_CHANGE = 2, LAUNCH_REBUILD = 3 };  // (CHANGE / REBUILD: the Game page)
// Launcher mode of the menu (menu.mm): it draws the launcher and takes every input while on.
void menu_launcher_mode(bool on);
// The page itself, drawn by the menu while launcher mode is on (ImFont *; the output scale is set already).
void launcher_draw(float scale, void *font, void *font_big);

#ifdef __cplusplus
}
// The game's title logo as an ImGui texture (render thread; loaded on first use). 0: not available (no game files yet,
// or macOS), *aspect = width / height.
#include "imgui.h"
ImTextureID launcher_logo(float *aspect);
// The launcher's backdrop (night-teal sky, stars, a planet's rim), also behind the setup page.
void launcher_backdrop(ImDrawList *dl, ImVec2 size, float scale);
#endif

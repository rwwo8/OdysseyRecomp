// User settings (odyssey.ini in the data root), edited from the menu.
#pragma once
#include <stdbool.h>

enum { RES_MATCH = 0, /* 1..8 = 1x..8x */ RES_DYNAMIC = 9, RES_Q75 = 10, RES_Q25 = 11, RES_Q50 = 12,
       // fixed sizes between the multiples (update 43): 720p, 900p (the Switch's own), 1440p, 5K
       RES_720 = 13, RES_900 = 14, RES_1440 = 15, RES_5K = 16 };
// The menu offers fixed sizes only (update 43: Match display and Dynamic removed, the player's wish); an older ini's
// match / dynamic / percentages are read as 1440p / 1440p / 1080p-720p. output_scale.c still knows them all.
#define RES_DEFAULT RES_1440
enum { UPSCALE_BILINEAR = 0, UPSCALE_METALFX = 1 /* macOS */, UPSCALE_FSR1 = 2 /* Windows: AMD FSR 1 */ };
#ifdef __APPLE__
#define UPSCALE_SHARP UPSCALE_METALFX  // each OS's non-bilinear upscaler (the default)
#else
#define UPSCALE_SHARP UPSCALE_FSR1
#endif
enum { AA_OFF = 0, AA_SMAA = 1 };
// The image in a window of another shape: 16:9 with bars, or (Vulkan) filling a wider window with more of the scene
// at the sides (runtime/hle/odyssey_wide.c)
enum { ASPECT_16_9 = 0, ASPECT_FILL = 1 };
// System language served to the game (runtime/services/am.c GetDesiredLanguage, services/hid_set.c GetLanguageCode):
// the game picks its text language from it, as it would from the Switch's own system setting. LANG_AUTO follows the
// host locale ($LC_ALL / $LC_MESSAGES / $LANG); the rest are the codes of the languages the game has text for.
enum { LANG_AUTO = 0, N_LANGUAGES = 12 };
extern const char *const g_language_codes[N_LANGUAGES];  // what the game is told: "ja", "en-US", "es", ...
extern const char *const g_language_names[N_LANGUAGES];  // for the menu ("Auto", "Japanese", ..., "Spanish")

typedef struct {
    bool fullscreen;     // not a window: Borderless or Fullscreen (Video tab "Display mode"; F11 / Alt+Enter toggle it)
    bool borderless;     // ... Borderless: the desktop's own mode, no display mode change (device.c rt_set_fullscreen)
    bool res_chosen;     // (the ini has a resolution: chosen, not the default - device.c lowers the default on iGPUs)
    int res_mode;        // 1..4 (N x 1080p: 1080p, 4K, 6K, 8K), RES_720 / 900 / 1440 / 5K; (older: RES_MATCH, RES_DYNAMIC, RES_Q*)
    int upscaler;        // UPSCALE_*: how a lower internal resolution reaches the window (MetalFX: macOS, FSR 1: Windows)
    int antialias;       // AA_*: anti-aliasing of the game image before it is scaled to the window
    int aspect;          // ASPECT_*: the image in a window wider than 16:9
    bool frame_interp;   // images between the game's frames (Vulkan: runtime/nvn/interp.c)
    bool deband;         // smooth gradients: the game's final picture in half floats, dithered into the window (Vulkan:
                         // nvn/vulkan/textures.c vk_deband)
    float volume;        // master volume, 1 = 100%
    bool reverb;         // the audio renderer's reverb effect
    bool movie_audio;
    bool show_fps;
    bool rumble;         // the controller's vibration (the game's HD rumble: runtime/hle/input.c input_vibration)
    int stick_deadzone;  // percent of a controller stick's travel that counts as rest (runtime/hle/input.c), 0: none
    int language;        // LANG_AUTO or an index into g_language_codes: the game's text language
    int aniso;           // anisotropic filtering of the game's mipmapped textures: 0 = the game's own, else 2..16
    int sharpen;         // FSR 1's sharpening (RCAS): SHARPEN_*
    bool frame_graph;    // a frame time graph under the FPS counter
    int face_layout;     // FACE_*: which controller face button is which Switch button (runtime/hle/bindings.c)
    int button_icons;    // ICONS_*: the game's own button pictures (runtime/nvn/glyphs.c)
    float brightness;    // 1 = as the game: a power curve on the gamma-encoded image (vulkan/exec.c "grade.frag")
    float saturation;    // 1 = as the game, 0 = grey
    bool mouse_camera;   // the mouse turns the camera once captured (runtime/hle/input.c)
    int mouse_sens;      // percent
    bool mouse_invert_y;
} Settings;
// SHARPEN_AUTO: High while FSR 1 scales the image up, none at the display's own resolution (the look before the setting)
enum { SHARPEN_OFF = 0, SHARPEN_LOW = 1, SHARPEN_MEDIUM = 2, SHARPEN_HIGH = 3, SHARPEN_AUTO = 4 };
// FACE_AUTO: by name on Xbox and PlayStation controllers (their A / Cross confirms), by position on the others
enum { FACE_AUTO = 0, FACE_POSITION = 1, FACE_NAME = 2 };
enum { ICONS_AUTO = 0, ICONS_NINTENDO = 1, ICONS_XBOX = 2, ICONS_PLAYSTATION = 3 };

extern Settings g_settings;

void settings_load(void);
void settings_save(void);
// The language code to serve the game ("es", "en-US", ...): the setting, or the host locale for LANG_AUTO
const char *settings_language(void);
// That code's name for the menu ("Spanish")
const char *settings_language_name(void);
// Mods switched off in the menu (runtime/mods.c): their folders, one "mod_off = <folder>" line each
bool settings_mod_off(const char *id);
void settings_set_mod_off(const char *id, bool off);

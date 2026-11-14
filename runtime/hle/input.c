// Controller input: SDL keyboard/gamepad -> nn::hid Npad state.
//
// Both go through the player's bindings (runtime/hle/bindings.c, defaults there: keyboard WASD left stick, arrows
// d-pad, K/J/L/I = A/B/X/Y, Q/E = L/R, 1/3 = ZL/ZR, Enter / Backspace = Plus / Minus, numpad 8/4/5/6 right stick;
// controller by position, Switch A = east).
#include <SDL3/SDL.h>
#include <ctype.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "../hle.h"
#include "../nvn/nvn.h"
#include "../nvn/renderer.h"
#include "../settings.h"
#include "../input_bind.h"
#include "../platform.h"

enum {
    BTN_A = 0, BTN_B, BTN_X, BTN_Y, BTN_LSTICK, BTN_RSTICK, BTN_L, BTN_R, BTN_ZL, BTN_ZR, BTN_PLUS, BTN_MINUS,
    BTN_LEFT, BTN_UP, BTN_RIGHT, BTN_DOWN
};

_Static_assert(BTN_DOWN == BIND_DOWN && BTN_ZL == BIND_ZL, "bindings follow the button bits");

static _Atomic uint64_t key_buttons, pad_buttons;
static _Atomic int32_t key_lx, key_ly, key_rx, key_ry, pad_lx, pad_ly, pad_rx, pad_ry;
static uint8_t keys_down[SDL_SCANCODE_COUNT];
static SDL_Gamepad *pad;
// Two-player mode (0.2.4): the game's own (a second player throws and steers Cappy). Player 1 is the keyboard, the
// mouse and the first controller; player 2 the second controller connected (npad id 1). ODYSSEY_LOG_PAD2=1: its use.
static SDL_Gamepad *pad2;
static _Atomic int64_t sampling;

// Host keys / buttons held by a test script (ODYSSEY_HOST_INPUT, input_frame): they go through the bindings
static uint8_t test_keys[SDL_SCANCODE_COUNT];
static _Atomic uint32_t test_pad;
static _Atomic int32_t test_lx, test_ly;  // (a resting stick's drift: "lstick" in ODYSSEY_HOST_INPUT)
static bool host_test;  // (then a real controller is left out: the player's own pad must not spoil the test)

static int held_key(int sc) { return sc > 0 && sc < SDL_SCANCODE_COUNT && (keys_down[sc] || test_keys[sc]); }

// The mouse (Controls tab "Mouse"): a click in the game's window captures it (relative mode: the pointer hidden and
// held); its movement turns the camera as the right stick would, its buttons go through g_bind_mouse. The menu, the
// window losing the focus or the setting off let it go; a click captures it again.
static _Atomic bool mouse_want, mouse_held;  // (asked by a click / captured now: input_mouse_update)
static _Atomic int32_t mouse_ax, mouse_ay;   // movement since the stick was last worked out, 1/16 pixel
static uint8_t mouse_down[8];
static bool held_mouse(int b) { return mouse_held && b > 0 && b < 8 && mouse_down[b]; }
static int32_t clamp_axis(int32_t v);
extern bool menu_input_captured(void);  // runtime/ui/menu.mm: overlay menu or name entry up (it has the keys / pad)

// Through the bindings (runtime/hle/bindings.c: g_bind_key), read on every key event, so a rebind applies at once.
static _Atomic bool key_shake, pad_shake;  // (the Shake binding held: input_motion)
static void recompute_keyboard(void) {
    uint64_t b = 0;
    for (int i = 0; i < BIND_PAD_COUNT; i++)
        if (held_key(g_bind_key[i]) || held_mouse(g_bind_mouse[i])) b |= 1ull << i;
    key_shake = (b >> BIND_SHAKE) & 1;
    key_buttons = b & ~(1ull << BIND_SHAKE);
    key_lx = (held_key(g_bind_key[BIND_LS_RIGHT]) - held_key(g_bind_key[BIND_LS_LEFT])) * 32767;
    key_ly = (held_key(g_bind_key[BIND_LS_UP]) - held_key(g_bind_key[BIND_LS_DOWN])) * 32767;
    key_rx = (held_key(g_bind_key[BIND_RS_RIGHT]) - held_key(g_bind_key[BIND_RS_LEFT])) * 32767;
    key_ry = (held_key(g_bind_key[BIND_RS_UP]) - held_key(g_bind_key[BIND_RS_DOWN])) * 32767;
}

// The Controls tab's stick deadzone (g_settings.stick_deadzone, percent): inside that circle a stick is at rest, the
// travel outside it is stretched to the full range (round: a diagonal keeps its direction). The SDL gamepad is read
// directly, so a deadzone set elsewhere (Steam Input's) doesn't apply.
static void deadzone(int32_t *x, int32_t *y) {
    float dz = g_settings.stick_deadzone / 100.0f;
    if (dz <= 0) return;
    float fx = *x / 32767.0f, fy = *y / 32767.0f, r = sqrtf(fx * fx + fy * fy);
    if (r <= dz) { *x = *y = 0; return; }
    float k = fminf((r - dz) / (1 - dz), 1) / r;
    *x = (int32_t)lroundf(fx * k * 32767), *y = (int32_t)lroundf(fy * k * 32767);
}

// Controller buttons (and the triggers as buttons) -> Switch buttons through g_bind_pad; the sticks stay the sticks.
static void recompute_pad(void) {
    uint32_t host = test_pad;
    if (pad && !host_test) {
        for (int i = 0; i < SDL_GAMEPAD_BUTTON_COUNT; i++)
            if (SDL_GetGamepadButton(pad, (SDL_GamepadButton)i)) host |= 1u << i;
        if (SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) > 16000) host |= 1u << PADB_LTRIGGER;
        if (SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) > 16000) host |= 1u << PADB_RTRIGGER;
    }
    uint64_t b = 0;
    int hosts[BIND_PAD_COUNT];
    bool names = bind_names_layout();  // (Controls tab "Button layout": bindings.c)
    for (int i = 0; i < BIND_PAD_COUNT; i++) hosts[i] = names ? bind_face_swap(g_bind_pad[i]) : g_bind_pad[i];
    for (int i = 0; i < BIND_PAD_COUNT; i++)
        if (hosts[i] >= 0 && hosts[i] < PADB_HOST_COUNT && (host >> hosts[i] & 1)) b |= 1ull << i;
    pad_shake = (b >> BIND_SHAKE) & 1;
    pad_buttons = b & ~(1ull << BIND_SHAKE);
    if (!pad || host_test) { pad_lx = test_lx, pad_ly = test_ly, pad_rx = pad_ry = 0; return; }
    int32_t x = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTX), y = -SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_LEFTY);
    deadzone(&x, &y);
    pad_lx = x, pad_ly = y;
    x = SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTX), y = -SDL_GetGamepadAxis(pad, SDL_GAMEPAD_AXIS_RIGHTY);
    deadzone(&x, &y);
    pad_rx = x, pad_ry = y;
}

// Forget held keys (the menu took focus); the gamepad is re-read on its next event.
void input_reset(void) {
    memset(keys_down, 0, sizeof keys_down);
    recompute_keyboard();
}

volatile int g_debug_frame_request;  // F9: dump the next frame's passes (build/pass_*.png) + draw log
volatile long g_f9_shot;  // F9: the frame whose real image and in-between are saved (vulkan/device.c)

// Events a test pushes (ODYSSEY_HOST_INPUT type: / sdlkey: / sdlpad:) carry this device id: they go the whole way, menu first.
#define TEST_DEVICE 0x7E57u
static bool test_event(const SDL_Event *e) {
    switch (e->type) {
    case SDL_EVENT_KEY_DOWN: case SDL_EVENT_KEY_UP: return e->key.which == TEST_DEVICE;
    case SDL_EVENT_TEXT_INPUT: return e->text.windowID == TEST_DEVICE;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: return e->gbutton.which == TEST_DEVICE;
    default: return false;
    }
}

// Scripted test runs ignore the user's own input (a key or stick touched while a test drives Link spoils it):
// ODYSSEY_NO_USER_INPUT=1, on by default whenever ODYSSEY_INPUT / ODYSSEY_DOORJUMP_TEST / ODYSSEY_PLACE is set
// (or ODYSSEY_HOST_INPUT / ODYSSEY_BIND_TEST; ODYSSEY_NO_USER_INPUT=0 lets it through again).
bool input_user_blocked(const SDL_Event *e) {
    static int on = -1;
    if (on < 0) {
        const char *v = getenv("ODYSSEY_NO_USER_INPUT");
        on = v ? atoi(v) != 0 : (getenv("ODYSSEY_INPUT") || getenv("ODYSSEY_DOORJUMP_TEST") || getenv("ODYSSEY_PLACE") ||
                                 getenv("ODYSSEY_HOST_INPUT") || getenv("ODYSSEY_BIND_TEST"));
        if (on) LOG("[input] scripted run: keyboard, mouse and controllers ignored\n");
    }
    if (!on) return false;
    if (test_event(e)) return false;  // (ODYSSEY_HOST_INPUT type: / sdlkey: / sdlpad: - the test's own presses)
    switch (e->type) {
    case SDL_EVENT_KEY_DOWN: case SDL_EVENT_KEY_UP: case SDL_EVENT_TEXT_INPUT: case SDL_EVENT_TEXT_EDITING:
    case SDL_EVENT_MOUSE_MOTION: case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
    case SDL_EVENT_MOUSE_WHEEL:
    case SDL_EVENT_GAMEPAD_ADDED: case SDL_EVENT_GAMEPAD_AXIS_MOTION: case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
    case SDL_EVENT_GAMEPAD_BUTTON_UP: case SDL_EVENT_JOYSTICK_ADDED: case SDL_EVENT_JOYSTICK_AXIS_MOTION:
    case SDL_EVENT_JOYSTICK_BUTTON_DOWN: case SDL_EVENT_JOYSTICK_BUTTON_UP:
        return true;
    default:
        return false;
    }
}

// Controller family for the button prompts (runtime/nvn/texpatch.c): 0 Nintendo / other / none, 1 Xbox, 2 PlayStation.
// ODYSSEY_PAD_TYPE=xbox|playstation|nintendo pretends one is attached (tests).
static _Atomic int pad_family;
static void note_family(void) {
    int f = 0;
    if (pad) switch (SDL_GetGamepadType(pad)) {
        case SDL_GAMEPAD_TYPE_XBOX360: case SDL_GAMEPAD_TYPE_XBOXONE: f = 1; break;
        case SDL_GAMEPAD_TYPE_PS3: case SDL_GAMEPAD_TYPE_PS4: case SDL_GAMEPAD_TYPE_PS5: f = 2; break;
        default: break;
    }
    if (f != pad_family) LOG("[input] button prompts: %s controller\n", f == 1 ? "Xbox" : f == 2 ? "PlayStation" : "Nintendo / other");
    pad_family = f;
}
int input_pad_family(void) {
    static int env = -2;
    if (env == -2) {
        const char *e = getenv("ODYSSEY_PAD_TYPE");
        env = !e ? -1 : !strcmp(e, "xbox") ? 1 : !strcmp(e, "playstation") || !strcmp(e, "ps") ? 2 : 0;
    }
    return env >= 0 ? env : pad_family;
}

void input_handle_event(const SDL_Event *e) {
    static bool scanned;  // pads present at startup: their ADDED event may have gone to the start screen's loop
    if (!scanned) {
        scanned = true;
        int n = 0;
        SDL_JoystickID *ids = SDL_GetGamepads(&n);
        if (n > 0 && !pad) { pad = SDL_OpenGamepad(ids[0]); LOG("[input] gamepad: %s\n", SDL_GetGamepadName(pad)); note_family(); }
        if (n > 1 && !pad2) { pad2 = SDL_OpenGamepad(ids[1]); LOG("[input] player 2 gamepad: %s\n", SDL_GetGamepadName(pad2)); }
        SDL_free(ids);
    }
    switch (e->type) {
    case SDL_EVENT_KEY_DOWN: case SDL_EVENT_KEY_UP:
        if (e->type == SDL_EVENT_KEY_DOWN && e->key.scancode == SDL_SCANCODE_F9 && !e->key.repeat) g_debug_frame_request = 1;
        if (e->key.scancode < SDL_SCANCODE_COUNT) keys_down[e->key.scancode] = e->type == SDL_EVENT_KEY_DOWN;
        recompute_keyboard();
        break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
        if (!mouse_held) {  // (a click in the window: the mouse is the game's from now on - this click itself does nothing)
            if (e->type == SDL_EVENT_MOUSE_BUTTON_DOWN && g_settings.mouse_camera) mouse_want = true;
            break;
        }
        if (e->button.button < 8) mouse_down[e->button.button] = e->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
        recompute_keyboard();
        break;
    case SDL_EVENT_MOUSE_MOTION:
        if (mouse_held) {
            mouse_ax += (int32_t)lroundf(e->motion.xrel * 16);
            mouse_ay += (int32_t)lroundf(e->motion.yrel * 16);
        }
        break;
    case SDL_EVENT_WINDOW_FOCUS_LOST:
        mouse_want = false;
        break;
    case SDL_EVENT_GAMEPAD_ADDED:
        if (!pad) { pad = SDL_OpenGamepad(e->gdevice.which); LOG("[input] gamepad: %s\n", SDL_GetGamepadName(pad)); note_family(); }
        else if (!pad2 && SDL_GetGamepadID(pad) != e->gdevice.which) {
            pad2 = SDL_OpenGamepad(e->gdevice.which);
            LOG("[input] player 2 gamepad: %s\n", SDL_GetGamepadName(pad2));
        }
        break;
    case SDL_EVENT_GAMEPAD_REMOVED:
        if (pad2 && SDL_GetGamepadID(pad2) == e->gdevice.which) { SDL_CloseGamepad(pad2); pad2 = NULL; }
        if (pad && SDL_GetGamepadID(pad) == e->gdevice.which) {
            SDL_CloseGamepad(pad);
            pad = pad2, pad2 = NULL;  // (the second one carries on as player 1)
            note_family();
        }
        recompute_pad();
        break;
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP:
        recompute_pad();
        break;
    }
}

// Main thread, each turn of the event loop: the mouse captured while it should be (a click asked for it, the setting
// on, the window focused, no menu over the game), let go otherwise.
void input_mouse_update(SDL_Window *w) {
    extern bool menu_input_captured(void);
    bool want = mouse_want && g_settings.mouse_camera && w && (SDL_GetWindowFlags(w) & SDL_WINDOW_INPUT_FOCUS) &&
                !menu_input_captured();
    if (!g_settings.mouse_camera) mouse_want = false;
    if (want == mouse_held) return;
    SDL_SetWindowRelativeMouseMode(w, want);
    mouse_held = want;
    memset(mouse_down, 0, sizeof mouse_down);
    mouse_ax = mouse_ay = 0;
    recompute_keyboard();
    LOG("[input] mouse %s\n", want ? "captured (camera, buttons)" : "released");
}

// The mouse's movement as a right stick: its speed over the last few milliseconds, 600 pixels a second at 100%
// sensitivity = the stick all the way (faster turns the camera no faster: the game's own top speed)
// Past full tilt (a fast flick, or a high sensitivity): the rest turns the camera directly (camera_stick_hook), so the
// mouse isn't held to the stick's top speed (GitHub #10: "too slow even at the highest sensitivity").
static _Atomic float mouse_extra_x, mouse_extra_y;  // (stick units past full tilt, 1.0 = one more full tilt)
static void mouse_stick(int32_t *rx, int32_t *ry) {
    static uint64_t last;
    static double vx, vy;
    if (!mouse_held) { *rx = *ry = 0; last = 0; mouse_extra_x = mouse_extra_y = 0; return; }
    uint64_t now = plat_now_ns();
    if (!last) last = now;
    double ms = (now - last) / 1e6;
    if (ms >= 4) {
        double k = g_settings.mouse_sens / 100.0 * 32767.0 / 600.0 * 1000.0 / ms / 16.0;
        int32_t ax = atomic_exchange(&mouse_ax, 0), ay = atomic_exchange(&mouse_ay, 0);
        double nx = ax * k, ny = -ay * k;
        if (g_settings.mouse_invert_y) ny = -ny;
        vx = (vx + nx) / 2, vy = (vy + ny) / 2;  // (two windows' average: steadier at a high polling rate)
        if (!ax && !ay && fabs(vx) < 400 && fabs(vy) < 400) vx = vy = 0;
        last = now;
        mouse_extra_x = (float)((vx - clamp_axis((int32_t)lround(vx))) / 32767.0);
        mouse_extra_y = (float)((vy - clamp_axis((int32_t)lround(vy))) / 32767.0);
    }
    *rx = clamp_axis((int32_t)lround(vx)), *ry = clamp_axis((int32_t)lround(vy));
}

// The camera's stick (ProjectCameraInput / al::SimpleCameraInput::calcInputStick(sead::Vector2f *out)): the game's
// value, plus the mouse past full tilt.
static GuestFn g_cam_stick[2];
static void camera_stick_call(Cpu *c, int which) {
    uint64_t out = c->x[1];
    static bool told[2];
    if (!told[which]) { told[which] = true; LOG("[input] the camera's stick read through the mouse hook (%s)\n", which ? "SimpleCameraInput" : "ProjectCameraInput"); }
    g_cam_stick[which](c);
    float ex = mouse_extra_x, ey = mouse_extra_y;
    if (out && (ex != 0 || ey != 0) && !menu_input_captured()) {
        float *v = (float *)(uintptr_t)out;
        v[0] += ex, v[1] += ey;
    }
}
static void camera_stick_project(Cpu *c) { camera_stick_call(c, 0); }
static void camera_stick_simple(Cpu *c) { camera_stick_call(c, 1); }
void input_camera_hooks(void) {
    static bool done;
    if (done) return;
    done = true;
    static const char *const names[2] = {"_ZNK18ProjectCameraInput14calcInputStickEPN4sead7Vector2IfEE",
                                         "_ZNK2al17SimpleCameraInput14calcInputStickEPN4sead7Vector2IfEE"};
    HostFn fns[2] = {camera_stick_project, camera_stick_simple};
    for (int i = 0; i < 2; i++) {
        uint64_t a = loader_find_symbol(names[i]);
        if (!a) continue;
        g_cam_stick[i] = dispatch_lookup(a);
        hle_override(a, fns[i], i ? "SimpleCameraInput::calcInputStick (mouse)" : "ProjectCameraInput::calcInputStick (mouse)");
    }
}

// Scripted input for testing: ODYSSEY_INPUT="frame:BUTTON:frames,..." (BUTTON = A,B,X,Y,L,R,ZL,ZR,PLUS,
// MINUS,LEFT,UP,RIGHT,DOWN, or STICK_UP/DOWN/LEFT/RIGHT, RSTICK_UP/DOWN/LEFT/RIGHT, STICK_<degrees>: full tilt at
// that angle, 0 = right, 90 = up).
static _Atomic uint64_t script_buttons;
static _Atomic int32_t script_lx, script_ly, script_rx, script_ry;

// Tests of the bindings, through them like a real player:
// ODYSSEY_HOST_INPUT="frame:key:<SDL key name>:frames,frame:pad:<button>:frames,..." holds a host key / controller
//   button (names as in odyssey.ini's bind_* lines: "Z", "Keypad 0", "south", "ltrigger"...);
//   "frame:lstick:<x>/<y>:frames" holds the controller's left stick there (raw SDL units, y up: a drifting stick).
// "frame:type:<text>" types <text> as real key events (down, text, up per character), through the overlay menu / name
//   entry first like a player's typing; "{Escape}" (any SDL key name) presses that key. No ',' or ':' in <text>.
// "frame:sdlpad:<button>:frames" / "frame:sdlkey:<key>:frames" hold a controller button / key as real events (down
//   at frame, up `frames` later): they reach menus and the on-screen keyboard first, as a player's would.
// "frame:shot:<name>" saves the window (game + menus) to build/<name>.png.
// ODYSSEY_BIND_TEST="frame:pad|key:<input>:<host>,..." starts a rebind capture of <input> (bind_* name: a, zl,
//   ls_up...) at that frame (the Controls tab shows it waiting) and presses <host> 90 frames later ("esc" cancels,
//   "wait" lets it time out); "frame:reset:pad|key" resets to the defaults.
static void push_key(SDL_Scancode sc, SDL_Keymod mod, bool down) {
    SDL_Event e;
    memset(&e, 0, sizeof e);
    e.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    e.key.which = TEST_DEVICE, e.key.scancode = sc, e.key.mod = mod, e.key.down = down;
    e.key.key = SDL_GetKeyFromScancode(sc, mod, false);
    SDL_PushEvent(&e);
}
char g_window_shot_request[256];  // test script "shot": a path for the next presented frame
static void test_push(uint64_t frame, unsigned long start, unsigned long len, const char *dev, const char *arg) {
    SDL_Event e;
    memset(&e, 0, sizeof e);
    if (!strcmp(dev, "shot")) {
        extern char g_window_shot_request[256];  // (the macOS renderer saves the next frame there)
        if (frame == start) snprintf(g_window_shot_request, sizeof g_window_shot_request, "build/%s.png", arg);
        return;
    }
    if (!strcmp(dev, "sdlkey")) {
        if (frame == start || frame == start + len) push_key(SDL_GetScancodeFromName(arg), SDL_KMOD_NONE, frame == start);
        return;
    }
    if (!strcmp(dev, "sdlpad")) {
        int b = bind_pad_from_name(arg);
        if (b < 0 || b >= SDL_GAMEPAD_BUTTON_COUNT || (frame != start && frame != start + len)) return;
        e.type = frame == start ? SDL_EVENT_GAMEPAD_BUTTON_DOWN : SDL_EVENT_GAMEPAD_BUTTON_UP;
        e.gbutton.which = TEST_DEVICE, e.gbutton.button = (Uint8)b, e.gbutton.down = frame == start;
        SDL_PushEvent(&e);
        return;
    }
    if (frame != start) return;
    LOG("[input] test: typing \"%s\"\n", arg);
    static char ascii[128][2];  // (a text event keeps a pointer to its text: these live on)
    for (const char *p = arg; *p; p++) {
        if (*p == '{' && strchr(p, '}')) {  // a named key
            char nm[32];
            size_t n = (size_t)(strchr(p, '}') - p - 1);
            snprintf(nm, sizeof nm, "%.*s", (int)(n < sizeof nm ? n : sizeof nm - 1), p + 1);
            SDL_Scancode sc = SDL_GetScancodeFromName(nm);
            push_key(sc, SDL_KMOD_NONE, true), push_key(sc, SDL_KMOD_NONE, false);
            p += n + 1;
            continue;
        }
        SDL_Keymod mod = SDL_KMOD_NONE;
        SDL_Scancode sc = SDL_GetScancodeFromKey((SDL_Keycode)tolower((unsigned char)*p), &mod);
        if (isupper((unsigned char)*p)) mod |= SDL_KMOD_LSHIFT;
        push_key(sc, mod, true);
        int c = *p & 0x7f;
        ascii[c][0] = (char)c;
        memset(&e, 0, sizeof e);
        e.type = SDL_EVENT_TEXT_INPUT, e.text.windowID = TEST_DEVICE, e.text.text = ascii[c];
        SDL_PushEvent(&e);
        push_key(sc, mod, false);
    }
}

static void host_test_frame(uint64_t frame) {
    static const char *hspec, *bspec;
    static int init;
    if (!init) { init = 1; hspec = getenv("ODYSSEY_HOST_INPUT"); bspec = getenv("ODYSSEY_BIND_TEST"); host_test = hspec; }
    char buf[2048];
    if (hspec) {
        uint8_t keys[SDL_SCANCODE_COUNT] = {0};
        uint32_t padm = 0;
        int32_t sx = 0, sy = 0;
        snprintf(buf, sizeof buf, "%s", hspec);
        char *save = NULL;
        for (char *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
            unsigned long start = 0, len = 10;
            char dev[8] = "", name[400] = "";
            if (sscanf(tok, "%lu:%7[a-z]:%399[^:]:%lu", &start, dev, name, &len) < 3) continue;
            if (!strcmp(dev, "type") || !strcmp(dev, "sdlpad") || !strcmp(dev, "sdlkey") || !strcmp(dev, "shot")) {
                test_push(frame, start, len, dev, name);
                continue;
            }
            if (frame < start || frame >= start + len) continue;
            if (!strcmp(dev, "key")) { SDL_Scancode sc = SDL_GetScancodeFromName(name); if (sc) keys[sc] = 1; }
            else if (!strcmp(dev, "lstick")) sscanf(name, "%d/%d", &sx, &sy);
            else { int h = bind_pad_from_name(name); if (h >= 0) padm |= 1u << h; }
        }
        bool kch = memcmp(keys, test_keys, sizeof keys) != 0, pch = padm != test_pad || sx != test_lx || sy != test_ly;
        memcpy(test_keys, keys, sizeof keys);
        test_pad = padm;
        test_lx = sx, test_ly = sy;
        if (kch) recompute_keyboard();
        if (pch) recompute_pad();
    }
    if (bspec) {
        snprintf(buf, sizeof buf, "%s", bspec);
        char *save = NULL;
        for (char *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
            unsigned long start = 0;
            char dev[8] = "", in[16] = "", host[40] = "";
            if (sscanf(tok, "%lu:%7[a-z]:%15[a-z_]:%39[^:]", &start, dev, in, host) < 3) continue;
            if (!strcmp(dev, "reset")) { if (frame == start) bind_reset(!strcmp(in, "key") ? BIND_DEV_KEY : BIND_DEV_PAD); continue; }
            int d = !strcmp(dev, "key") ? BIND_DEV_KEY : BIND_DEV_PAD;
            if (frame == start) {
                LOG("[input] test: capture %s %s\n", dev, in);
                bind_capture_begin(d, bind_slot_from_name(in));
            }
            if (frame == start + 90 && strcmp(host, "wait")) {
                SDL_Event e;
                memset(&e, 0, sizeof e);
                if (!strcmp(host, "esc") || d == BIND_DEV_KEY) {
                    e.type = SDL_EVENT_KEY_DOWN;
                    e.key.scancode = !strcmp(host, "esc") ? SDL_SCANCODE_ESCAPE : SDL_GetScancodeFromName(host);
                } else {
                    int h = bind_pad_from_name(host);
                    if (h >= PADB_LTRIGGER) {
                        e.type = SDL_EVENT_GAMEPAD_AXIS_MOTION;
                        e.gaxis.axis = h == PADB_LTRIGGER ? SDL_GAMEPAD_AXIS_LEFT_TRIGGER : SDL_GAMEPAD_AXIS_RIGHT_TRIGGER;
                        e.gaxis.value = 32767;
                    } else {
                        e.type = SDL_EVENT_GAMEPAD_BUTTON_DOWN;
                        e.gbutton.button = (Uint8)h;
                    }
                }
                bind_capture_event(&e);
            }
        }
    }
}

static uint64_t g_pad_obj;
volatile int g_inject_plus;  // frames to hold Plus for the game (movie.c: A/B skip the opening on rando seeds)
RT_ON_RESET(input_reboot_reset) { g_pad_obj = 0; g_inject_plus = 0; }  // (reboot: the controller object was guest memory)
void input_frame(uint64_t frame) {
    if (g_pad_obj && getenv("ODYSSEY_DUMP_PAD") && frame % 600 == 0) {
        const uint8_t *m = (const uint8_t *)(uintptr_t)(g_pad_obj - 0x98);
        LOG("[pad] mgr %llx 4e0=%u 4e4=%u 4e8=%u 548=%#x 54c..=%02x %02x %02x 56c=%02x\n", g_pad_obj - 0x98,
            *(uint32_t *)(m + 0x4e0), *(uint32_t *)(m + 0x4e4), *(uint32_t *)(m + 0x4e8), *(uint32_t *)(m + 0x548),
            m[0x54c], m[0x54d], m[0x54e], m[0x56c]);
        for (int i = 0; i < 9; i++) {
            const uint8_t *o = m + 0x98 + 0x48 * i;
            uint64_t player = *(uint64_t *)(m + 0x10 * i);
            LOG("[pad]  ctl%d id %#x style %#x btn %#x conn %d %d | player %llx [8]=%u\n", i, *(uint32_t *)(o + 8),
                *(uint32_t *)(o + 0xc), *(uint32_t *)(o + 0x14), o[0x44], o[0x45], player,
                player ? *(uint32_t *)(uintptr_t)(player + 8) : 0);
        }
    }
    extern void watch_arm(void);
    watch_arm();
    host_test_frame(frame);
    const char *spec = getenv("ODYSSEY_INPUT");
    if (!spec) return;
    static const char *const names[] = {"A", "B", "X", "Y", "LSTICK", "RSTICK", "L", "R", "ZL", "ZR", "PLUS",
                                        "MINUS", "LEFT", "UP", "RIGHT", "DOWN"};
    uint64_t b = 0;
    int32_t lx = 0, ly = 0, rx = 0, ry = 0;
    static char buf[16384];  // (long scripted sessions: the perf walk is ~4 KB)
    snprintf(buf, sizeof buf, "%s", spec);
    for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
        unsigned long start = 0, len = 10;
        char name[32] = "";
        if (sscanf(tok, "%lu:%31[A-Z_0-9]:%lu", &start, name, &len) < 2) continue;
        if (frame < start || frame >= start + len) continue;
        if (!strcmp(name, "STICK_UP")) ly = 32767;
        else if (!strcmp(name, "STICK_DOWN")) ly = -32767;
        else if (!strcmp(name, "STICK_LEFT")) lx = -32767;
        else if (!strcmp(name, "STICK_RIGHT")) lx = 32767;
        else if (!strcmp(name, "RSTICK_UP")) ry = 32767;
        else if (!strcmp(name, "RSTICK_DOWN")) ry = -32767;
        else if (!strcmp(name, "RSTICK_LEFT")) rx = -32767;
        else if (!strcmp(name, "RSTICK_RIGHT")) rx = 32767;
        else if (!strncmp(name, "STICK_", 6) && name[6] >= '0' && name[6] <= '9') {
            double r = atoi(name + 6) * 3.14159265358979 / 180;
            lx = (int32_t)lround(cos(r) * 32767), ly = (int32_t)lround(sin(r) * 32767);
        }
        for (int i = 0; i < 16; i++) if (!strcmp(name, names[i])) b |= 1ull << i;
    }
    script_buttons = b;
    script_lx = lx;
    script_ly = ly;
    script_rx = rx;
    script_ry = ry;
}


// Buttons held right now (keyboard, gamepad, test script), independent of whether the game polls (movies).
uint64_t input_buttons_now(void) { return (menu_input_captured() ? 0 : key_buttons | pad_buttons) | script_buttons; }

static int32_t clamp_axis(int32_t v) { return v > 32767 ? 32767 : v < -32767 ? -32767 : v; }

// Player 2's state (npad id 1): the second controller through the same bindings.
static void fill_state_p2(uint8_t *s) {
    SDL_Gamepad *p = pad2;
    if (!p || host_test || menu_input_captured()) return;
    uint32_t host = 0;
    for (int i = 0; i < SDL_GAMEPAD_BUTTON_COUNT; i++)
        if (SDL_GetGamepadButton(p, (SDL_GamepadButton)i)) host |= 1u << i;
    if (SDL_GetGamepadAxis(p, SDL_GAMEPAD_AXIS_LEFT_TRIGGER) > 16000) host |= 1u << PADB_LTRIGGER;
    if (SDL_GetGamepadAxis(p, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) > 16000) host |= 1u << PADB_RTRIGGER;
    uint64_t b = 0;
    bool names = bind_names_layout();
    for (int i = 0; i < BIND_PAD_COUNT; i++) {
        int h = names ? bind_face_swap(g_bind_pad[i]) : g_bind_pad[i];
        if (i != BIND_SHAKE && h >= 0 && h < PADB_HOST_COUNT && (host >> h & 1)) b |= 1ull << i;
    }
    int32_t lx = SDL_GetGamepadAxis(p, SDL_GAMEPAD_AXIS_LEFTX), ly = -SDL_GetGamepadAxis(p, SDL_GAMEPAD_AXIS_LEFTY);
    int32_t rx = SDL_GetGamepadAxis(p, SDL_GAMEPAD_AXIS_RIGHTX), ry = -SDL_GetGamepadAxis(p, SDL_GAMEPAD_AXIS_RIGHTY);
    deadzone(&lx, &ly);
    deadzone(&rx, &ry);
    lx = clamp_axis(lx), ly = clamp_axis(ly), rx = clamp_axis(rx), ry = clamp_axis(ry);
    if (lx < -16000) b |= 1ull << 16;
    if (ly > 16000) b |= 1ull << 17;
    if (lx > 16000) b |= 1ull << 18;
    if (ly < -16000) b |= 1ull << 19;
    if (rx < -16000) b |= 1ull << 20;
    if (ry > 16000) b |= 1ull << 21;
    if (rx > 16000) b |= 1ull << 22;
    if (ry < -16000) b |= 1ull << 23;
    *(uint64_t *)(s + 8) = b;
    *(int32_t *)(s + 16) = lx;
    *(int32_t *)(s + 20) = ly;
    *(int32_t *)(s + 24) = rx;
    *(int32_t *)(s + 28) = ry;
    *(uint32_t *)(s + 32) = 1;  // IsConnected
    static int log = -1;
    if (log < 0) log = getenv("ODYSSEY_LOG_PAD2") != NULL;
    static uint64_t last;
    if (log && b != last) LOG("[input] player 2 buttons %#llx\n", (unsigned long long)b);
    last = b;
}

// NpadFullKeyState / NpadHandheldState / NpadJoy*State share this layout (0x28 bytes):
// {int64 sampling, u64 buttons, AnalogStick L {x,y}, AnalogStick R {x,y}, u32 attributes}
static void fill_state(Cpu *c) {
    uint8_t *s = (uint8_t *)(uintptr_t)c->x[0];
    uint32_t id = *(uint32_t *)(uintptr_t)c->x[1];
    memset(s, 0, 0x28);
    *(int64_t *)s = ++sampling;
    static int nlog;
    if (nlog < 6 && (sampling % 600) == 1) { nlog++; LOG("[input] GetNpadState id %#x lr %llx\n", id, c->x[30]); }
    if (id == 1) { fill_state_p2(s); return; }  // (two-player mode: the second controller)
    if (id != 0) return;  // docked: player 1 (FullKey); Handheld stays disconnected
    extern uint64_t g_watch_lo, g_watch_hi;
    if (id == 0 && !g_pad_obj) g_pad_obj = c->x[1] - 8;
    if (id == 0 && !g_watch_lo && getenv("ODYSSEY_WATCH_PAD")) {
        unsigned lo = 0x98 + 0x10, hi = 0x98 + 0x48;  // offsets from the controller manager
        sscanf(getenv("ODYSSEY_WATCH_PAD"), "%x,%x", &lo, &hi);
        g_watch_lo = c->x[1] - 8 - 0x98 + lo;
        g_watch_hi = c->x[1] - 8 - 0x98 + hi;
        LOG("[input] watching controller object %llx\n", c->x[1] - 8);
    }
    bool menu = menu_input_captured();  // the overlay menu / name entry has the controls (typing there isn't for the game)
    uint64_t b = menu ? script_buttons : key_buttons | pad_buttons | script_buttons;
    {   // injected Plus: held for ~10 presented frames (the game polls several times per frame)
        extern uint64_t renderer_present_count(void);
        static uint64_t until;
        if (g_inject_plus > 0) { until = renderer_present_count() + 10; g_inject_plus = 0; }
        if (renderer_present_count() < until) b |= 1ull << BTN_PLUS;
    }
    int32_t lx = clamp_axis((menu ? 0 : key_lx + pad_lx) + script_lx), ly = clamp_axis((menu ? 0 : key_ly + pad_ly) + script_ly);
    int32_t mrx = 0, mry = 0;
    if (!menu) mouse_stick(&mrx, &mry);
    int32_t rx = clamp_axis((menu ? 0 : key_rx + pad_rx + mrx) + script_rx), ry = clamp_axis((menu ? 0 : key_ry + pad_ry + mry) + script_ry);
    // stick directions also appear as buttons (bits 16-23)
    if (lx < -16000) b |= 1ull << 16;
    if (ly > 16000) b |= 1ull << 17;
    if (lx > 16000) b |= 1ull << 18;
    if (ly < -16000) b |= 1ull << 19;
    if (rx < -16000) b |= 1ull << 20;
    if (ry > 16000) b |= 1ull << 21;
    if (rx > 16000) b |= 1ull << 22;
    if (ry < -16000) b |= 1ull << 23;
    *(uint64_t *)(s + 8) = b;
    static uint64_t last_b;
    if (b != last_b && getenv("ODYSSEY_INPUT")) LOG("[input] id %#x buttons %#llx (sampling %lld, lr %llx)\n", id, (unsigned long long)b, (long long)sampling, c->x[30]);
    last_b = b;
    *(int32_t *)(s + 16) = lx;
    *(int32_t *)(s + 20) = ly;
    *(int32_t *)(s + 24) = rx;
    *(int32_t *)(s + 28) = ry;
    *(uint32_t *)(s + 32) = 1;  // IsConnected
}

HLE_FUNC("_ZN2nn3hid12GetNpadStateEPNS0_16NpadFullKeyStateERKj", hid_state_fullkey) { fill_state(c); }
HLE_FUNC("_ZN2nn3hid12GetNpadStateEPNS0_16NpadJoyDualStateERKj", hid_state_dual) { fill_state(c); }
HLE_FUNC("_ZN2nn3hid12GetNpadStateEPNS0_16NpadJoyLeftStateERKj", hid_state_left) { fill_state(c); }
HLE_FUNC("_ZN2nn3hid12GetNpadStateEPNS0_17NpadHandheldStateERKj", hid_state_handheld) { fill_state(c); }
HLE_FUNC("_ZN2nn3hid12GetNpadStateEPNS0_17NpadJoyRightStateERKj", hid_state_right) { fill_state(c); }

// GetNpadStates(State *out, int count, const NpadIdType &id) -> how many it wrote, newest first (Odyssey): the newest
// state only - each call has a new sampling number, so the game sees a fresh sample every poll.
static void fill_states(Cpu *c) {
    if ((int32_t)c->x[1] < 1) { c->x[0] = 0; return; }
    c->x[1] = c->x[2];
    fill_state(c);
    c->x[0] = 1;
}
HLE_FUNC("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadFullKeyStateEiRKj", hid_states_fullkey) { fill_states(c); }
HLE_FUNC("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyDualStateEiRKj", hid_states_dual) { fill_states(c); }
HLE_FUNC("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyLeftStateEiRKj", hid_states_left) { fill_states(c); }
HLE_FUNC("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadHandheldStateEiRKj", hid_states_handheld) { fill_states(c); }
HLE_FUNC("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadJoyRightStateEiRKj", hid_states_right) { fill_states(c); }

// ShowControllerSupport(ControllerSupportResultInfo *out, const ControllerSupportArg &) -> Result (Odyssey, at boot):
// the system's "connect a controller" applet, which our am service doesn't have (the game waited for it forever).
// Answered at once: one player, on controller 1. ResultInfo: {s8 player count, pad[3], u32 selected NpadId}.
HLE_FUNC("_ZN2nn3hid21ShowControllerSupportEPNS0_27ControllerSupportResultInfoERKNS0_20ControllerSupportArgE",
         hid_show_controller_support) {
    uint8_t *out = (uint8_t *)(uintptr_t)c->x[0];
    const int8_t *arg = (const int8_t *)(uintptr_t)c->x[1];  // ControllerSupportArg: {s8 player count min, max, ...}
    int want = arg ? arg[1] : 1, players = want >= 2 && pad2 ? 2 : 1;
    if (out) {
        memset(out, 0, 8);
        out[0] = (uint8_t)players;
    }
    static int nlog;
    if (nlog++ < 8) LOG("[input] ShowControllerSupport (players %d..%d): answered with %d player%s%s\n", arg ? arg[0] : 0, want,
                        players, players > 1 ? "s" : "", players < want ? " (a second controller plays player 2)" : "");
    c->x[0] = RES_OK;
}

// FullKey for player 1 only (we report docked mode, where Handheld is unavailable)
HLE_FUNC("_ZN2nn3hid15GetNpadStyleSetERKj", hid_style_set) {
    uint32_t id = *(uint32_t *)(uintptr_t)c->x[0];
    static int nlog;
    if (nlog++ < 4) LOG("[input] GetNpadStyleSet id %#x\n", id);
    c->x[0] = id == 0 || (id == 1 && pad2) ? 1 : 0;  // docked: no handheld controller; player 2: a second controller
}

// BindNpadStyleSetUpdateEvent(id, SystemEventType*, clear mode): signaled once so the game sees a
// controller connected.
#include "../kernel.h"
HLE_FUNC("_ZN2nn3hid27BindNpadStyleSetUpdateEventERKjPNS_2os15SystemEventTypeENS3_14EventClearModeE", hid_bind_style_event) {
    uint32_t w, r;
    KEvent *ev = kernel_create_event_pair(&w, &r);
    pthread_mutex_lock(&g_klock);
    kernel_signal(ev);
    pthread_mutex_unlock(&g_klock);
    uint64_t clear_mode = c->x[2];
    c->x[0] = c->x[1];
    c->x[1] = r;
    c->x[2] = 0;
    c->x[3] = clear_mode;
    guest_call(c, guest_sym("_ZN2nn2os33AttachReadableHandleToSystemEventEPNS0_15SystemEventTypeEjbNS0_14EventClearModeE"));
    LOG("[input] style set update event bound\n");
}

// Vibration: the SDK's vibration node graph and sead's vibration thread stay recompiled and send the game's HD rumble -
// a low and a high band's amplitude for each device (left / right Joy-Con, or the two sides of a Pro Controller) -
// through the hid service (services/hid_set.c: SendVibrationValue(s)) to here: onto the gamepad's two motors, the
// stronger side per band (low band: the low-frequency motor). Sent again while it lasts, so a value runs 250 ms at most:
// a game that stops sending stops the rumble. Controls tab "Vibration" (`vibration` in odyssey.ini).
void input_vibration(uint32_t handle, float amp_low, float amp_high) {
    static float lo[2], hi[2];
    static uint16_t last_l, last_h;
    static uint64_t last_ns;
    static int log = -1;  // ODYSSEY_LOG_RUMBLE=1: each change sent to the gamepad
    if (log < 0) log = getenv("ODYSSEY_LOG_RUMBLE") != NULL;
    int side = handle & 1;
    lo[side] = isfinite(amp_low) ? amp_low : 0, hi[side] = isfinite(amp_high) ? amp_high : 0;
    float l = fmaxf(lo[0], lo[1]), h = fmaxf(hi[0], hi[1]);
    if (!g_settings.rumble) l = h = 0;
    // (the Joy-Cons' actuators are strong: the game's amplitudes are mostly 0.02-0.2, which a gamepad's motors barely
    // turn at - small ones get a boost, (a + a^0.4) / 2: 0.04 -> 0.2, 0.17 -> 0.37, 1 -> 1; below 0.015, nothing)
    l = l < 0.015f ? 0 : (fminf(l, 1) + powf(fminf(l, 1), 0.4f)) * 0.5f;
    h = h < 0.015f ? 0 : (fminf(h, 1) + powf(fminf(h, 1), 0.4f)) * 0.5f;
    uint16_t L = (uint16_t)(l * 65535.0f), H = (uint16_t)(h * 65535.0f);
    uint64_t now = plat_now_ns();
    if (L == last_l && H == last_h && (!(L | H) || now - last_ns < 100000000ull)) return;  // (the same: again every 100 ms)
    last_l = L, last_h = H, last_ns = now;
    if (log) LOG("[input] rumble %.2f %.2f\n", L / 65535.0, H / 65535.0);
    SDL_Gamepad *p = pad;
    if (p) SDL_RumbleGamepad(p, L, H, (L | H) ? 250 : 0);
}

HLE_FUNC("_ZN2nn3hid25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", hid_init_vibration) { (void)c; }
HLE_FUNC("_ZN2nn3hid25GetVibrationDeviceHandlesEPNS0_21VibrationDeviceHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", hid_vibration_handles) {
    uint32_t *out = (uint32_t *)(uintptr_t)c->x[0];
    int n = (int)c->x[1] < 2 ? (int)c->x[1] : 2;
    uint32_t id = *(uint32_t *)(uintptr_t)c->x[2];
    for (int i = 0; i < n; i++) out[i] = (id & 0xFF) << 8 | (uint32_t)i | 0x03000000u;  // type, player, position
    c->x[0] = (uint64_t)n;
}
HLE_FUNC("_ZN2nn3hid22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", hid_vibration_info) {
    uint32_t *info = (uint32_t *)(uintptr_t)c->x[0];
    uint32_t h = *(uint32_t *)(uintptr_t)c->x[1];
    info[0] = 1;        // VibrationDeviceType_LinearResonantActuator
    info[1] = h & 1;    // position: left / right
}

// ---- Motion (0.2.4): the game's six-axis sensor (nn::hid GetSixAxisSensorHandles / StartSixAxisSensor /
// GetSixAxisSensorStates, imported by main - the SDK's own versions read the hid service's shared memory, which never
// moves) answered from the controller's gyro and accelerometer through SDL (PlayStation, Switch Pro, Steam Controller
// and others that have them): the motion cap throws (a shake: homing, up, down and spin throws), the roll boost, the
// motion moves of the minigames. Axes as Switch emulators map SDL's (accel in g, gyro in turns per second). For
// controllers without motion and the keyboard, the Shake binding (Controls tab; keyboard R by default) shakes the
// controller as a quick flick would. ODYSSEY_LOG_MOTION=1: the values the game gets, now and then.
typedef struct {
    int64_t delta_ns, sampling;
    float acc[3], gyro[3], angle[3], dir[9];
    uint32_t attr, pad_;
} SixAxisState;
_Static_assert(sizeof(SixAxisState) == 0x60, "nn::hid::SixAxisSensorState");

static SDL_Gamepad *motion_pad;   // (the pad its sensors were switched on for)
static bool motion_gyro, motion_acc;
static float motion_dir[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1}, motion_angle[3];
static uint64_t motion_last_ns;
static int64_t motion_sampling;
static pthread_mutex_t motion_lock = PTHREAD_MUTEX_INITIALIZER;

static void motion_sensors_on(void) {  // (motion_lock)
    SDL_Gamepad *p = pad;
    if (p == motion_pad) return;
    motion_pad = p;
    motion_gyro = p && SDL_GamepadHasSensor(p, SDL_SENSOR_GYRO) && SDL_SetGamepadSensorEnabled(p, SDL_SENSOR_GYRO, true);
    motion_acc = p && SDL_GamepadHasSensor(p, SDL_SENSOR_ACCEL) && SDL_SetGamepadSensorEnabled(p, SDL_SENSOR_ACCEL, true);
    LOG("[input] motion: %s%s\n", motion_gyro ? "gyro" : "no gyro", motion_acc ? ", accelerometer" : ", no accelerometer");
}

// One state, now: what the sensors read (or the Shake binding's flick), the orientation turned on by the gyro.
static void motion_sample(SixAxisState *s) {
    pthread_mutex_lock(&motion_lock);
    motion_sensors_on();
    uint64_t now = plat_now_ns();
    double dt = motion_last_ns ? (now - motion_last_ns) / 1e9 : 1.0 / 60;
    if (dt > 0.1) dt = 0.1;
    motion_last_ns = now;
    memset(s, 0, sizeof *s);
    s->delta_ns = (int64_t)(dt * 1e9);
    s->sampling = ++motion_sampling;
    s->acc[2] = -1;  // (at rest, lying flat)
    float d[3];
    bool menu = menu_input_captured();
    if (!menu && !host_test && motion_acc && SDL_GetGamepadSensorData(motion_pad, SDL_SENSOR_ACCEL, d, 3)) {
        s->acc[0] = -d[0] / SDL_STANDARD_GRAVITY, s->acc[1] = d[2] / SDL_STANDARD_GRAVITY, s->acc[2] = -d[1] / SDL_STANDARD_GRAVITY;
    }
    if (!menu && !host_test && motion_gyro && SDL_GetGamepadSensorData(motion_pad, SDL_SENSOR_GYRO, d, 3)) {
        const float k = 1.0f / (2.0f * 3.14159265f);  // (rad/s -> turns/s)
        s->gyro[0] = d[0] * k, s->gyro[1] = -d[2] * k, s->gyro[2] = d[1] * k;
    }
    if (!menu && (key_shake || pad_shake)) {  // a flick back and forth, every 50 ms, while it is held
        bool ph = (now / 50000000ull) & 1;
        s->acc[0] = ph ? 2.5f : -2.5f;
        s->acc[1] = ph ? -1.5f : 1.5f;
        s->gyro[2] = ph ? 2.0f : -2.0f;
    }
    // the orientation: turned by the gyro over dt (a small rotation, then kept orthonormal)
    float wx = s->gyro[0] * 6.2831853f * (float)dt, wy = s->gyro[1] * 6.2831853f * (float)dt, wz = s->gyro[2] * 6.2831853f * (float)dt;
    float R[9] = {1, -wz, wy, wz, 1, -wx, -wy, wx, 1}, M[9];
    for (int r = 0; r < 3; r++)
        for (int c2 = 0; c2 < 3; c2++)
            M[r * 3 + c2] = motion_dir[r * 3] * R[c2] + motion_dir[r * 3 + 1] * R[3 + c2] + motion_dir[r * 3 + 2] * R[6 + c2];
    for (int r = 0; r < 3; r++) {  // (Gram-Schmidt on the rows)
        float *v = M + r * 3;
        for (int q = 0; q < r; q++) {
            float *u = M + q * 3, dp = v[0] * u[0] + v[1] * u[1] + v[2] * u[2];
            v[0] -= dp * u[0], v[1] -= dp * u[1], v[2] -= dp * u[2];
        }
        float l = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        if (l > 1e-6f) v[0] /= l, v[1] /= l, v[2] /= l;
    }
    memcpy(motion_dir, M, sizeof M);
    for (int i = 0; i < 3; i++) motion_angle[i] += s->gyro[i] * (float)dt;
    memcpy(s->angle, motion_angle, sizeof s->angle);
    memcpy(s->dir, motion_dir, sizeof s->dir);
    s->attr = 1;  // IsConnected
    static int log = -1;
    if (log < 0) log = getenv("ODYSSEY_LOG_MOTION") != NULL;
    if (log && ((motion_sampling % 120) == 1 || key_shake || pad_shake))
        LOG("[input] motion acc %.2f %.2f %.2f gyro %.2f %.2f %.2f\n", s->acc[0], s->acc[1], s->acc[2], s->gyro[0], s->gyro[1], s->gyro[2]);
    pthread_mutex_unlock(&motion_lock);
}

// GetSixAxisSensorHandles(SixAxisSensorHandle *out, int count, const NpadIdType &id, NpadStyleSet style) -> count:
// a handle {style index, npad id, device index} per device - two for a Joy-Con pair, one otherwise.
HLE_FUNC("_ZN2nn3hid23GetSixAxisSensorHandlesEPNS0_19SixAxisSensorHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE",
         hid_sixaxis_handles) {
    uint32_t *out = (uint32_t *)(uintptr_t)c->x[0];
    int count = (int)c->x[1];
    uint32_t id = *(uint32_t *)(uintptr_t)c->x[2], style = (uint32_t)c->x[3];
    int n = count < 1 ? 0 : (style & 4) && count >= 2 ? 2 : 1;  // (bit 2: JoyDual)
    uint32_t type = style & 1 ? 3 : style & 2 ? 4 : style & 4 ? 5 : 3;
    for (int i = 0; i < n; i++) out[i] = type | (id & 0xFF) << 8 | (uint32_t)i << 16;
    static int nlog;
    if (nlog++ < 4) LOG("[input] GetSixAxisSensorHandles id %#x style %#x: %d\n", id, style, n);
    c->x[0] = (uint64_t)n;
}
HLE_FUNC("_ZN2nn3hid18StartSixAxisSensorERKNS0_19SixAxisSensorHandleE", hid_sixaxis_start) {
    pthread_mutex_lock(&motion_lock);
    motion_sensors_on();
    pthread_mutex_unlock(&motion_lock);
    (void)c;
}
// GetSixAxisSensorStates(SixAxisSensorState *out, int count, const SixAxisSensorHandle &) -> how many, newest first
HLE_FUNC("_ZN2nn3hid22GetSixAxisSensorStatesEPNS0_18SixAxisSensorStateEiRKNS0_19SixAxisSensorHandleE", hid_sixaxis_states) {
    SixAxisState *out = (SixAxisState *)(uintptr_t)c->x[0];
    if ((int)c->x[1] < 1 || !out) { c->x[0] = 0; return; }
    motion_sample(out);
    c->x[0] = 1;
}

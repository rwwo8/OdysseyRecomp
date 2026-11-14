// In-game overlay menu built with Dear ImGui (Metal renderer on macOS, Vulkan elsewhere; input fed from SDL events).
//
// Threads: SDL events arrive on the main thread and are queued; the menu is laid out and drawn on the
// render thread inside backend_present, after the game image, into the same drawable.
#ifdef __APPLE__
#import <Metal/Metal.h>
#endif
#include <SDL3/SDL.h>
#include <ctype.h>
#include <math.h>
#include <pthread.h>
#include <atomic>
#include <vector>

#include "imgui.h"
#include "option_rows.h"
#include "imgui_internal.h"  // (NavCursorVisible)
#include "osk.h"
#include "theme.h"
#include "launcher.h"  // (outside the extern "C" below: it has C++ parts)
#ifdef __APPLE__
#include "imgui_impl_metal.h"
#else
#include "imgui_impl_vulkan.h"
extern "C" bool vk_imgui_backend_init(void);  // runtime/nvn/vulkan/imgui_glue.cpp
#endif
extern "C" void rt_set_fullscreen(SDL_Window *w, bool on);  // runtime/nvn/vulkan/device.c, metal.m

extern "C" {
#include "../hle.h"
#include "../mods.h"
#include "../settings.h"
#include "menu.h"
#include "setup.h"
void input_reset(void);
void controls_bindings_draw(float scale);  // controls_ui.mm
#include "../input_bind.h"
#include "../paths.h"
}

// ------------------------------------------------------------------ state shared with the main thread
static std::atomic<bool> g_open{false};
static std::atomic<bool> g_setup{false};  // the first-start setup page (setup.mm) instead of the menu
static std::atomic<bool> g_launcher{false};  // the launcher (launcher.mm) instead of the menu
static std::atomic<bool> g_text_busy{false};  // a text field / the on-screen keyboard has the keys (render thread: ui_text_busy)
static std::atomic<bool> g_want_fullscreen_apply{false};

struct QEvent {
    enum { KEY, ANALOG, MOUSE_POS, MOUSE_BUTTON, WHEEL, TEXT } kind;
    ImGuiKey key;
    bool down;
    float value, x, y;
    int button;
    char text[32];
};
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static std::vector<QEvent> q_events;
static float g_pixel_density = 1;

static void push(const QEvent &e) {
    pthread_mutex_lock(&q_lock);
    q_events.push_back(e);
    pthread_mutex_unlock(&q_lock);
}

bool menu_is_open(void) { return g_open.load(); }
void menu_setup_mode(bool on) { g_setup.store(on); }
void menu_launcher_mode(bool on) { g_launcher.store(on); }
static void set_open(bool open);
extern "C" void menu_test_open(void) {
    set_open(true);
    if (getenv("ODYSSEY_MENU_TAB")) { extern int g_tab_request_ext; g_tab_request_ext = atoi(getenv("ODYSSEY_MENU_TAB")); }
}

void menu_tabs_focus(bool first_tab);
static void set_open(bool open) {
    if (open == g_open.load()) return;
    g_open.store(open);
    input_reset();  // nothing held while the menu had focus leaks into the game
    bind_capture_cancel();
    if (open) {
        static bool opened;  // the controller's cursor: the first tab (Controls) the first time this session, later the
        menu_tabs_focus(!opened);  // selected one
        opened = true;
    }
    else { settings_save(); osk_cancel(); g_text_busy = false; }
}

static ImGuiKey key_from_scancode(SDL_Scancode sc) {
    switch (sc) {
    case SDL_SCANCODE_UP: return ImGuiKey_UpArrow;
    case SDL_SCANCODE_DOWN: return ImGuiKey_DownArrow;
    case SDL_SCANCODE_LEFT: return ImGuiKey_LeftArrow;
    case SDL_SCANCODE_RIGHT: return ImGuiKey_RightArrow;
    case SDL_SCANCODE_RETURN: return ImGuiKey_Enter;
    case SDL_SCANCODE_KP_ENTER: return ImGuiKey_KeypadEnter;
    case SDL_SCANCODE_SPACE: return ImGuiKey_Space;
    case SDL_SCANCODE_TAB: return ImGuiKey_Tab;
    case SDL_SCANCODE_BACKSPACE: return ImGuiKey_Backspace;
    case SDL_SCANCODE_DELETE: return ImGuiKey_Delete;
    case SDL_SCANCODE_HOME: return ImGuiKey_Home;
    case SDL_SCANCODE_END: return ImGuiKey_End;
    case SDL_SCANCODE_PAGEUP: return ImGuiKey_PageUp;
    case SDL_SCANCODE_PAGEDOWN: return ImGuiKey_PageDown;
    case SDL_SCANCODE_LSHIFT: return ImGuiKey_LeftShift;
    case SDL_SCANCODE_RSHIFT: return ImGuiKey_RightShift;
    case SDL_SCANCODE_LCTRL: return ImGuiKey_LeftCtrl;
    case SDL_SCANCODE_RCTRL: return ImGuiKey_RightCtrl;
    case SDL_SCANCODE_LGUI: return ImGuiKey_LeftSuper;
    case SDL_SCANCODE_RGUI: return ImGuiKey_RightSuper;
    case SDL_SCANCODE_A: return ImGuiKey_A;
    case SDL_SCANCODE_C: return ImGuiKey_C;
    case SDL_SCANCODE_V: return ImGuiKey_V;
    case SDL_SCANCODE_X: return ImGuiKey_X;
    case SDL_SCANCODE_Z: return ImGuiKey_Z;
    case SDL_SCANCODE_Q: return ImGuiKey_Q;  // previous tab
    case SDL_SCANCODE_E: return ImGuiKey_E;  // next tab
    default: return ImGuiKey_None;
    }
}

// Nintendo layout: the right face button (A) confirms, the bottom one (B) goes back. The Controls tab's Xbox /
// PlayStation layout (bindings.c bind_names_layout): the bottom one (A / Cross) confirms, the right one goes back.
static ImGuiKey key_from_pad(Uint8 b) {
    if (bind_names_layout()) {
        if (b == SDL_GAMEPAD_BUTTON_SOUTH) return ImGuiKey_GamepadFaceDown;
        if (b == SDL_GAMEPAD_BUTTON_EAST) return ImGuiKey_GamepadFaceRight;
    }
    switch (b) {
    case SDL_GAMEPAD_BUTTON_EAST: return ImGuiKey_GamepadFaceDown;   // activate
    case SDL_GAMEPAD_BUTTON_SOUTH: return ImGuiKey_GamepadFaceRight; // cancel / back
    case SDL_GAMEPAD_BUTTON_NORTH: return ImGuiKey_GamepadFaceUp;
    case SDL_GAMEPAD_BUTTON_WEST: return ImGuiKey_GamepadFaceLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return ImGuiKey_GamepadDpadUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return ImGuiKey_GamepadDpadDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return ImGuiKey_GamepadDpadLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return ImGuiKey_GamepadDpadRight;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ImGuiKey_GamepadL1;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ImGuiKey_GamepadR1;
    case SDL_GAMEPAD_BUTTON_START: return ImGuiKey_GamepadStart;
    case SDL_GAMEPAD_BUTTON_BACK: return ImGuiKey_GamepadBack;
    default: return ImGuiKey_None;
    }
}

// ---- software keyboard (runtime/hle/swkbd.c: the game's name entry etc.) --------------------------------------
// The game thread waits in menu_keyboard_run (re-presenting the last frame); this dialog takes the text: typed
// directly when the player last used a keyboard, an on-screen keyboard (d-pad + A, B deletes, Start / + OK) when
// they last used a controller.
static std::atomic<int> g_kbd{0};  // 1 open, 2 confirmed, 3 cancelled
static std::atomic<bool> g_last_pad{false};
static char g_kbd_text[96];
static int g_kbd_max = 8;
// A notice the game thread waits on in menu_notice_run, like the name entry (runtime/hle/applets.c: a system applet
// this version has nothing to show for)
static std::atomic<int> g_note{0};  // 1 shown, 2 closed
static char g_note_title[128], g_note_text[800];
static bool capturing() { return g_open.load() || g_kbd.load() == 1 || g_note.load() == 1 || g_setup.load() || g_launcher.load(); }
// (frame interpolation's presenter, runtime/nvn/vulkan/device.c, draws the overlay without the render lock) nothing open
// that takes input or runs the menu's actions, and the overlay drawn once (ImGui uploads its fonts on the first frame)
static std::atomic<bool> g_drawn;
extern "C" bool menu_overlay_lockfree(void) { return !capturing() && (!g_settings.show_fps || g_drawn.load()); }
// The game gets no input while this is true (runtime/hle/input.c): menu or name entry up.
extern "C" bool menu_input_captured(void) { return capturing(); }

bool menu_handle_event(const SDL_Event *e) {
    static bool back_down, start_down;
    if ((g_open.load() || g_launcher.load()) && bind_capture_event(e)) return true;  // Controls tab waiting for a new binding: it takes the press
    if (e->type == SDL_EVENT_KEY_DOWN) g_last_pad = false;
    if (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN) g_last_pad = true;
    if (g_kbd.load() == 1 && e->type == SDL_EVENT_KEY_DOWN && !e->key.repeat) {  // Enter confirms, Esc cancels
        if (e->key.scancode == SDL_SCANCODE_RETURN || e->key.scancode == SDL_SCANCODE_KP_ENTER) { g_kbd = 2; return true; }
        if (e->key.scancode == SDL_SCANCODE_ESCAPE) { g_kbd = 3; return true; }
    }
    if (g_kbd.load() == 1 && e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN && e->gbutton.button == SDL_GAMEPAD_BUTTON_START) {
        g_kbd = 2;
        return true;
    }
    if (g_note.load() == 1 && e->type == SDL_EVENT_KEY_DOWN && !e->key.repeat &&  // Enter / Space / Esc: OK
        (e->key.scancode == SDL_SCANCODE_RETURN || e->key.scancode == SDL_SCANCODE_KP_ENTER ||
         e->key.scancode == SDL_SCANCODE_SPACE || e->key.scancode == SDL_SCANCODE_ESCAPE)) {
        g_note = 2;
        return true;
    }
    // typing (a text field, the on-screen keyboard, the name entry): keys are text, not menu shortcuts
    bool typing = g_kbd.load() == 1 || ((g_open.load() || g_launcher.load()) && g_text_busy.load());
    switch (e->type) {
    case SDL_EVENT_KEY_DOWN:
        if (!e->key.repeat && !g_setup.load() && !g_launcher.load() && (e->key.scancode == SDL_SCANCODE_F1 ||
                                                  (e->key.scancode == SDL_SCANCODE_ESCAPE && !g_open.load()))) {
            if (!typing) set_open(!g_open.load());  // (Esc with the menu open goes to ImGui below: it cancels a field)
            return true;
        }
        if (!e->key.repeat && (e->key.scancode == SDL_SCANCODE_F11 ||
                               (e->key.scancode == SDL_SCANCODE_RETURN && (e->key.mod & (SDL_KMOD_ALT | SDL_KMOD_GUI))) ||
                               (e->key.scancode == SDL_SCANCODE_F && (e->key.mod & SDL_KMOD_GUI) && (e->key.mod & SDL_KMOD_CTRL)))) {
            g_settings.fullscreen = !g_settings.fullscreen;
            g_want_fullscreen_apply.store(true);
            settings_save();
            return true;
        }
        /* fallthrough */
    case SDL_EVENT_KEY_UP: {
        if (!capturing()) return false;
        bool down = e->type == SDL_EVENT_KEY_DOWN;
        if (down && e->key.scancode == SDL_SCANCODE_ESCAPE) {  // Esc: back out of popups, else close
            QEvent q = {};
            q.kind = QEvent::KEY; q.key = ImGuiKey_Escape; q.down = true; push(q);
            q.down = false; push(q);
            return true;
        }
        ImGuiKey k = key_from_scancode(e->key.scancode);
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_TEXT_INPUT:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::TEXT; strlcpy(q.text, e->text.text, sizeof q.text); push(q); }
        return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        bool down = e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_BACK) back_down = down;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_START) start_down = down;
        if (down && !typing && !g_setup.load() && !g_launcher.load() && ((back_down && start_down) || e->gbutton.button == SDL_GAMEPAD_BUTTON_GUIDE)) {
            set_open(!g_open.load());
            return true;
        }
        if (!capturing()) return false;
        ImGuiKey k = key_from_pad(e->gbutton.button);
        if (k != ImGuiKey_None) { QEvent q = {}; q.kind = QEvent::KEY; q.key = k; q.down = down; push(q); }
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        if (!capturing()) return false;
        float v = e->gaxis.value / 32767.0f;
        QEvent q = {};
        q.kind = QEvent::ANALOG;
        switch (e->gaxis.axis) {
        case SDL_GAMEPAD_AXIS_LEFTX:
            q.key = ImGuiKey_GamepadLStickLeft; q.value = v < -0.3f ? -v : 0; push(q);
            q.key = ImGuiKey_GamepadLStickRight; q.value = v > 0.3f ? v : 0; push(q);
            break;
        case SDL_GAMEPAD_AXIS_LEFTY:
            q.key = ImGuiKey_GamepadLStickUp; q.value = v < -0.3f ? -v : 0; push(q);
            q.key = ImGuiKey_GamepadLStickDown; q.value = v > 0.3f ? v : 0; push(q);
            break;
        case SDL_GAMEPAD_AXIS_LEFT_TRIGGER: q.key = ImGuiKey_GamepadL2; q.value = v; push(q); break;
        case SDL_GAMEPAD_AXIS_RIGHT_TRIGGER: q.key = ImGuiKey_GamepadR2; q.value = v; push(q); break;
        default: break;
        }
        return true;
    }
    case SDL_EVENT_MOUSE_MOTION:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::MOUSE_POS; q.x = e->motion.x * g_pixel_density; q.y = e->motion.y * g_pixel_density; push(q); }
        return true;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
        if (!capturing()) return false;
        {
            QEvent q = {};
            q.kind = QEvent::MOUSE_BUTTON;
            q.button = e->button.button == SDL_BUTTON_LEFT ? 0 : e->button.button == SDL_BUTTON_RIGHT ? 1 : 2;
            q.down = e->type == SDL_EVENT_MOUSE_BUTTON_DOWN;
            push(q);
        }
        return true;
    case SDL_EVENT_MOUSE_WHEEL:
        if (!capturing()) return false;
        { QEvent q = {}; q.kind = QEvent::WHEEL; q.x = e->wheel.x; q.y = e->wheel.y; push(q); }
        return true;
    default:
        return false;
    }
}

void menu_apply_window_requests(void *win) {
    SDL_Window *w = (SDL_Window *)win;
    g_pixel_density = SDL_GetWindowPixelDensity(w);
    static bool text_input;
    bool want_text = capturing();
    if (want_text != text_input) {
        if (want_text) SDL_StartTextInput(w);
        else SDL_StopTextInput(w);
        text_input = want_text;
    }
    static bool first = true;
    if (first || g_want_fullscreen_apply.exchange(false)) {
        first = false;
        rt_set_fullscreen(w, g_settings.fullscreen);  // (device.c: a 60 Hz mode on 144 / 165 Hz displays)
    }
}

// ------------------------------------------------------------------ render thread
static bool g_inited;
static ImGuiContext *g_ctx;  // ours (another UI would have its own context)
static ImFont *g_font, *g_font_big;
static ImFont *g_menu_font, *g_menu_font_big;  // the menu window (Roboto Medium); everything else keeps g_font
static int g_tab, g_tab_request = -2;  // (-2: no request; -1 is the Prelaunch tab)
static int g_focus_tab = -99;  // put the nav cursor on this tab next frame (-100: the selected one; -99: none)
static int g_focus_frames;

// The menu opening: the controller's cursor starts on the first tab the first time in a session,
// later on the tab that's selected
void menu_tabs_focus(bool first_tab) { g_focus_tab = first_tab ? -1 : -100, g_focus_frames = 0; }
void menu_tabs_focus_tab(int id) { g_focus_tab = id, g_focus_frames = 0; }  // (the launcher: the page it opens)
int g_tab_request_ext = -1;

// The look (theme.h): charcoal, white text, red as the one accent; square-ish corners; tabs are plain words with a red
// line under the selected one (tabs_body draws it).
static void style_init(void) {
    ImGuiStyle &s = ImGui::GetStyle();
    ImGui::StyleColorsDark();
    s.WindowRounding = 16; s.FrameRounding = 8; s.GrabRounding = 8; s.TabRounding = 10; s.ChildRounding = 10;
    s.PopupRounding = 6; s.ScrollbarRounding = 4;
    s.WindowPadding = ImVec2(32, 26); s.FramePadding = ImVec2(14, 8); s.ItemSpacing = ImVec2(14, 12);
    s.WindowBorderSize = 0; s.ScrollbarSize = 14; s.TabBarBorderSize = 0;
    ImVec4 *c = s.Colors, none(0, 0, 0, 0);
    c[ImGuiCol_WindowBg] = kPanelV;
    c[ImGuiCol_ChildBg] = none;
    c[ImGuiCol_PopupBg] = ImVec4(kPanelV.x, kPanelV.y, kPanelV.z, 0.99f);
    c[ImGuiCol_Border] = kLineV;
    c[ImGuiCol_Text] = kTextV;
    c[ImGuiCol_TextDisabled] = kTextDimV;
    c[ImGuiCol_FrameBg] = c[ImGuiCol_Button] = c[ImGuiCol_Header] = c[ImGuiCol_TableHeaderBg] = kSurfaceV;
    c[ImGuiCol_FrameBgHovered] = c[ImGuiCol_ButtonHovered] = c[ImGuiCol_HeaderHovered] = kSurfaceHoverV;
    c[ImGuiCol_FrameBgActive] = c[ImGuiCol_ButtonActive] = c[ImGuiCol_HeaderActive] = kAccentDeepV;
    c[ImGuiCol_Tab] = c[ImGuiCol_TabSelectedOverline] = none;
    c[ImGuiCol_TabSelected] = kSurfaceV;  // (the page shown: a filled tab, the sky-blue line under it)
    c[ImGuiCol_TabDimmed] = c[ImGuiCol_TabDimmedSelected] = c[ImGuiCol_TabDimmedSelectedOverline] = none;
    c[ImGuiCol_TabHovered] = ImVec4(1, 1, 1, 0.06f);
    c[ImGuiCol_CheckMark] = c[ImGuiCol_SliderGrabActive] = c[ImGuiCol_NavCursor] = c[ImGuiCol_ScrollbarGrabActive] = kAccentV;
    c[ImGuiCol_SliderGrab] = ImVec4(kAccentV.x, kAccentV.y, kAccentV.z, 0.75f);
    c[ImGuiCol_Separator] = kLineV;
    c[ImGuiCol_TableRowBg] = none;
    c[ImGuiCol_TableRowBgAlt] = ImVec4(1, 1, 1, 0.03f);
    c[ImGuiCol_ScrollbarBg] = none;
    c[ImGuiCol_ScrollbarGrab] = ImVec4(1, 1, 1, 0.14f);
    c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(1, 1, 1, 0.22f);
    c[ImGuiCol_TitleBg] = c[ImGuiCol_TitleBgActive] = c[ImGuiCol_WindowBg];
    c[ImGuiCol_ModalWindowDimBg] = ImVec4(0, 0, 0, 0.45f);
}


#ifdef __APPLE__
static void init(id<MTLDevice> dev) {
#else
static void init(void) {
#endif
    IMGUI_CHECKVERSION();
    g_ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
    io.IniFilename = NULL;
    ImFontConfig cfg;
    cfg.OversampleH = 2;
    const char *paths[] = {"/System/Library/Fonts/Avenir Next.ttc", "/System/Library/Fonts/Helvetica.ttc",
                           "C:/Windows/Fonts/segoeui.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                           "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"};
    for (const char *p : paths) {
        if (FILE *f = fopen(p, "rb")) fclose(f);  // a missing file is an assertion in ImGui, not a NULL return
        else continue;
        if (!g_font) g_font = io.Fonts->AddFontFromFileTTF(p, 34, &cfg);
        if (g_font && !g_font_big) { ImFontConfig b = cfg; b.FontNo = 0; g_font_big = io.Fonts->AddFontFromFileTTF(p, 56, &b); }
    }
    // the menu window itself: Roboto Medium (third_party/imgui/misc/fonts, Apache 2.0); the FPS counter, overlays and
    // on-screen keyboard keep the fonts above
    char menu_font[1024];
    if (const char *f = getenv("ODYSSEY_MENU_FONT")) strlcpy(menu_font, f, sizeof menu_font);  // (test) another face
    if (getenv("ODYSSEY_MENU_FONT") ||
        rt_resource("Roboto-Medium.ttf", "third_party/imgui/misc/fonts/Roboto-Medium.ttf", menu_font, sizeof menu_font)) {
        g_menu_font = io.Fonts->AddFontFromFileTTF(menu_font, 36, &cfg);
        g_menu_font_big = io.Fonts->AddFontFromFileTTF(menu_font, 58, &cfg);
    }
    if (!g_font) g_font = io.Fonts->AddFontDefault();
    if (!g_font_big) g_font_big = g_font;
    if (!g_menu_font || !g_menu_font_big) g_menu_font = g_font, g_menu_font_big = g_font_big;
    style_init();
#ifdef __APPLE__
    ImGui_ImplMetal_Init(dev);
#else
    vk_imgui_backend_init();
#endif
    g_inited = true;
}

static void drain_events(ImGuiIO &io) {
    pthread_mutex_lock(&q_lock);
    std::vector<QEvent> ev;
    ev.swap(q_events);
    pthread_mutex_unlock(&q_lock);
    for (const QEvent &q : ev) {
        switch (q.kind) {
        case QEvent::KEY: io.AddKeyEvent(q.key, q.down); break;
        case QEvent::ANALOG: io.AddKeyAnalogEvent(q.key, q.value > 0.1f, q.value); break;
        case QEvent::MOUSE_POS: io.AddMousePosEvent(q.x, q.y); break;
        case QEvent::MOUSE_BUTTON: io.AddMouseButtonEvent(q.button, q.down); break;
        case QEvent::WHEEL: io.AddMouseWheelEvent(q.x, q.y); break;
        case QEvent::TEXT: io.AddInputCharactersUTF8(q.text); break;
        }
    }
}

// Section header: in the accent, capitals, as the option rows' sections (option_rows.mm opt_section).
static void header(const char *t) {
    char up[96];
    int i = 0;
    for (; t[i] && i < (int)sizeof up - 1; i++) up[i] = (char)toupper((unsigned char)t[i]);
    up[i] = 0;
    ImGui::Dummy(ImVec2(0, 4));
    ImGui::TextColored(kAccentV, "%s", up);
    ImGui::Separator();
    ImGui::Spacing();
}

static void hint(const char *t) {
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("%s", t);
    ImGui::PopTextWrapPos();
}

// A row with a label on the left and a choice of options on the right (dpad left/right cycles).
// reserve: room kept free right of the combo (a button on the same line)
static bool choice(const char *label, int *value, const char *const *names, int n, float reserve = 0) {
    ImGui::PushID(label);
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(label);
    ImGui::SameLine(ImGui::GetContentRegionAvail().x * 0.45f);
    bool changed = false;
    ImGui::SetNextItemWidth(reserve > 0 ? -reserve : -1);
    if (ImGui::BeginCombo("##c", names[*value])) {
        for (int i = 0; i < n; i++) {
            if (ImGui::Selectable(names[i], i == *value)) { *value = i; changed = true; }
            if (i == *value) ImGui::SetItemDefaultFocus();
        }
        ImGui::EndCombo();
    }
    if (ImGui::IsItemFocused() && !ImGui::IsPopupOpen("##c")) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow)) {
            *value = (*value + 1) % n; changed = true;
        }
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) {
            *value = (*value + n - 1) % n; changed = true;
        }
    }
    ImGui::PopID();
    return changed;
}

static bool toggle(const char *label, bool *v) {
    const char *names[] = {"Off", "On"};
    int i = *v;
    bool ch = choice(label, &i, names, 2);
    *v = i;
    return ch;
}

extern "C" void renderer_get_scale(float *sx, float *sy);
extern "C" int input_pad_family(void);  // runtime/hle/input.c
extern "C" double output_scale_dynamic_factor(void);

static void tab_display(void) {
    float scale = ImGui::GetFontSize() / 34;
    opt_begin("##video", scale);
    opt_section("Display");
    {
        static const char *modes[] = {"Window", "Borderless", "Fullscreen"};
        int m = !g_settings.fullscreen ? 0 : g_settings.borderless ? 1 : 2;
        if (opt_choice("Display mode", &m, modes, 3, 0,
                       "Window: a window you can resize and move.\n\nBorderless: fills the screen as a window without "
                       "a frame - switching to other windows is instant, the display keeps its own refresh rate (on 144 "
                       "/ 165 Hz the game's 60 frames can't come quite evenly).\n\nFullscreen: fills the screen and "
                       "switches a 144 / 165 Hz display to its 60 Hz mode - the smoothest movement (with the Frame "
                       "limiter at 60 fps).\n\nF11 or Alt+Enter switches between the window and the last of the other "
                       "two.")) {
            g_settings.fullscreen = m != 0;
            if (m) g_settings.borderless = m == 1;
            g_want_fullscreen_apply.store(true);
        }
    }
#ifndef __APPLE__  // (Vulkan: runtime/nvn/interp.c; device.c rt_set_fullscreen picks the display mode for it)
    {
        static const char *lim[] = {"60 fps", "120 fps"};
        int v = g_settings.frame_interp;
        if (opt_choice("Frame limiter", &v, lim, 2, 0,
                       "How many images a second you see. 60 fps: the game's own frames, each shown once - in "
                       "fullscreen a 144 / 165 Hz display switches to its 60 Hz mode, so movement stays perfectly even. "
                       "The smoothest choice on 144 / 165 Hz.\n\n120 fps: an extra image between each two of the game's "
                       "frames, made from the game's own state halfway (frame interpolation; experimental). For displays "
                       "at 120 or 240 Hz: on 144 / 165 Hz the 120 images can't come evenly. About twice the GPU work, "
                       "half a frame of delay; the game itself still runs at 60.")) {
            g_settings.frame_interp = v != 0;
            if (g_settings.fullscreen) g_want_fullscreen_apply.store(true);  // (60 Hz mode, or the desktop's rate)
        }
    }
#endif
    opt_toggle("Show FPS", &g_settings.show_fps, false, "Shows the frame rate in the top right corner.");
    opt_indent(1);
    if (!g_settings.show_fps) opt_disable_next();
    opt_toggle("Frame time graph", &g_settings.frame_graph, false,
               "Under the FPS counter: how long each of the last frames took. A steady line at 16.7 ms is a smooth 60 "
               "fps; spikes are the hitches you feel (a place or effect seen for the first time, a loading area).");
    opt_indent(-1);
#ifndef __APPLE__  // (Vulkan: runtime/hle/odyssey_wide.c)
    {
        static const char *asp[] = {"16:9", "Fill window"};
        opt_choice("Aspect ratio", &g_settings.aspect, asp, 2, ASPECT_16_9,
                   "For windows wider than 16:9 (ultrawide monitors). 16:9: the Switch's picture, with bars at the sides. "
                   "Fill window: the game shows more of the world at the sides; the HUD keeps its shape in the middle.");
    }
#endif

    opt_section("Rendering");
    // display order -> RES_* (the ini / enum order predates the menu order)
    // (up to 8K: 7680 x 4320 - more only ran out of GPU memory)
    // (named by their size, fixed sizes only: Match display, Dynamic and the shares of the display removed for more
    // quality steps - the player, 2026-11-07; 720p / 900p taken out again, the player's wish)
    static const char *res[] = {"1080p", "1440p", "4K", "5K", "6K", "8K"};
    static const int res_mode[] = {1, RES_1440, 2, RES_5K, 3, 4};
    enum { RES_DEFAULT_AT = 1 };
    enum { NRES = sizeof res_mode / sizeof res_mode[0] };
    {
        int ri = RES_DEFAULT_AT;
        for (int i = 0; i < NRES; i++) if (res_mode[i] == g_settings.res_mode) ri = i;
        float sx, sy;
        renderer_get_scale(&sx, &sy);
        char d[400];
        snprintf(d, sizeof d, "How sharp the 3D image is: the size the game renders at, then scaled to your screen. Above "
                              "your display's resolution the picture gets smoother still (supersampling), at more GPU "
                              "cost (the Switch renders 900p).\n\n"
                              "Rendering at %.0f x %.0f.", 1600.0 * sx, 900.0 * sy);
        if (opt_choice("Internal resolution", &ri, res, NRES, RES_DEFAULT_AT, d, false)) g_settings.res_mode = res_mode[ri];
    }
    {   // each OS's own upscaler next to bilinear (UPSCALE_SHARP: MetalFX on macOS, AMD FSR 1 on Windows)
#ifdef __APPLE__
        static const char *ups[] = {"Bilinear", "MetalFX"};
        const char *ud = "How the image is scaled up to the window when it renders at a lower resolution. MetalFX: Apple's "
                         "upscaler, sharper. Bilinear: plain and soft.";
#else
        static const char *ups[] = {"Bilinear", "AMD FSR 1"};
        const char *ud = "How the image is scaled up to the window when it renders at a lower resolution. AMD FSR 1: "
                         "edge-aware upscaling and sharpening, sharper. Bilinear: plain and soft.";
#endif
        int ui = g_settings.upscaler == UPSCALE_BILINEAR ? 0 : 1;
        if (opt_choice("Upscaler", &ui, ups, 2, 1, ud)) g_settings.upscaler = ui ? UPSCALE_SHARP : UPSCALE_BILINEAR;
    }
    static const char *aa[] = {"Off", "SMAA"};
    opt_choice("Anti-aliasing", &g_settings.antialias, aa, 2, AA_OFF,
               "Smooths jagged edges of the game image before it is scaled to the window. SMAA: finds the edges and "
               "blends only along them, so textures stay sharp. Most useful at a lower internal resolution.");
#ifndef __APPLE__  // (Vulkan: exec.c post_process)
    {
        static const char *sh[] = {"Off", "Low", "Medium", "High", "Auto"};
        static const int order[] = {SHARPEN_AUTO, SHARPEN_OFF, SHARPEN_LOW, SHARPEN_MEDIUM, SHARPEN_HIGH};
        static const char *names[] = {sh[4], sh[0], sh[1], sh[2], sh[3]};
        int i = 0;
        for (int k = 0; k < 5; k++) if (order[k] == g_settings.sharpen) i = k;
        if (opt_choice("Sharpening", &i, names, 5, 0,
                       "AMD FSR's contrast-adaptive sharpening: fine detail (grass, stone, fabric) stands out more. "
                       "Auto: High while the image is scaled up, none at your display's own resolution. Low / Medium / "
                       "High: always, at any resolution."))
            g_settings.sharpen = order[i];
    }
#endif
    {
        static const char *af[] = {"Game's own", "2x", "4x", "8x", "16x"};
        static const int val[] = {0, 2, 4, 8, 16};
        int i = 4;
        for (int k = 0; k < 5; k++) if (val[k] == g_settings.aniso) i = k;
        if (opt_choice("Anisotropic filtering", &i, af, 5, 4,
                       "Keeps textures sharp when you see them at a slant: the ground ahead of Mario, roads and walls "
                       "into the distance, which otherwise blur. 16x: sharpest, and nearly free on any recent GPU. Game's "
                       "own: as on the Switch."))
            g_settings.aniso = val[i];
    }
#ifndef __APPLE__  // (Vulkan: exec.c post_process "grade.frag")
    opt_section("Picture");
    {
        int b = (int)lroundf(g_settings.brightness * 100);
        if (opt_int("Brightness", &b, 50, 150, 5, 100, "%d%%",
                    "Lighter or darker middle tones; black stays black and white stays white. For a dark room, or a "
                    "display that shows the game too dark or too bright."))
            g_settings.brightness = b / 100.0f;
        int s = (int)lroundf(g_settings.saturation * 100);
        if (opt_int("Color saturation", &s, 0, 200, 5, 100, "%d%%",
                    "How strong the colors are. 100%: as the game; more: more vivid; 0%: black and white."))
            g_settings.saturation = s / 100.0f;
    }
#endif
#ifndef __APPLE__  // (Vulkan: nvn/vulkan/textures.c "Banding")
    opt_toggle("Smooth gradients", &g_settings.deband, true,
               "Removes the visible color steps (banding) in skies, fog and dark areas: the game's image keeps more "
               "precision until it reaches the screen and gets a fine dither there. Off: as on the Switch.");
#endif
    opt_end();
}

static void tab_audio(void) {
    opt_begin("##audio", ImGui::GetFontSize() / 34);
    opt_section("Sound");
    float pct = roundf(g_settings.volume * 100);
    if (opt_slider("Volume", &pct, 0, 200, 5, 100, "%g%%",
                   "The game's volume. 100% is the game's own level; above it, louder."))
        g_settings.volume = pct / 100.0f;
    opt_toggle("Reverb", &g_settings.reverb, true,
               "The game's echo effect in caves and big rooms.");
    opt_toggle("Movie audio", &g_settings.movie_audio, true,
               "Sound in the game's videos (e.g. the control tips). Applies the next time a video starts.");
    opt_end();
}

// Mods (runtime/mods.h): the folders in mods/ with game files, each on or off (applies the next time the game starts).
static void tab_mods(float scale) {
    const char *how = "Put each add-on in its own folder in the mods folder, with its romfs folder inside: "
                      "mods/<Name>/romfs/...\n\nAdd-ons made for version 1.0.0 of the game work best. "
                      "If two mods change the same file, the one higher in the list wins.\n\nCode mods (exefs: IPS / "
                      "pchtxt patches, Super Mario Odyssey: Online) can't be used: the game code is recompiled from the "
                      "original game on your PC.";
    opt_begin("##mods", scale);
    int n = mods_count();
    opt_section(mods_changed() ? "Add-ons - restart the game to apply" : "Add-ons");
    if (!n) {
        opt_disable_next();
        opt_action("No add-ons found", "", how);
    }
    for (int i = 0; i < n; i++) {
        const ModInfo *m = mods_get(i);
        char d[1600];
        int k = snprintf(d, sizeof d, "mods/%s\n\n", m->id);
        if (!m->romfs) {
            snprintf(d + k, sizeof d - k, "A code mod: it changes the game code, which can't be used here - the game "
                                          "code is recompiled from the original game on your PC.");
        } else {
            k += snprintf(d + k, sizeof d - k, "%d file%s", m->files, m->files == 1 ? "" : "s");
            if (m->applied)
                k += snprintf(d + k, sizeof d - k, ": %d replace%s the game's, %d %s new.", m->replaced,
                              m->replaced == 1 ? "s" : "", m->added, m->added == 1 ? "is" : "are");
            else
                k += snprintf(d + k, sizeof d - k, ".");
            if (m->applied && m->shadowed)
                k += snprintf(d + k, sizeof d - k, " %d %s also in a mod higher in this list, which wins.", m->shadowed,
                              m->shadowed == 1 ? "is" : "are");
            if (m->applied && m->skipped)
                k += snprintf(d + k, sizeof d - k, " %d %s in %s the game doesn't have, left out.", m->skipped,
                              m->skipped == 1 ? "is" : "are", m->skipped == 1 ? "a folder" : "folders");
            if (m->code) k += snprintf(d + k, sizeof d - k, " Its code patches (exefs) can't be used here.");
            snprintf(d + k, sizeof d - k, "\n\nSwitching it on or off applies the next time the game starts.");
        }
        bool on = m->romfs && m->on;
        ImGui::PushID(i);  // (two mods may have the same name)
        if (!m->romfs) opt_disable_next();
        if (opt_toggle(m->name, &on, true, d)) mods_set_on(i, on);
        ImGui::PopID();
    }
    opt_section("Folder");
    char url[1600];
    if (opt_action("Open the mods folder", "", how) && mods_dir_url(url, sizeof url)) SDL_OpenURL(url);
    opt_end();
}

// Quit: out to the desktop, after asking (progress since the last save is lost); B / Esc or Cancel backs out.
static void tab_quit(float scale, bool in_game) {
    static bool ask, was_ask;
    static int focus;  // frames left to put the cursor on the first button: the one pressed went away, and a controller
                       // had no cursor left on the page (a player: "use the mouse to click the last OK to exit")
    if (ask && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
        ask = false;
    if (ask != was_ask) was_ask = ask, focus = 2;
    const char *d = in_game ? "Closes " RT_APP_NAME ".\n\nProgress since your last save is lost." : "Closes " RT_APP_NAME ".";
    opt_begin("##quit", scale);
    opt_section("Exit");
    if (focus > 0) ImGui::SetKeyboardFocusHere(), ImGui::SetNavCursorVisible(true), focus--;
    if (!ask) {
        if (opt_action("Exit to Desktop", "", d)) ask = true;
    } else {
        if (opt_action("Yes, exit to Desktop", "", d)) {
            settings_save();
            SDL_Event q = {};
            q.type = SDL_EVENT_QUIT;
            SDL_PushEvent(&q);
            ask = false;
        }
        if (opt_action("Cancel", "", "Stays where you are.")) ask = false;
    }
    opt_end();
}

static void tab_about(void) {
    float scale = ImGui::GetFontSize() / 34;
    opt_begin("##controls", scale);
    opt_section("System language");
    {
        // what the game is told the console's language is: its text follows this (runtime/settings.c)
        char autol[64];
        snprintf(autol, sizeof autol, "Auto (%s)", settings_language_name());
        const char *names[N_LANGUAGES];
        names[0] = autol;
        for (int i = 1; i < N_LANGUAGES; i++) names[i] = g_language_names[i];
        if (opt_choice("Language", &g_settings.language, names, N_LANGUAGES, 0,
                       "The game's text language, as its own system setting. Applies the next time the game starts."))
            settings_save();
    }
    opt_section("Controller");
    if (opt_toggle("Vibration", &g_settings.rumble, true,
                   "The controller's rumble, as the game sends it (the Switch's HD rumble on the controller's motors)."))
        settings_save();
    {
        static const int pct[] = {0, 5, 10, 15, 20, 25, 30};
        static const char *const names[] = {"Off", "5%", "10%", "15%", "20%", "25%", "30%"};
        int i = 0;
        for (int k = 0; k < 7; k++) if (pct[k] <= g_settings.stick_deadzone) i = k;
        if (opt_choice("Stick deadzone", &i, names, 7, 0,
                       "How far a controller stick moves before it counts. Raise it if Mario or the camera drifts on "
                       "their own.", false)) {
            g_settings.stick_deadzone = pct[i];
            settings_save();
        }
    }
    {
        static const char *const names[] = {"Auto", "Nintendo", "Xbox / PS"};
        int v = g_settings.face_layout;
        if (opt_choice("Button layout", &v, names, 3, 0,
                       "Which face button is which. Nintendo: as on a Switch controller, the right button is A (on an "
                       "Xbox controller that's B). Xbox / PS: the button named A (Cross) is A, B (Circle) is B, X "
                       "(Square) is X, Y (Triangle) is Y - in the game and in these menus. Auto: Xbox / PS on those "
                       "controllers, Nintendo on the others.")) {
            g_settings.face_layout = v;
            settings_save();
        }
    }
    {
        static const char *const names[] = {"Auto", "Nintendo", "Xbox", "PlayStation"};
        int v = g_settings.button_icons;
        if (opt_choice("Button icons in the game", &v, names, 4, 0,
                       "The buttons the game shows in its prompts and menus, drawn as the buttons of your controller "
                       "(Xbox: A B X Y, LB RB LT RT; PlayStation: Cross Circle Square Triangle, L1 R1 L2 R2), for the "
                       "button that does it with your bindings. Auto: your controller's.")) {
            g_settings.button_icons = v;
            settings_save();
        }
    }
    opt_section("Mouse and keyboard");
    if (opt_toggle("Mouse camera", &g_settings.mouse_camera, true,
                   "Click in the game's window and the mouse is the game's: moving it turns the camera, its buttons "
                   "do what the Mouse column below says (left: throw Cappy, right: crouch, middle: camera behind "
                   "Mario). F1 or Esc (this menu) or switching to another window lets it go; click again to take it "
                   "back. The keyboard: WASD to move, the rest in the table below."))
        settings_save();
    {
        int s = g_settings.mouse_sens;
        if (opt_int("Mouse sensitivity", &s, 25, 1000, 25, 100, "%d%%",
                    "How fast the camera turns for a move of the mouse. 100%: a quick flick turns it at the game's "
                    "top speed; above that the camera turns faster than a stick can.")) {
            g_settings.mouse_sens = s;
            settings_save();
        }
    }
    if (opt_toggle("Invert mouse up / down", &g_settings.mouse_invert_y, false,
                   "Moving the mouse up turns the camera down, as with an inverted stick."))
        settings_save();
    opt_section("Bindings");
    controls_bindings_draw(scale);
    opt_section("This menu");
    ImGui::PushStyleColor(ImGuiCol_Text, kTextDimV);
    ImGui::PushTextWrapPos(0);
    ImGui::TextUnformatted("Open / close: F1, Esc, the controller's Home / Xbox / PS button, or Back + Start held "
                           "together. Sections: LB / RB (Q / E). Back: B (Esc) - from a section up to the bar, then "
                           "back to the game. Fullscreen: F11 / Alt+Enter.");
    ImGui::PopTextWrapPos();
    ImGui::PopStyleColor();
    opt_end();
}

// Reboot (runtime/main.c): the game is gone - menu and name dialog close; the ImGui context stays.
RT_ON_RESET(menu_reset) {
    set_open(false);
    g_kbd = 0;
    osk_cancel();
    pthread_mutex_lock(&q_lock);
    q_events.clear();
    pthread_mutex_unlock(&q_lock);
}

static void keyboard_draw(ImGuiIO &io, float scale) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 120));
    float w = fminf(io.DisplaySize.x * 0.9f, 1100 * scale);
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, 0), ImGuiCond_Always);
    ImGui::Begin("##kbd", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                    ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PushFont(g_font_big);
    ImGui::TextUnformatted("Enter your name");
    ImGui::PopFont();
    static bool was_open, was_pad;
    bool pad = g_last_pad.load(), appearing = !was_open || pad != was_pad;  // (switching device: focus the new one)
    was_open = true, was_pad = pad;
    if (!pad) {  // keyboard: type straight into the field
        if (appearing) ImGui::SetKeyboardFocusHere();
        ImGui::SetNextItemWidth(-1);
        ImGui::PushFont(g_font_big);
        ImGui::InputText("##name", g_kbd_text, (size_t)(g_kbd_max * 4 + 1 < (int)sizeof g_kbd_text ? g_kbd_max * 4 + 1 : sizeof g_kbd_text),
                         ImGuiInputTextFlags_CallbackCharFilter,
                         [](ImGuiInputTextCallbackData *d) -> int { return d->EventChar < 0x20 ? 1 : 0; });
        ImGui::PopFont();
        if ((int)strlen(g_kbd_text) > g_kbd_max) g_kbd_text[g_kbd_max] = 0;
        ImGui::TextDisabled("Enter  confirm      Esc  cancel      (%d / %d)", (int)strlen(g_kbd_text), g_kbd_max);
    } else {  // controller: on-screen keyboard (osk.mm, shared with our menus' text fields)
        int r = osk_keys(g_kbd_text, sizeof g_kbd_text, g_kbd_max, appearing, scale, g_font_big);
        if (r) g_kbd = r > 0 ? 2 : 3;  // (Start / + confirms in menu_handle_event too)
    }
    ImGui::End();
    if (g_kbd.load() != 1) was_open = false;
}

static void notice_draw(ImGuiIO &io, float scale) {
    ImGui::GetBackgroundDrawList()->AddRectFilled(ImVec2(0, 0), io.DisplaySize, IM_COL32(0, 0, 0, 140));
    float w = fminf(io.DisplaySize.x * 0.9f, 1000 * scale);
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, 0), ImGuiCond_Always);
    ImGui::Begin("##note", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                     ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PushFont(g_menu_font_big);
    ImGui::TextUnformatted(g_note_title);
    ImGui::PopFont();
    ImGui::PushFont(g_menu_font);
    ImGui::Spacing();
    ImGui::PushTextWrapPos(0);
    ImGui::TextUnformatted(g_note_text);
    ImGui::PopTextWrapPos();
    ImGui::Spacing();
    static bool was_open;
    if (!was_open) ImGui::SetKeyboardFocusHere(), ImGui::SetNavCursorVisible(true);  // (the controller's cursor on OK)
    was_open = true;
    // OK: clicked, A on it, or any face button / + (only one choice: whichever the player's layout calls A)
    if (ImGui::Button("OK", ImVec2(200 * scale, 0)) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
        ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown, false) || ImGui::IsKeyPressed(ImGuiKey_GamepadStart, false))
        g_note = 2;
    ImGui::PopFont();
    ImGui::End();
    if (g_note.load() != 1) was_open = false;
}

// Game thread (runtime/hle/applets.c): the notice over the last frame until the player closes it.
extern "C" void menu_notice_run(const char *title, const char *text) {
    extern void backend_represent(void);
    snprintf(g_note_title, sizeof g_note_title, "%s", title);
    snprintf(g_note_text, sizeof g_note_text, "%s", text);
    input_reset();
    g_note = 1;
    while (g_note.load() == 1 && !g_rt_unwind) {  // ~60 Hz (a reboot closes it)
        uint64_t t0 = SDL_GetTicks();
        backend_represent();
        uint64_t dt = SDL_GetTicks() - t0;
        if (dt < 16) SDL_Delay((uint32_t)(16 - dt));
    }
    g_note = 0;
    input_reset();  // (the button that closed it doesn't reach the game)
}

// Game thread (runtime/hle/swkbd.c): show the dialog, re-present the last frame until it's answered.
// Returns 1 confirmed (out = text, UTF-8), 0 cancelled.
extern "C" int menu_keyboard_run(const char *initial, int max_len, char *out, int cap) {
    extern void backend_represent(void);
    snprintf(g_kbd_text, sizeof g_kbd_text, "%s", initial ? initial : "");
    g_kbd_max = max_len > 0 && max_len < (int)sizeof g_kbd_text / 4 ? max_len : 8;
    input_reset();
    g_kbd = 1;
    // (test) ODYSSEY_KBD_AUTO=<text>: answer at once
    if (getenv("ODYSSEY_KBD_AUTO")) { snprintf(g_kbd_text, sizeof g_kbd_text, "%s", getenv("ODYSSEY_KBD_AUTO")); g_kbd = 2; }
    while (g_kbd.load() == 1 && !g_rt_unwind) {  // ~60 Hz (a reboot cancels)
        uint64_t t0 = SDL_GetTicks();
        backend_represent();
        uint64_t dt = SDL_GetTicks() - t0;
        if (dt < 16) SDL_Delay((uint32_t)(16 - dt));
    }
    bool ok = g_kbd.load() == 2 && g_kbd_text[0];
    if (ok) snprintf(out, cap, "%s", g_kbd_text);
    g_kbd = 0;
    input_reset();
    return ok;
}

// The menu's sections (tabs_body below).
static bool g_back_consumed;   // this frame's B / Esc took the cursor from a page back to the list: not a close
static bool g_close_request;   // Resume / Back on the list (menu_tabs_close_requested: the launcher's panel)
bool menu_tabs_close_requested(void) { bool r = g_close_request; g_close_request = false; return r; }

// a page's picture, centred at c, about 2r across
static void nav_icon(ImDrawList *dl, int id, ImVec2 c, float r, ImU32 col) {
    float t = fmaxf(r * 0.16f, 1.5f);
    switch (id) {
    case -3:  // resume: play
        dl->AddTriangleFilled(ImVec2(c.x - r * 0.5f, c.y - r * 0.7f), ImVec2(c.x + r * 0.75f, c.y), ImVec2(c.x - r * 0.5f, c.y + r * 0.7f), col);
        break;
    case 8:  // controls: a controller
        dl->AddRect(ImVec2(c.x - r, c.y - r * 0.5f), ImVec2(c.x + r, c.y + r * 0.45f), col, r * 0.45f, 0, t);
        dl->AddLine(ImVec2(c.x - r * 0.62f, c.y - r * 0.02f), ImVec2(c.x - r * 0.25f, c.y - r * 0.02f), col, t);
        dl->AddLine(ImVec2(c.x - r * 0.435f, c.y - r * 0.2f), ImVec2(c.x - r * 0.435f, c.y + r * 0.16f), col, t);
        dl->AddCircleFilled(ImVec2(c.x + r * 0.4f, c.y - r * 0.12f), r * 0.11f, col, 10);
        dl->AddCircleFilled(ImVec2(c.x + r * 0.6f, c.y + r * 0.08f), r * 0.11f, col, 10);
        break;
    case 0:  // video: a screen on a stand
        dl->AddRect(ImVec2(c.x - r, c.y - r * 0.7f), ImVec2(c.x + r, c.y + r * 0.45f), col, r * 0.12f, 0, t);
        dl->AddLine(ImVec2(c.x, c.y + r * 0.45f), ImVec2(c.x, c.y + r * 0.75f), col, t);
        dl->AddLine(ImVec2(c.x - r * 0.45f, c.y + r * 0.78f), ImVec2(c.x + r * 0.45f, c.y + r * 0.78f), col, t);
        break;
    case 1:  // audio: a speaker with waves
        dl->AddQuadFilled(ImVec2(c.x - r, c.y - r * 0.3f), ImVec2(c.x - r * 0.55f, c.y - r * 0.3f), ImVec2(c.x - r * 0.55f, c.y + r * 0.3f), ImVec2(c.x - r, c.y + r * 0.3f), col);
        dl->AddTriangleFilled(ImVec2(c.x - r * 0.6f, c.y - r * 0.3f), ImVec2(c.x - r * 0.05f, c.y - r * 0.75f), ImVec2(c.x - r * 0.05f, c.y + r * 0.75f), col);
        dl->AddTriangleFilled(ImVec2(c.x - r * 0.6f, c.y - r * 0.3f), ImVec2(c.x - r * 0.05f, c.y + r * 0.75f), ImVec2(c.x - r * 0.6f, c.y + r * 0.3f), col);
        dl->PathArcTo(c, r * 0.5f, -0.8f, 0.8f, 12); dl->PathStroke(col, 0, t);
        dl->PathArcTo(c, r * 0.85f, -0.8f, 0.8f, 16); dl->PathStroke(col, 0, t);
        break;
    case 2:  // mods: four blocks
        for (int i = 0; i < 4; i++) {
            float x = c.x + (i % 2 ? r * 0.08f : -r * 0.86f), y = c.y + (i / 2 ? r * 0.08f : -r * 0.86f);
            if (i == 3) dl->AddRect(ImVec2(x, y), ImVec2(x + r * 0.78f, y + r * 0.78f), col, r * 0.15f, 0, t);
            else dl->AddRectFilled(ImVec2(x, y), ImVec2(x + r * 0.78f, y + r * 0.78f), col, r * 0.15f);
        }
        break;
    case 9:  // quit: power
        dl->PathArcTo(c, r * 0.72f, -3.14159f * 0.5f + 0.7f, 3.14159f * 1.5f - 0.7f, 24);
        dl->PathStroke(col, 0, t * 1.1f);
        dl->AddLine(ImVec2(c.x, c.y - r * 0.95f), ImVec2(c.x, c.y - r * 0.15f), col, t * 1.1f);
        break;
    default:
        dl->AddCircle(c, r * 0.6f, col, 16, t);
    }
}

static void tabs_body(float scale, bool in_game, void (*prelaunch)(float)) {
    // Odyssey Recomp's own pause screen (2026-11-10, the player: "change everything, ours"): a bar along the top - our
    // icon and name, the sections as pills side by side, Continue at the right - and the open section below it in one
    // centred column. LB / RB (Q / E) or the cursor along the bar switch sections; A / Down goes into one; B / Esc in a
    // section comes back up to the bar, B on the bar continues the game. in_game false: the start screen's panel
    // (launcher.mm) - "Back" instead of "Continue".
    struct Tab { const char *name, *sub; int id; };
    Tab tabs[10];
    int ntabs = 0;
    if (prelaunch) tabs[ntabs++] = {"Prelaunch", "", -1};
    tabs[ntabs++] = {"Display", "Screen, image quality and picture", 0};
    tabs[ntabs++] = {"Sound", "Volume and effects", 1};
    tabs[ntabs++] = {"Input", "Language, controllers, mouse and keyboard", 8};
    tabs[ntabs++] = {"Add-ons", "Mods for the game's files", 2};
    if (!prelaunch) tabs[ntabs++] = {"Exit", "Leave " RT_APP_NAME, 9};
    if (g_tab_request_ext >= 0) { g_tab_request = g_tab_request_ext; g_tab_request_ext = -1; }
    if (g_tab_request != -2) {
        for (int i = 0; i < ntabs; i++) if (tabs[i].id == g_tab_request) g_tab = g_tab_request;
        g_tab_request = -2;
    }
    int cur = -1;
    for (int i = 0; i < ntabs; i++) if (tabs[i].id == g_tab) cur = i;
    if (cur < 0) { cur = 0; g_tab = tabs[cur].id; }
    bool any_popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId), typing = ui_text_busy();
    if (!any_popup && !typing) {  // LB / RB (Q / E): the section before / after
        int step = ImGui::IsKeyPressed(ImGuiKey_GamepadR1, false) || ImGui::IsKeyPressed(ImGuiKey_E, false) ? 1
                 : ImGui::IsKeyPressed(ImGuiKey_GamepadL1, false) || ImGui::IsKeyPressed(ImGuiKey_Q, false) ? -1 : 0;
        if (step) {
            cur = (cur + step + ntabs) % ntabs;
            g_tab = tabs[cur].id;
            g_focus_tab = g_tab, g_focus_frames = 0;
        }
    }
    g_back_consumed = false;
    ImVec2 avail = ImGui::GetContentRegionAvail();
    float bar_h = 70 * scale, fs = ImGui::GetFontSize();
    ImGui::BeginChild("##bar", ImVec2(avail.x, bar_h), ImGuiChildFlags_None,
                      ImGuiWindowFlags_NavFlattened | ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoScrollbar);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImVec2 o = ImGui::GetCursorScreenPos();
    float x = o.x;
    {   // the project's own icon (docs/icon, tools/make_icon.py: a red ring and a white compass star, as on the GitHub
        // banner) and the name - not the game's logo (2026-11-11, the player)
        float d = bar_h * 0.98f, u = d / 1024.0f, rout = (337.92f + 40.96f) * u;  // the 1024 drawing, ring's outer edge
        float cx = x + rout + 2 * scale, cy = o.y + bar_h * 0.5f;
        dl->AddCircle(ImVec2(cx, cy), 337.92f * u, IM_COL32(0xE5, 0x38, 0x3B, 255), 64, 81.92f * u);
        float r1 = 240.64f * u, r2 = 63.49f * u;  // the star's long and short points (512-271.36, 556.893-512 x sqrt2)
        ImVec2 pts[8];
        for (int i = 0; i < 8; i++) {
            float a = i * 0.785398f - 1.570796f, r = (i & 1) ? r2 : r1;
            pts[i] = ImVec2(cx + cosf(a) * r, cy + sinf(a) * r);
        }
        for (int i = 0; i < 8; i += 2) {  // four convex wedges: centre, point, the short points either side
            ImVec2 q[4] = {ImVec2(cx, cy), pts[(i + 7) % 8], pts[i], pts[i + 1]};
            dl->AddConvexPolyFilled(q, 4, IM_COL32(0xF2, 0xF6, 0xF8, 255));
        }
        x = cx + rout + 16 * scale;
        float ts = g_font_big->FontSize * 0.62f;
        dl->AddText(g_font_big, ts, ImVec2(x, cy - ts * 0.5f), kText, RT_APP_NAME);
        x += g_font_big->CalcTextSizeA(ts, FLT_MAX, 0, RT_APP_NAME).x + 30 * scale;
    }
    float ph = 50 * scale, ir = 11 * scale, py = o.y + (bar_h - ph) * 0.5f;
    auto pill = [&](int id, const char *name, float px, bool sel, bool main_action) -> bool {
        float tw = ImGui::CalcTextSize(name).x, pw = tw + ir * 2 + 52 * scale;
        ImGui::SetCursorScreenPos(ImVec2(px, py));
        ImGui::PushID(id + 100);
        ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
        bool hit = ImGui::InvisibleButton("##pill", ImVec2(pw, ph), ImGuiButtonFlags_EnableNav);
        ImGui::PopStyleColor();
        bool focus_here = g_focus_tab == id || ((g_focus_tab == -100 || g_focus_tab == -1) && id == g_tab);
        if (focus_here) {  // (the cursor put on this pill: menu opened, LB / RB, back from a section)
            ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
            ImGui::SetNavCursorVisible(true);
            if (++g_focus_frames >= 3) g_focus_tab = -99, g_focus_frames = 0;
        }
        bool foc = ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible, hov = ImGui::IsItemHovered();
        ImVec2 a(px, py), b(px + pw, py + ph);
        float rr = ph * 0.5f;
        if (main_action) dl->AddRectFilled(a, b, theme_u32(kActionV, foc || hov ? 1.0f : 0.85f), rr);
        else if (sel) dl->AddRectFilled(a, b, theme_u32(kAccentV), rr);
        else if (hov || foc) dl->AddRectFilled(a, b, IM_COL32(255, 255, 255, 22), rr);
        if (foc) dl->AddRect(ImVec2(a.x - 3 * scale, a.y - 3 * scale), ImVec2(b.x + 3 * scale, b.y + 3 * scale),
                             theme_u32(main_action || sel ? kTextV : kAccentV), rr + 3 * scale, 0, 2.5f * scale);
        ImU32 ink = main_action ? kText : sel ? theme_u32(kPanelV, 1) : foc || hov ? kText : kTextDim;
        nav_icon(dl, id, ImVec2(px + 22 * scale + ir, py + ph * 0.5f), ir, ink);
        dl->AddText(ImVec2(px + 22 * scale + ir * 2 + 12 * scale, py + (ph - fs) * 0.5f), ink, name);
        ImGui::PopID();
        // (moving along the bar shows each section - not while the cursor is being put on a pill: ImGui's own first
        // focus lands on the first pill when the menu opens, and took the section asked for away)
        if (foc && !main_action && id != g_tab && g_focus_tab == -99) g_tab = id;
        return hit || (foc && (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadDown) || ImGui::IsKeyPressed(ImGuiKey_DownArrow)));
    };
    for (int k = 0; k < ntabs; k++) {
        const Tab &t = tabs[k];
        float tw = ImGui::CalcTextSize(t.name).x;
        if (pill(t.id, t.name, x, t.id == g_tab, false)) {
            g_tab = t.id, cur = k;
            opt_focus_first(true);  // (into the section: its first card takes the cursor)
        }
        if (t.id == g_tab) cur = k;
        x += tw + ir * 2 + 52 * scale + 10 * scale;
    }
    {   // Continue / Back, at the right end
        const char *cn = in_game ? "Continue" : "Back";
        float cw = ImGui::CalcTextSize(cn).x + ir * 2 + 52 * scale;
        if (pill(-3, cn, o.x + avail.x - cw - 4 * scale, false, true)) {
            if (in_game) set_open(false);
            else g_close_request = true;
        }
    }
    // B / Esc on the bar: continue (the launcher: back)
    if (ImGui::IsWindowFocused() && !any_popup && !typing &&
        (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false))) {
        if (in_game) set_open(false);
        else g_close_request = true;
        g_back_consumed = true;
    }
    ImGui::EndChild();
    {   // a hairline under the bar
        ImVec2 p = ImGui::GetCursorScreenPos();
        ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x, p.y + 4 * scale), ImVec2(p.x + avail.x, p.y + 4 * scale), theme_u32(kLineV), 1.0f);
        ImGui::Dummy(ImVec2(avail.x, 18 * scale));
    }

    // the section, in a centred column
    float cw = fminf(avail.x, 1180 * scale);
    ImGui::SetCursorPosX(ImGui::GetCursorPosX() + (avail.x - cw) * 0.5f);
    ImGui::BeginChild("##content", ImVec2(cw, 0), ImGuiChildFlags_None, ImGuiWindowFlags_NavFlattened | ImGuiWindowFlags_NoBackground);
    {   // the section's name and what it holds
        ImGui::PushFont(g_font_big);
        ImGui::TextUnformatted(tabs[cur].name);
        ImGui::PopFont();
        ImGui::PushStyleColor(ImGuiCol_Text, kTextDimV);
        ImGui::TextUnformatted(tabs[cur].sub);
        ImGui::PopStyleColor();
        ImGui::Dummy(ImVec2(0, 10 * scale));
    }
    bool page_focused = false;
    ImGui::BeginChild("##page", ImVec2(0, 0), ImGuiChildFlags_None, ImGuiWindowFlags_NavFlattened | ImGuiWindowFlags_NoBackground);
    switch (tabs[cur].id) {
    case -1: prelaunch(scale); break;
    case 0: tab_display(); break;
    case 1: tab_audio(); break;
    case 2: tab_mods(scale); break;
    case 8: tab_about(); break;
    case 9: tab_quit(scale, in_game); break;
    }
    static const char *scroll_test = getenv("ODYSSEY_MENU_SCROLL");  // test hook: page scroll, 0..1
    if (scroll_test) ImGui::SetScrollY(ImGui::GetScrollMaxY() * (float)atof(scroll_test));
    page_focused = ImGui::IsWindowFocused(ImGuiFocusedFlags_ChildWindows);
    ImGui::EndChild();
    ImGui::EndChild();
    opt_focus_first(false);  // (a section without cards: nothing took it)
    // B / Esc in a section: back up to the bar (the section's own pill)
    if (page_focused && !g_back_consumed && !any_popup && !typing && !ui_text_busy() &&
        (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false))) {
        g_focus_tab = g_tab, g_focus_frames = 0;
        g_back_consumed = true;
    }
}

void menu_tabs_draw(float scale, ImFont *font, ImFont *font_big, bool in_game, void (*prelaunch)(float)) {
    ImFont *f0 = g_font, *f1 = g_font_big;
    g_font = font, g_font_big = font_big;
    ImGuiStyle saved = ImGui::GetStyle();  // the menu's look (another UI may have its own style)
    style_init();
    ImGui::GetStyle().ScaleAllSizes(scale);
    tabs_body(scale, in_game, prelaunch);
    ImGui::GetStyle() = saved;
    g_font = f0, g_font_big = f1;
}

#ifdef __APPLE__
void menu_render(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    const double tw = target.width, th = target.height;
#else
void menu_render(void *cmd, uint32_t target_w, uint32_t target_h) {
    const double tw = target_w, th = target_h;
#endif
    bool open = g_open.load(), setup = g_setup.load(), launcher = g_launcher.load();
    bool kbd = g_kbd.load() == 1, note = g_note.load() == 1;
    if (!open && !kbd && !note && !setup && !launcher && !g_settings.show_fps) {
        if (g_inited) { pthread_mutex_lock(&q_lock); q_events.clear(); pthread_mutex_unlock(&q_lock); }
        return;
    }
#ifdef __APPLE__
    if (!g_inited) init(dev);
#else
    if (!g_inited) init();
#endif
    ImGui::SetCurrentContext(g_ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)tw, (float)th);
    io.DisplayFramebufferScale = ImVec2(1, 1);
    static double last;
    double now = SDL_GetTicks() / 1000.0;
    io.DeltaTime = last > 0 && now > last ? (float)(now - last) : 1.0f / 60;
    last = now;
    drain_events(io);
    // fonts are built at 34/56 px for a ~1080 px tall output; scale to the window
    float scale = (float)(th / 1080.0);
    if (scale < 0.45f) scale = 0.45f;
    io.FontGlobalScale = scale;

#ifdef __APPLE__
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
#endif
    // spacing/rounding follow the output size too (style tuned for 1080 p)
    static ImGuiStyle base;
    static float style_scale = -1;
    if (style_scale < 0) base = ImGui::GetStyle();
    if (fabsf(style_scale - scale) > 0.01f) {
        ImGui::GetStyle() = base;
        ImGui::GetStyle().ScaleAllSizes(scale);
        style_scale = scale;
    }
#ifdef __APPLE__
    ImGui_ImplMetal_NewFrame(rp);
#else
    ImGui_ImplVulkan_NewFrame();
#endif
    ImGui::NewFrame();

    if (setup) {
        setup_draw(scale, g_menu_font, g_menu_font_big);
        open = false;
    } else if (launcher) {
        launcher_draw(scale, g_menu_font, g_menu_font_big);
        open = false;
    } else if (g_settings.show_fps) {
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - 16 * scale, 16 * scale), 0, ImVec2(1, 0));
        ImGui::SetNextWindowBgAlpha(0.35f);
        ImGui::Begin("##fps", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize |
                                        ImGuiWindowFlags_NoInputs | ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
        ImGui::Text("%.0f fps", io.Framerate);
        // Video tab "Frame time graph": the last 240 presents' intervals, 0..50 ms, a line at 16.7 ms
        static float times[240];
        static int at;
        times[at] = io.DeltaTime * 1000.0f;
        at = (at + 1) % 240;
        if (g_settings.frame_graph) {
            float gw = 200 * scale, gh = 40 * scale, worst = 0;  // (small: the game's life meter is under it)
            for (float t : times) worst = fmaxf(worst, t);
            ImVec2 p = ImGui::GetCursorScreenPos();
            ImDrawList *dl = ImGui::GetWindowDrawList();
            dl->AddRectFilled(p, ImVec2(p.x + gw, p.y + gh), IM_COL32(0, 0, 0, 90), 4 * scale);
            float y60 = p.y + gh - gh * 16.7f / 50.0f;
            dl->AddLine(ImVec2(p.x, y60), ImVec2(p.x + gw, y60), IM_COL32(120, 200, 230, 110), 1.0f);
            for (int i = 0; i < 240; i++) {
                float t = times[(at + i) % 240], x = p.x + gw * i / 240.0f, h = gh * fminf(t, 50.0f) / 50.0f;
                ImU32 c = t > 25 ? IM_COL32(240, 80, 80, 255) : t > 18 ? IM_COL32(240, 200, 80, 255) : IM_COL32(110, 220, 140, 255);
                dl->AddRectFilled(ImVec2(x, p.y + gh - h), ImVec2(x + gw / 240.0f + 0.5f, p.y + gh), c);
            }
            ImGui::Dummy(ImVec2(gw, gh));
            ImGui::Text("worst %.1f ms", worst);
        }
        ImGui::End();
    }

    if (open) {
        // the game dimmed behind the menu, darker towards the bottom; the menu a large rounded panel: the bar on top,
        // the section below
        ImGui::GetBackgroundDrawList()->AddRectFilledMultiColor(ImVec2(0, 0), io.DisplaySize, IM_COL32(4, 18, 28, 150),
                                                                IM_COL32(4, 18, 28, 150), IM_COL32(2, 8, 14, 205), IM_COL32(2, 8, 14, 205));
        float w = fminf(io.DisplaySize.x - 2 * 28 * scale, 1760 * scale), h = io.DisplaySize.y - 2 * 28 * scale;
        ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
        ImGui::SetNextWindowSize(ImVec2(w, h), ImGuiCond_Always);
        ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24 * scale, 24 * scale));
        ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 22 * scale);
        ImGui::Begin("##menu", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
        ImGui::PopStyleVar(2);
        ImFont *keep_big = g_font_big;  // (the window in the menu's font; the page titles use g_font_big)
        g_font_big = g_menu_font_big;
        ImGui::PushFont(g_menu_font);
        tabs_body(scale, true, NULL);  // (B / Esc: tabs_body - a page back to the list, the list out)
        ImGui::PopFont();
        g_font_big = keep_big;
        ImGui::End();
        osk_draw(g_font_big, scale);  // (a text field activated with the controller)
    }

    if (kbd) keyboard_draw(io, scale);
    if (note && !open) notice_draw(io, scale);  // (the menu opened over it: the notice waits behind it)
    ImGui::Render();
    g_text_busy = (open || launcher) && ui_text_busy();
#ifdef __APPLE__
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
#else
    ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)cmd);  // inside the window image's rendering
#endif
    g_drawn = true;
}

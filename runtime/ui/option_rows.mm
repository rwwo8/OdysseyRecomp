// Settings pages (see option_rows.h), Odyssey Recomp's own look: one column of cards. Each card is a setting - its name
// on the left, its value on the right as the kind of thing it is: a switch (on / off), pills (a few choices, all in
// view, the chosen one filled), a bar (a number in a range) or a value between two round arrows (longer lists). The
// card under the cursor (controller) or the mouse opens up and shows what the setting does, under its name.
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>

#include "imgui.h"
#include "imgui_internal.h"  // (SetKeyOwner, NavCursorVisible)

#include "option_rows.h"
#include "osk.h"
#include "theme.h"

static float g_scale = 1;
static bool g_next_disabled;
void opt_disable_next(void) { g_next_disabled = true; }
static int g_indent;
static bool g_focus_req, g_take_first;  // (opt_focus_first: requested / this page's first card takes it)
void opt_focus_first(bool on) { g_focus_req = on; }
static bool g_held;  // the last card's left / right has been held a while (steppers go faster)
void opt_indent(int step) { g_indent = g_indent + step < 0 ? 0 : g_indent + step; }

void opt_begin(const char *id, float scale) {
    g_scale = scale;
    g_take_first = g_focus_req;
    g_focus_req = false;
    if (g_take_first) ImGui::NavMoveRequestCancel();  // (this frame's move goes to the first card instead)
    g_indent = 0;
    ImGui::PushID(id);
    ImGui::BeginChild("##cards", ImVec2(0, 0), ImGuiChildFlags_None, ImGuiWindowFlags_NavFlattened);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(ImGui::GetStyle().ItemSpacing.x, 8 * scale));
}

// A section: its name in small spaced capitals, a hairline running on to the right
void opt_section(const char *title) {
    if (ImGui::GetCursorPosY() > ImGui::GetStyle().WindowPadding.y + 1) ImGui::Dummy(ImVec2(0, 16 * g_scale));
    std::string t = title;
    for (char &c : t) c = (char)toupper((unsigned char)c);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImFont *f = ImGui::GetFont();
    float size = ImGui::GetFontSize() * 0.72f, sp = 3 * g_scale, x = 0;
    ImVec2 p = ImGui::GetCursorScreenPos();
    for (char c : t) {
        char one[2] = {c, 0};
        dl->AddText(f, size, ImVec2(p.x + x, p.y), theme_u32(kAccentV), one);
        x += f->CalcTextSizeA(size, FLT_MAX, 0, one).x + sp;
    }
    float w = ImGui::GetContentRegionAvail().x, ly = p.y + size * 0.55f;
    if (p.x + x + 12 * g_scale < p.x + w) dl->AddLine(ImVec2(p.x + x + 10 * g_scale, ly), ImVec2(p.x + w, ly), theme_u32(kLineV), 1.0f);
    ImGui::Dummy(ImVec2(w, size + 4 * g_scale));
}

// What a card shows on its right
enum { K_TEXT, K_ARROWS, K_SWITCH, K_PILLS, K_BAR };
typedef struct {
    int kind;
    std::string value;
    bool on;                      // K_SWITCH
    const char *const *names;     // K_PILLS
    int n, cur;
    float frac;                   // K_BAR: where the value is in its range, 0..1
} Look;

static float pills_width(const Look &lk, float fs, float pad) {
    float w = 0;
    for (int i = 0; i < lk.n; i++) w += ImGui::CalcTextSize(lk.names[i]).x * 0.86f + pad * 2;
    return w + 4 * g_scale;
}

// One card. Returns 2 (A / click), -1 / +1 (left / right), 3 + i (a pill clicked: choice i) or 0.
static int card(const char *label, const Look &lk, bool changed, const char *desc, bool upper = false) {
    ImGui::PushID(label);
    if (g_indent) ImGui::SetCursorPosX(ImGui::GetCursorPosX() + g_indent * 30 * g_scale);
    ImGuiID sid = ImGui::GetID("##open");
    bool open = ImGui::GetStateStorage()->GetBool(sid, false);  // (the frame before: lit - the card is taller)
    ImVec2 p = ImGui::GetCursorScreenPos();
    float w = ImGui::GetContentRegionAvail().x, fs = ImGui::GetFontSize(), pad = 22 * g_scale, base = fs * 2.15f;
    ImFont *font = ImGui::GetFont();
    float ds = fs * 0.78f, dh = 0;
    if (open && desc && *desc) dh = font->CalcTextSizeA(ds, FLT_MAX, w - 2 * pad, desc).y + fs * 0.55f;
    float h = base + dh;
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));  // (the card's own ring shows the cursor)
    bool clicked = ImGui::InvisibleButton("##card", ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    if (g_take_first) {
        g_take_first = false;
        ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
        ImGui::SetNavCursorVisible(true);
        ImGui::SetScrollHereY(0);
    }
    bool off = g_next_disabled;
    g_next_disabled = false;
    bool hov = ImGui::IsItemHovered(), foc = ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible;
    int step = clicked && !off ? 2 : 0;
    g_held = false;
    if (foc && !off) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft) ||
            ImGui::IsKeyPressed(ImGuiKey_LeftArrow))
            step = -1;
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) ||
            ImGui::IsKeyPressed(ImGuiKey_RightArrow))
            step = 1;
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_GamepadLStickLeft,
                           ImGuiKey_GamepadLStickRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            if (ImGui::GetKeyData(k)->DownDuration > 1.0f) g_held = true;
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            ImGui::SetKeyOwner(k, ImGui::GetItemID());
    }
    bool lit = hov || foc;
    ImGui::GetStateStorage()->SetBool(sid, lit);

    ImDrawList *dl = ImGui::GetWindowDrawList();
    float r = 14 * g_scale;
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), theme_u32(lit ? kSurfaceHoverV : kSurfaceV, lit ? 1.0f : 0.72f), r);
    if (foc) dl->AddRect(p, ImVec2(p.x + w, p.y + h), theme_u32(kAccentV), r, 0, 2.5f * g_scale);
    std::string t = label;
    if (upper) for (char &c : t) c = (char)toupper((unsigned char)c);
    float ty = p.y + (base - fs) * 0.5f, cy = p.y + base * 0.5f;
    dl->AddText(ImVec2(p.x + pad, ty), off ? kTextOff : kText, t.c_str());
    if (changed && !off) dl->AddCircleFilled(ImVec2(p.x + pad * 0.5f, cy), 3.5f * g_scale, theme_u32(kAccentV), 12);  // (not the default)
    float right = p.x + w - pad;
    ImU32 dim = off ? kTextOff : theme_u32(kTextV, 0.8f);
    float mx = ImGui::GetIO().MousePos.x;

    if (lk.kind == K_SWITCH) {
        float tw = fs * 1.9f, th = fs * 1.05f, tx = right - tw, tyy = cy - th * 0.5f;
        dl->AddRectFilled(ImVec2(tx, tyy), ImVec2(tx + tw, tyy + th), lk.on ? theme_u32(kAccentV, off ? 0.4f : 1.0f) : IM_COL32(255, 255, 255, 46), th * 0.5f);
        float kr = th * 0.5f - 3 * g_scale, kx = lk.on ? tx + tw - th * 0.5f : tx + th * 0.5f;
        dl->AddCircleFilled(ImVec2(kx, cy), kr, off ? IM_COL32(180, 190, 200, 160) : IM_COL32(255, 255, 255, 255), 24);
        dl->AddText(ImVec2(tx - fs * 0.5f - ImGui::CalcTextSize(lk.on ? "On" : "Off").x, ty), dim, lk.on ? "On" : "Off");
    } else if (lk.kind == K_PILLS) {
        float ppad = 16 * g_scale, pw = pills_width(lk, fs, ppad), ph = fs * 1.45f, x0 = right - pw, py = cy - ph * 0.5f;
        dl->AddRectFilled(ImVec2(x0, py), ImVec2(right, py + ph), IM_COL32(0, 0, 0, 70), ph * 0.5f);
        float x = x0 + 2 * g_scale, ts = fs * 0.86f;
        for (int i = 0; i < lk.n; i++) {
            float lw = ImGui::CalcTextSize(lk.names[i]).x * 0.86f + ppad * 2;
            bool sel = i == lk.cur;
            if (sel) dl->AddRectFilled(ImVec2(x, py + 2 * g_scale), ImVec2(x + lw, py + ph - 2 * g_scale),
                                       theme_u32(kAccentV, off ? 0.4f : 1.0f), (ph - 4 * g_scale) * 0.5f);
            dl->AddText(font, ts, ImVec2(x + ppad, cy - ts * 0.5f), sel ? IM_COL32(8, 30, 42, 255) : dim, lk.names[i]);
            if (clicked && !off && mx >= x && mx < x + lw) step = 3 + i;
            x += lw;
        }
    } else if (lk.kind == K_BAR || lk.kind == K_ARROWS) {
        // ( < value > ): round arrow buttons, a click on one steps; a bar under the value for a number in a range
        float br = fs * 0.5f, vw = ImGui::CalcTextSize(lk.value.c_str()).x, gap = fs * 0.55f;
        float bw = lk.kind == K_BAR ? fmaxf(fs * 5.0f, vw) : vw;
        float rx = right - br;                          // (the right arrow's centre)
        float lx = rx - br - gap - bw - gap - br * 2;   // (the left arrow's left edge)
        ImU32 ac = off ? kTextOff : lit ? theme_u32(kAccentV) : theme_u32(kTextV, 0.55f);
        for (int side = 0; side < 2; side++) {
            float bx = side ? rx : lx + br;
            dl->AddCircle(ImVec2(bx, cy), br, ac, 24, 1.6f * g_scale);
            float a = br * 0.35f, d = side ? 1.0f : -1.0f;
            dl->AddLine(ImVec2(bx - a * d * 0.6f, cy - a), ImVec2(bx + a * d * 0.6f, cy), ac, 2.2f * g_scale);
            dl->AddLine(ImVec2(bx + a * d * 0.6f, cy), ImVec2(bx - a * d * 0.6f, cy + a), ac, 2.2f * g_scale);
        }
        float vx = lx + br * 2 + gap;
        float vy = lk.kind == K_BAR ? cy - fs * 0.62f : ty;
        dl->AddText(ImVec2(vx + (bw - vw) * 0.5f, vy), off ? kTextOff : changed ? theme_u32(kAccentSoftV) : theme_u32(kTextV, 0.9f), lk.value.c_str());
        if (lk.kind == K_BAR) {
            float by = cy + fs * 0.5f, bh = 4 * g_scale;
            dl->AddRectFilled(ImVec2(vx, by), ImVec2(vx + bw, by + bh), IM_COL32(255, 255, 255, 40), bh);
            dl->AddRectFilled(ImVec2(vx, by), ImVec2(vx + bw * fminf(fmaxf(lk.frac, 0), 1), by + bh), theme_u32(kAccentV, off ? 0.4f : 1.0f), bh);
        }
        if (clicked && !off) {
            if (mx >= lx - 4 && mx <= lx + br * 2 + 4) step = -1;
            else if (mx >= rx - br - 4 && mx <= rx + br + 4) step = 1;
        }
    } else if (!lk.value.empty()) {
        float vw = ImGui::CalcTextSize(lk.value.c_str()).x;
        dl->AddText(ImVec2(right - vw, ty), off ? kTextOff : changed ? theme_u32(kAccentSoftV) : dim, lk.value.c_str());
    }
    if (dh > 0)  // the opened card: what the setting does
        dl->AddText(font, ds, ImVec2(p.x + pad, p.y + base - fs * 0.15f), theme_u32(kTextDimV), desc, NULL, w - 2 * pad);
    ImGui::PopID();
    return step;
}

bool opt_toggle(const char *label, bool *v, bool def, const char *desc) {
    Look lk = {K_SWITCH};
    lk.on = *v;
    if (!card(label, lk, *v != def, desc)) return false;  // (any press flips it)
    *v = !*v;
    return true;
}

bool opt_choice(const char *label, int *v, const char *const *names, int n, int def, const char *desc, bool wrap) {
    int cur = *v >= 0 && *v < n ? *v : 0;
    Look lk = {K_ARROWS};
    lk.value = names[cur];
    if (n <= 4) {  // a few: all in view as pills, if they fit in half the card
        Look pl = {K_PILLS};
        pl.names = names, pl.n = n, pl.cur = cur;
        if (pills_width(pl, ImGui::GetFontSize(), 16 * g_scale) < ImGui::GetContentRegionAvail().x * 0.55f) lk = pl;
    }
    int step = card(label, lk, cur != def, desc);
    if (!step) return false;
    int nv = step >= 3 ? step - 3 : cur + (step == 2 ? 1 : step);
    nv = wrap || step == 2 ? (nv + n) % n : nv < 0 ? 0 : nv >= n ? n - 1 : nv;
    if (nv == cur) return false;
    *v = nv;
    return true;
}

bool opt_slider(const char *label, float *v, float lo, float hi, float step, float def, const char *fmt, const char *desc) {
    char buf[32];
    snprintf(buf, sizeof buf, fmt, *v);
    Look lk = {K_BAR};
    lk.value = buf;
    lk.frac = hi > lo ? (*v - lo) / (hi - lo) : 0;
    int s = card(label, lk, fabsf(*v - def) > step * 0.01f, desc);
    if (!s) return false;
    float eps = step * 0.01f, n = roundf(*v / step) * step + (s == 2 ? step : s * step);
    if (s == 2 && n > hi + eps) n = lo;  // (A / click past the top wraps to the bottom; left / right stop at the ends)
    *v = n < lo ? lo : n > hi ? hi : n;
    return true;
}

bool opt_int(const char *label, int *v, int lo, int hi, int step, int def, const char *fmt, const char *desc,
             const char *lo_name) {
    char buf[48];
    if (lo_name && *v == lo) snprintf(buf, sizeof buf, "%s", lo_name);
    else snprintf(buf, sizeof buf, fmt, *v);
    Look lk = {K_BAR};
    lk.value = buf;
    lk.frac = hi > lo ? (float)(*v - lo) / (float)(hi - lo) : 0;
    int s = card(label, lk, *v != def, desc);
    if (!s) return false;
    int d = s == 2 ? step : s * step * (g_held && hi - lo > 40 * step ? 10 : 1);
    int n = *v + d;
    if (s == 2 && n > hi) n = lo;
    n = n < lo ? lo : n > hi ? hi : n;
    if (n == *v) return false;
    *v = n;
    return true;
}

bool opt_button(const char *label, const char *desc) {
    Look lk = {K_TEXT};
    return card(label, lk, false, desc) == 2;
}

bool opt_radio(const char *label, bool selected, const char *desc) {
    bool off = g_next_disabled;
    Look lk = {K_TEXT};
    bool chosen = card(label, lk, false, desc) == 2;
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    float fs = ImGui::GetFontSize(), r = fs * 0.36f, cx = b.x - 22 * g_scale - r, cy = a.y + fs * 2.15f * 0.5f;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImU32 col = off ? kTextOff : selected ? theme_u32(kAccentV) : theme_u32(kTextV, 0.78f);
    dl->AddCircle(ImVec2(cx, cy), r, col, 0, 2.0f);
    if (selected) dl->AddCircleFilled(ImVec2(cx, cy), r * 0.55f, col);
    return chosen && !selected;
}

bool opt_action(const char *label, const char *value, const char *desc, bool upper) {
    Look lk = {K_TEXT};
    lk.value = value ? value : "";
    return card(label, lk, false, desc, upper) == 2;
}

static ImGuiID g_text_editing;  // the text card turned into a field (one at a time)
bool opt_text_editing(const char *label) { return g_text_editing && g_text_editing == ImGui::GetID(label); }

bool opt_text(const char *label, char *buf, size_t cap, const char *hint, const char *desc) {
    ImGuiID &editing = g_text_editing;
    static int focus;  // frames left to give it the keyboard focus
    ImGuiID id = ImGui::GetID(label);
    if (editing != id) {
        Look lk = {K_TEXT};
        lk.value = buf[0] ? buf : (hint ? hint : "");
        if (card(label, lk, false, desc) == 2) editing = id, focus = 2;
        return false;
    }
    ImGui::PushID(label);
    ImGui::SetNextItemWidth(-1);
    if (focus > 0) ImGui::SetKeyboardFocusHere(), focus--;
    bool done = ui_input_text("##text", buf, cap, ImGuiInputTextFlags_EnterReturnsTrue, hint, label);
    if (done || ui_input_text_cancelled() || (focus == 0 && !ImGui::IsItemActive() && !osk_is_open())) editing = 0;
    ImGui::PopID();
    return done;
}

void opt_end(void) {
    ImGui::PopStyleVar();
    if (const char *t = getenv("ODYSSEY_OPT_SCROLL")) ImGui::SetScrollY(ImGui::GetScrollMaxY() * (float)atof(t));  // (test)
    ImGui::EndChild();
    ImGui::PopID();
}

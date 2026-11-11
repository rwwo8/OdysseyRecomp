// Odyssey Recomp's look (runtime/ui): one palette for the launcher, the menu, its option rows, the Controls page and the
// on-screen keyboard. A night-sky teal (the launcher's backdrop), white text, a light sky-blue for what's selected,
// and Mario's red only for the main action (Play, Choose game folder).
#pragma once
#include "imgui.h"

#define THEME_RGB(r, g, b, a) ImVec4((r) / 255.0f, (g) / 255.0f, (b) / 255.0f, (a))
// the palette
static const ImVec4 kPanelV = THEME_RGB(11, 33, 45, 0.97f);         // the menu window (the launcher's sky, dark)
static const ImVec4 kSurfaceV = THEME_RGB(24, 58, 77, 1);           // fields, buttons, rows (the launcher's tiles)
static const ImVec4 kSurfaceHoverV = THEME_RGB(36, 84, 108, 1);     // ... under the mouse / the cursor
static const ImVec4 kAccentV = THEME_RGB(108, 205, 240, 1);         // sky blue: the selection, sliders, headings
static const ImVec4 kAccentDeepV = THEME_RGB(19, 86, 112, 1);       // ... pressed / active fields
static const ImVec4 kAccentSoftV = THEME_RGB(160, 228, 252, 1);     // ... as text: a value that isn't the default
static const ImVec4 kActionV = THEME_RGB(229, 56, 59, 1);           // Mario's red: the one main action of a page
static const ImVec4 kTextV = THEME_RGB(242, 246, 248, 1);
static const ImVec4 kTextDimV = THEME_RGB(150, 186, 202, 1);        // secondary text, tabs not shown
static const ImVec4 kTextOffV = THEME_RGB(92, 122, 136, 1);         // greyed out
static const ImVec4 kLineV = THEME_RGB(255, 255, 255, 0.10f);       // separators
static const ImVec4 kWarnV = THEME_RGB(168, 110, 24, 1);            // a conflict (one key bound twice)

static inline ImU32 theme_u32(ImVec4 c, float alpha = -1) {
    if (alpha >= 0) c.w = alpha;
    return ImGui::ColorConvertFloat4ToU32(c);
}
#define kAccent theme_u32(kAccentV)
#define kAccentDim theme_u32(kAccentV, 0.43f)
#define kText theme_u32(kTextV)
#define kTextDim theme_u32(kTextDimV)
#define kTextOff theme_u32(kTextOffV)

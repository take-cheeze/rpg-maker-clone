#include "window_title.hxx"

#include <lvgl.h>
#include <ng-log/logging.h>

namespace {

// The display the hook below retitles. Captured by window_title_install; the
// SDL window backend creates exactly one display and it outlives the run, so a
// file-scope pointer is enough (the hook has no argument to carry it in).
lv_display_t* g_display = nullptr;

// What the window is called before a game says otherwise, and again if one sets
// an empty title. LVGL's own default is "LVGL Simulator", which says nothing
// about what is running.
constexpr const char* kDefaultTitle = "RPG Maker Clone";

void set_sdl_window_title(const char* title) {
  if (g_display == nullptr)
    return;
  const bool named = title != nullptr && *title != '\0';
  lv_sdl_window_set_title(g_display, named ? title : kDefaultTitle);
  if (named)
    LOG(INFO) << "Window title: " << title;
}

}  // namespace

void window_title_install(lv_display_t* display) {
  g_display = display;
  window_title_set_hook(&set_sdl_window_title);
  // Name the window before any game is loaded, so a boot that never gets far
  // enough to read a title (or a project with none) is still identifiable.
  set_sdl_window_title(nullptr);
}

#pragma once

#include "terminal.hxx"

// Install the hook (see terminal.hxx's "Window title bridge" section) that
// puts whatever title the running game sets on the SDL window `display` owns
// -- under Emscripten SDL maps the same call onto the page's document.title,
// so the browser tab is named too.  Call this once, right after the display is
// created and before the mruby interpreter runs any Ruby code.  Only for the
// SDL window backend: the terminal backends (--sixel / --iterm) drive an LVGL
// display with no SDL window behind it, so they install nothing and the title a
// game sets is simply recorded.  Lives in the executable rather than the
// mruby-rgss gem so the gem keeps no compile-time dependency on SDL, the same
// way the log bridge keeps it free of ng-log.
void window_title_install(lv_display_t* display);

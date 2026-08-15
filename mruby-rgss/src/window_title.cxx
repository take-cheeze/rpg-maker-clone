// The gem's half of the window title bridge: a function pointer the executable
// fills in and the last title set through it. See include/terminal.hxx's
// "Window title bridge" section for why the two halves are split.

#include "terminal.hxx"

namespace {
window_title_hook_fn g_hook = nullptr;
// Kept even when no hook is installed, so RGSS.window_title reads back what the
// game asked for under every backend (the terminal ones, mrbtest, PSP, Wio).
std::string g_title;
}  // namespace

void window_title_set_hook(window_title_hook_fn hook) {
  g_hook = hook;
}

void window_title_set(const char* title) {
  if (title == nullptr)
    title = "";
  g_title = title;
  if (g_hook != nullptr)
    g_hook(g_title.c_str());
}

const std::string& window_title_get() {
  return g_title;
}

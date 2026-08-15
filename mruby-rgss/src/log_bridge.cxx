#include "terminal.hxx"

#include <cstdio>
#include <cstring>

namespace {
log_bridge_hook_fn g_hook = nullptr;
}  // namespace

void log_bridge_set_hook(log_bridge_hook_fn hook) {
  g_hook = hook;
}

void log_bridge_write(const char* msg, size_t len) {
  if (g_hook != nullptr)
    g_hook(msg, len);
}

void log_bridge_write_stderr(const char* msg) {
  std::fprintf(stderr, "%s\n", msg);
  log_bridge_write(msg, std::strlen(msg));
}

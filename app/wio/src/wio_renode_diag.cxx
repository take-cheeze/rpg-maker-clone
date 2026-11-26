// The wio_renode_game firmware's diagnostic log at kDiagBase (Renode only: a
// real board has nothing mapped there), where stdout and stderr go, and its
// heap guard.

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "wio_game_rom.h"

namespace {

// kDiagBase: u32 bytes written, then the text.
uint32_t* diag_len() {
  return reinterpret_cast<uint32_t*>(kDiagBase);
}
char* diag_text() {
  return reinterpret_cast<char*>(kDiagBase + 16);
}

}  // namespace

void wio_diag_write(const char* text, size_t len) {
  uint32_t n = *diag_len();
  const size_t cap = kDiagSize - 16;
  if (n >= cap)
    return;
  if (len > cap - n)
    len = cap - n;
  std::memcpy(diag_text() + n, text, len);
  *diag_len() = n + len;
}

void wio_diag_printf(const char* fmt, ...) {
  char buf[256];
  va_list ap;
  va_start(ap, fmt);
  int n = std::vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n > 0)
    wio_diag_write(buf,
                   static_cast<size_t>(n) < sizeof(buf) ? n : sizeof(buf) - 1);
}

size_t wio_diag_length() {
  return *diag_len();
}

extern "C" {

// The seeed core links with --wrap=_write and its own __wrap__write drops the
// bytes; this one is linked first and keeps them. Every game file is read-only.
int __wrap__write(int fd, const char* buf, int len) {
  if (fd == 1 || fd == 2) {
    wio_diag_write(buf, len);
    return len;
  }
  errno = EBADF;
  return -1;
}

}  // extern "C"

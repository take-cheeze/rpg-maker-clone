// newlib file syscalls over the game image at game_rom_base(), for the
// wio_renode_game firmware (Renode only: a real board has nothing mapped
// there). Reads copy out of the image the way the SD layer (sd_syscalls.cxx)
// copies off the card, so the heap behaves as it would with a card, minus
// the SD library's own buffers. Writes to a file are refused (EROFS); fd 1
// and 2 go to the diagnostic log.

#include "wio_game_rom.h"

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#include <fcntl.h>
#include <sys/stat.h>

namespace {

struct RomHeader {
  char magic[8];
  uint32_t count, config_off, config_len;
};
struct RomEntry {
  uint32_t path_off, data_off, len;
};

const uint8_t* rom() {
  return reinterpret_cast<const uint8_t*>(game_rom_base());
}
const RomHeader* header() {
  const RomHeader* h = reinterpret_cast<const RomHeader*>(rom());
  return std::memcmp(h->magic, "WIOGROM1", 8) == 0 ? h : nullptr;
}
const RomEntry* find(const char* path) {
  const RomHeader* h = header();
  if (!h)
    return nullptr;
  const RomEntry* e = reinterpret_cast<const RomEntry*>(h + 1);
  for (uint32_t i = 0; i < h->count; ++i)
    if (std::strcmp(reinterpret_cast<const char*>(rom() + e[i].path_off),
                    path) == 0)
      return &e[i];
  return nullptr;
}

constexpr int kFdBase = 3;
constexpr int kMaxFiles = 8;
struct OpenFile {
  const RomEntry* entry;
  uint32_t pos;
};
OpenFile g_open[kMaxFiles];

OpenFile* slot_of(int fd) {
  const int i = fd - kFdBase;
  if (i < 0 || i >= kMaxFiles || !g_open[i].entry)
    return nullptr;
  return &g_open[i];
}

// kDiagBase: u32 bytes written, then the text.
uint32_t* diag_len() {
  return reinterpret_cast<uint32_t*>(kDiagBase);
}
char* diag_text() {
  return reinterpret_cast<char*>(kDiagBase + 16);
}

}  // namespace

const char* wio_game_rom_config(const char* key, char* buf, size_t cap) {
  const RomHeader* h = header();
  if (!h)
    return nullptr;
  const char* p = reinterpret_cast<const char*>(rom() + h->config_off);
  const char* end = p + h->config_len;
  const size_t klen = std::strlen(key);
  while (p < end) {
    const char* nl = static_cast<const char*>(std::memchr(p, '\n', end - p));
    if (!nl)
      nl = end;
    if (static_cast<size_t>(nl - p) > klen && std::strncmp(p, key, klen) == 0 &&
        p[klen] == '=') {
      size_t n = nl - (p + klen + 1);
      if (n >= cap)
        n = cap - 1;
      std::memcpy(buf, p + klen + 1, n);
      buf[n] = '\0';
      return buf;
    }
    p = nl + 1;
  }
  return nullptr;
}

const void* wio_game_rom_file(const char* path, size_t* len) {
  const RomEntry* e = find(path);
  if (!e)
    return nullptr;
  *len = e->len;
  return rom() + e->data_off;
}

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

int _open(const char* path, int flags, ...) {
  if ((flags & O_ACCMODE) != O_RDONLY) {
    errno = EROFS;
    return -1;
  }
  const RomEntry* e = find(path);
  if (!e) {
    errno = ENOENT;
    return -1;
  }
  for (int i = 0; i < kMaxFiles; ++i) {
    if (!g_open[i].entry) {
      g_open[i] = {e, 0};
      return kFdBase + i;
    }
  }
  errno = EMFILE;
  return -1;
}

int _close(int fd) {
  OpenFile* f = slot_of(fd);
  if (!f) {
    errno = EBADF;
    return -1;
  }
  f->entry = nullptr;
  return 0;
}

int _read(int fd, char* buf, int len) {
  OpenFile* f = slot_of(fd);
  if (!f || len < 0) {
    errno = EBADF;
    return -1;
  }
  uint32_t left = f->entry->len - f->pos;
  uint32_t n = static_cast<uint32_t>(len) < left ? len : left;
  std::memcpy(buf, rom() + f->entry->data_off + f->pos, n);
  f->pos += n;
  return static_cast<int>(n);
}

// The seeed core links with --wrap=_write and its own __wrap__write drops the
// bytes; this one is linked first and keeps them.
int __wrap__write(int fd, const char* buf, int len) {
  if (fd == 1 || fd == 2) {
    wio_diag_write(buf, len);
    return len;
  }
  errno = slot_of(fd) ? EROFS : EBADF;
  return -1;
}

int _lseek(int fd, int offset, int whence) {
  OpenFile* f = slot_of(fd);
  if (!f) {
    errno = EBADF;
    return -1;
  }
  int64_t pos = offset;
  if (whence == SEEK_CUR)
    pos += f->pos;
  else if (whence == SEEK_END)
    pos += f->entry->len;
  if (pos < 0 || pos > f->entry->len) {
    errno = EINVAL;
    return -1;
  }
  f->pos = static_cast<uint32_t>(pos);
  return static_cast<int>(pos);
}

int _fstat(int fd, struct stat* st) {
  std::memset(st, 0, sizeof(*st));
  if (fd >= 0 && fd <= 2) {
    st->st_mode = S_IFCHR;
    return 0;
  }
  OpenFile* f = slot_of(fd);
  if (!f) {
    errno = EBADF;
    return -1;
  }
  st->st_mode = S_IFREG;
  st->st_size = f->entry->len;
  return 0;
}

// The core's _sbrk lets the heap grow right up to the stack pointer, so the
// next deeper call writes over the last block. Linked with --wrap=_sbrk, this
// keeps kStackReserve bytes free below the stack and fails the growth instead,
// which reaches mruby as NoMemoryError.
constexpr ptrdiff_t kStackReserve = 8192;
void* __real__sbrk(ptrdiff_t incr);
void* __wrap__sbrk(ptrdiff_t incr) {
  char* top = static_cast<char*>(__real__sbrk(0));
  char* sp;
  __asm__ volatile("mov %0, sp" : "=r"(sp));
  if (incr > 0 && top + incr + kStackReserve > sp) {
    errno = ENOMEM;
    return reinterpret_cast<void*>(-1);
  }
  return __real__sbrk(incr);
}

int _isatty(int fd) {
  return fd >= 0 && fd <= 2;
}

int _unlink(const char*) {
  errno = EROFS;
  return -1;
}

}  // extern "C"

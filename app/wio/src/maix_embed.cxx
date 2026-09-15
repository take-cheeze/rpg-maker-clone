// Flash-resident game files for the maix_game firmware (PlatformIO side).
//
// Serves data/maix-hello (embedded as C arrays by app/maix/embed_game.py
// into maix_game_data.h) through newlib _open/_read/_lseek/_close/_fstat,
// so the unmodified mruby engine (File.open "#{GAME_DIR}/RPG_RT.ldb" and
// friends, mruby-io, the bitmap loaders' fopen) reads the game with no SD
// card present -- which is also exactly the situation under Renode, where
// no SD controller is modeled. Writes are refused with EROFS: saves need
// the SD layer (app/wio/src/maix_sd_syscalls.cxx, MAIX_WITH_SD), which is
// the next slice's problem, not this one's; the title screen never writes.
//
// Only compiled into env:maix_game (see platformio.ini). The mruby-boot
// environment deliberately does not carry game data.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <Arduino.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "maix_game_data.h"

extern "C" {

namespace {

// Open-file table over the embedded array table. Positions are per-open
// state; the arrays themselves are read-only flash.
constexpr int kFdBase = 3;
constexpr int kMaxFiles = 8;

struct OpenFile {
  const uint8_t* data = nullptr;
  size_t len = 0;
  size_t pos = 0;
  bool used = false;
};

OpenFile g_open[kMaxFiles];

const MaixEmbedFile* find_embedded(const char* path) {
  for (size_t i = 0; i < kMaixEmbedFileCount; ++i) {
    if (std::strcmp(kMaixEmbedFiles[i].path, path) == 0)
      return &kMaixEmbedFiles[i];
  }
  return nullptr;
}

}  // namespace

int _open(const char* path, int flags, ...) {
  if ((flags & O_ACCMODE) != O_RDONLY) {
    errno = EROFS;
    return -1;
  }
  const MaixEmbedFile* found = find_embedded(path);
  if (!found) {
    errno = ENOENT;
    return -1;
  }
  for (int i = 0; i < kMaxFiles; ++i) {
    if (!g_open[i].used) {
      g_open[i].data = found->data;
      g_open[i].len = found->len;
      g_open[i].pos = 0;
      g_open[i].used = true;
      return kFdBase + i;
    }
  }
  errno = EMFILE;
  return -1;
}

int _close(int fd) {
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_open[slot].used) {
    errno = EBADF;
    return -1;
  }
  g_open[slot].used = false;
  return 0;
}

int _read(int fd, char* buf, int len) {
  if (fd == 0) {
    errno = EBADF;
    return -1;
  }
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_open[slot].used) {
    errno = EBADF;
    return -1;
  }
  OpenFile& f = g_open[slot];
  size_t left = f.len - f.pos;
  size_t n = static_cast<size_t>(len) < left ? static_cast<size_t>(len) : left;
  std::memcpy(buf, f.data + f.pos, n);
  f.pos += n;
  return static_cast<int>(n);
}

int _write(int fd, const char* buf, int len) {
  if (fd == 1 || fd == 2) {  // stdout/stderr -> USB serial for diagnostics
    Serial.write(reinterpret_cast<const uint8_t*>(buf), len);
    return len;
  }
  errno = EBADF;
  return -1;
}

int _lseek(int fd, int offset, int whence) {
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_open[slot].used) {
    errno = EBADF;
    return -1;
  }
  OpenFile& f = g_open[slot];
  size_t pos = static_cast<size_t>(offset);
  if (whence == SEEK_CUR)
    pos = f.pos + offset;
  else if (whence == SEEK_END)
    pos = f.len + offset;
  if (pos > f.len) {
    errno = EINVAL;
    return -1;
  }
  f.pos = pos;
  return static_cast<int>(pos);
}

int _fstat(int fd, struct stat* st) {
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_open[slot].used) {
    errno = EBADF;
    return -1;
  }
  std::memset(st, 0, sizeof(*st));
  st->st_mode = S_IFREG;
  st->st_size = g_open[slot].len;
  return 0;
}

int _unlink(const char* path) {
  (void)path;
  errno = EROFS;
  return -1;
}

}  // extern "C"

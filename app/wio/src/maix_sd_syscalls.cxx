// SD-backed newlib syscalls for the Maix Amigo firmware.
//
// mruby-io and the bitmap loaders open game assets by path (File.open, fopen),
// which bottom out in newlib's _open/_read/_close/_lseek/_fstat. On the board
// those must be backed by storage; this routes them to Maixduino's SD library
// (sdfat over the TF slot -- SPI1, chip-select 26 -- via maix_tf_sd.h, NOT
// the library's global `SD`, which defaults to the right bus but the wrong
// pins). Paths under GAME_DIR (e.g. "/sd/<game>") are served from the card,
// the same convention app/wio/src/sd_syscalls.cxx uses.
//
// Compiled only when MAIX_WITH_SD is defined (mirroring WIO_WITH_SD): the
// bring-up environments leave it off, and CI compiles it once with the flag
// on as a dedicated proof step. Runtime proof needs a real card (Renode
// models no SD controller), so that half waits for hardware -- but note
// scripts/wio_renode_sdcard.bash's own shape for how it will be tested: an
// SD image attached under Renode with game data on it.
// Call maix_sd_init() once from setup() before opening anything.

#ifdef MAIX_WITH_SD

#include <cerrno>
#include <cstring>

#include <Arduino.h>

#include "maix_tf_sd.h"  // before <fcntl.h>: sdfat's O_* consts collide with
                         // newlib's O_* macros (see sd_open_mode below)

#include <fcntl.h>
#include <sys/stat.h>

#include "maix.hxx"

extern "C" {

namespace {

// Small fixed descriptor table above the three stdio fds. Each open asset maps
// to one SDLib File. The interpreter opens data files one or few at a time,
// so a handful of slots is enough for now.
constexpr int kFdBase = 3;
constexpr int kMaxFiles = 8;
File g_files[kMaxFiles];
bool g_used[kMaxFiles];

// Map an absolute game path to an SD path. GAME_DIR is "/sd/<game>"; the SD
// library roots at "/", so strip a leading "/sd".
const char* to_sd_path(const char* path) {
  if (std::strncmp(path, "/sd", 3) == 0)
    return path + 3;
  return path;
}

}  // namespace

}  // extern "C"

bool maix_sd_init(void) {
  // TF slot chip-select: pin 26 (see maix_tf_sd.h). Returns false with no
  // card present -- callers treat every later open as ENOENT rather than
  // hanging here. C++ linkage (declared so in maix.hxx): only the newlib
  // hooks below need C linkage.
  return maix_tf_sd().begin(26);
}

extern "C" {

// Translate newlib open flags to the SD library's own. The spellings
// collide but the VALUES differ (newlib: O_CREAT 0x200, O_APPEND 0x8;
// sdfat: O_CREAT 0x10, O_APPEND 0x4, O_TRUNC 0x40), and newlib's are macros
// while sdfat's are typed consts -- so below, each O_* in a *test* position
// is newlib's, each O_* in a *mode-building* position is sdfat's. A write
// open always carries O_CREAT (a save file that does not exist yet is the
// normal case, and SD.open creates on write per its own contract).
uint8_t sd_open_mode(int flags) {
  uint8_t mode = O_READ;
  const int acc = flags & O_ACCMODE;
  if (acc == O_WRONLY || acc == O_RDWR)
    mode = static_cast<uint8_t>(O_WRITE | O_CREAT);
  if (flags & O_APPEND)
    mode = static_cast<uint8_t>(mode | O_APPEND);
  if (flags & O_TRUNC)
    mode = static_cast<uint8_t>(mode | O_TRUNC);
  return mode;
}

int _open(const char* path, int flags, ...) {
  int slot = -1;
  for (int i = 0; i < kMaxFiles; ++i) {
    if (!g_used[i]) {
      slot = i;
      break;
    }
  }
  if (slot < 0) {
    errno = EMFILE;
    return -1;
  }

  File f = maix_tf_sd().open(to_sd_path(path), sd_open_mode(flags));
  if (!f) {
    errno = ENOENT;
    return -1;
  }
  g_files[slot] = f;
  g_used[slot] = true;
  return kFdBase + slot;
}

int _close(int fd) {
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_used[slot]) {
    errno = EBADF;
    return -1;
  }
  g_files[slot].close();
  g_used[slot] = false;
  return 0;
}

int _read(int fd, char* buf, int len) {
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_used[slot]) {
    errno = EBADF;
    return -1;
  }
  return g_files[slot].read(buf, static_cast<uint32_t>(len));
}

int _write(int fd, const char* buf, int len) {
  if (fd == 1 || fd == 2) {  // stdout/stderr -> USB serial for diagnostics
    Serial.write(reinterpret_cast<const uint8_t*>(buf), len);
    return len;
  }
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_used[slot]) {
    errno = EBADF;
    return -1;
  }
  return g_files[slot].write(reinterpret_cast<const uint8_t*>(buf), len);
}

int _lseek(int fd, int offset, int whence) {
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_used[slot]) {
    errno = EBADF;
    return -1;
  }
  File& f = g_files[slot];
  uint32_t pos = offset;
  if (whence == SEEK_CUR)
    pos = f.position() + offset;
  else if (whence == SEEK_END)
    pos = f.size() + offset;
  if (!f.seek(pos)) {
    errno = EINVAL;
    return -1;
  }
  return static_cast<int>(pos);
}

int _fstat(int fd, struct stat* st) {
  const int slot = fd - kFdBase;
  if (slot < 0 || slot >= kMaxFiles || !g_used[slot]) {
    errno = EBADF;
    return -1;
  }
  std::memset(st, 0, sizeof(*st));
  st->st_mode = S_IFREG;
  st->st_size = g_files[slot].size();
  return 0;
}

// hal-wio-io's own mrb_hal_io_unlink backs File.delete with this directly --
// no open file descriptor involved. Shared verbatim semantics with the wio
// layer: the only reachable caller deletes wave-cache files.
int _unlink(const char* path) {
  if (!maix_tf_sd().remove(to_sd_path(path))) {
    errno = ENOENT;
    return -1;
  }
  return 0;
}

}  // extern "C"

#endif  // MAIX_WITH_SD

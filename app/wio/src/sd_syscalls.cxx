// SD-backed newlib syscalls for the Wio Terminal firmware.
//
// mruby-io and the bitmap loaders open game assets by path (File.open, fopen),
// which bottom out in newlib's _open/_read/_close/_lseek/_fstat. On the board
// those must be backed by storage; this routes them to the Arduino SD library
// (FatFs over the microSD slot). Paths under GAME_DIR (e.g. "/sd/<game>") are
// served from the card.
//
// This is a scaffold for the mruby/asset phase (P3), NOT part of the P1 HAL
// bring-up firmware: it is compiled only when WIO_WITH_SD is defined, and the
// bring-up PlatformIO env leaves it off (and out of build_src_filter). It is
// checked in so the newlib integration path is concrete and reviewable.

#ifdef WIO_WITH_SD

#include <cerrno>
#include <cstring>

#include <Arduino.h>
#include <SD.h>
#include <fcntl.h>
#include <sys/stat.h>

extern "C" {

namespace {

// Small fixed descriptor table above the three stdio fds. Each open asset maps
// to one Arduino File. The interpreter opens data files one or few at a time,
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

  uint8_t mode = FILE_READ;
  if ((flags & O_ACCMODE) == O_WRONLY || (flags & O_ACCMODE) == O_RDWR)
    mode = FILE_WRITE;

  File f = SD.open(to_sd_path(path), mode);
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
  return g_files[slot].read(reinterpret_cast<uint8_t*>(buf), len);
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

}  // extern "C"

#endif  // WIO_WITH_SD

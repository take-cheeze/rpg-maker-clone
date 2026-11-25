// newlib file syscalls: a game path (under WIO_GAME_ROOT) is read from the
// microSD card when wio_sd_begin() found a game there (wio_sd.cxx), else from
// the game image at game_rom_base(); every other path from the image. Reads
// copy out of the image the way they copy off the card, so the heap behaves
// the same with either. Writes to a file are refused (EROFS).

#include "wio_game_rom.h"

#include <cerrno>
#include <cstdio>
#include <cstring>

#include "wio_sd.h"

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
// A file from the image (entry) or the card (sd >= 0).
struct OpenFile {
  const RomEntry* entry;
  uint32_t pos;
  int sd;
  bool used;
};
OpenFile g_open[kMaxFiles];

OpenFile* slot_of(int fd) {
  const int i = fd - kFdBase;
  if (i < 0 || i >= kMaxFiles || !g_open[i].used)
    return nullptr;
  return &g_open[i];
}

uint32_t size_of(const OpenFile* f) {
#if WIO_SD
  if (f->sd >= 0)
    return wio_sd_size(f->sd);
#endif
  return f->entry->len;
}

#if WIO_SD
// The path below WIO_GAME_ROOT, or nullptr when +path+ is not a game path.
const char* game_relative(const char* path) {
  const size_t n = sizeof(WIO_GAME_ROOT) - 1;
  return std::strncmp(path, WIO_GAME_ROOT, n) == 0 && path[n] == '/'
             ? path + n + 1
             : nullptr;
}
#endif

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

bool wio_game_rom_present() {
  return header() != nullptr;
}

const char* wio_game_files_begin() {
  static char line[64];
  if (line[0])
    return line;
  const WioSdState sd = wio_sd_begin();
  if (sd == WIO_SD_GAME)
    std::snprintf(line, sizeof(line), "Game: SD card %s", WIO_SD_GAME_DIR);
  else if (find(WIO_GAME_ROOT "/RPG_RT.ldb"))
    std::snprintf(line, sizeof(line), "Game: QSPI image (%s)",
                  wio_sd_state_text(sd));
  else
    std::snprintf(line, sizeof(line), "No game (%s, none in QSPI)",
                  wio_sd_state_text(sd));
  std::fprintf(stderr, "[Wio] %s\n", line);
  return line;
}

const void* wio_game_rom_file(const char* path, size_t* len) {
  const RomEntry* e = find(path);
  if (!e)
    return nullptr;
  *len = e->len;
  return rom() + e->data_off;
}

extern "C" {

int _open(const char* path, int flags, ...) {
  if ((flags & O_ACCMODE) != O_RDONLY) {
    errno = EROFS;
    return -1;
  }
  int i = 0;
  while (i < kMaxFiles && g_open[i].used)
    ++i;
  if (i == kMaxFiles) {
    errno = EMFILE;
    return -1;
  }
#if WIO_SD
  const char* rel = game_relative(path);
  if (rel && wio_sd_state() == WIO_SD_GAME) {
    const int h = wio_sd_open(rel);
    if (h < 0) {
      errno = -h;
      return -1;
    }
    g_open[i] = {nullptr, 0, h, true};
    return kFdBase + i;
  }
#endif
  const RomEntry* e = find(path);
  if (!e) {
    errno = ENOENT;
    return -1;
  }
  g_open[i] = {e, 0, -1, true};
  return kFdBase + i;
}

int _close(int fd) {
  OpenFile* f = slot_of(fd);
  if (!f) {
    errno = EBADF;
    return -1;
  }
#if WIO_SD
  if (f->sd >= 0)
    wio_sd_close(f->sd);
#endif
  f->used = false;
  return 0;
}

int _read(int fd, char* buf, int len) {
  OpenFile* f = slot_of(fd);
  if (!f || len < 0) {
    errno = EBADF;
    return -1;
  }
#if WIO_SD
  if (f->sd >= 0) {
    const int n = wio_sd_read(f->sd, buf, static_cast<unsigned>(len));
    if (n < 0) {
      errno = -n;
      return -1;
    }
    return n;
  }
#endif
  uint32_t left = f->entry->len - f->pos;
  uint32_t n = static_cast<uint32_t>(len) < left ? len : left;
  std::memcpy(buf, rom() + f->entry->data_off + f->pos, n);
  f->pos += n;
  return static_cast<int>(n);
}

int _lseek(int fd, int offset, int whence) {
  OpenFile* f = slot_of(fd);
  if (!f) {
    errno = EBADF;
    return -1;
  }
  const uint32_t size = size_of(f);
  int64_t pos = offset;
  if (whence == SEEK_CUR) {
#if WIO_SD
    pos += f->sd >= 0 ? wio_sd_tell(f->sd) : f->pos;
#else
    pos += f->pos;
#endif
  } else if (whence == SEEK_END) {
    pos += size;
  }
  if (pos < 0 || pos > size) {
    errno = EINVAL;
    return -1;
  }
#if WIO_SD
  if (f->sd >= 0) {
    const int32_t r = wio_sd_seek(f->sd, static_cast<uint32_t>(pos));
    if (r < 0) {
      errno = -r;
      return -1;
    }
    return r;
  }
#endif
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
  st->st_size = size_of(f);
  return 0;
}

int _isatty(int fd) {
  return fd >= 0 && fd <= 2;
}

int _unlink(const char*) {
  errno = EROFS;
  return -1;
}

}  // extern "C"

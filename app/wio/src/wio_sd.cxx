// Game files from the microSD card: FatFs over Seeed_Arduino_FS's SPI card
// driver, on the card slot's own SERCOM (SDCARD_SPI), not the LCD's. The
// FatFs build (app/wio/wio_sd.py) shares one sector window between every open
// file, so the RAM cost is that window plus a few dozen bytes a file; reads
// stream through it, and whole sectors go straight to the caller's buffer.

#include "wio_sd.h"

#include <cstdio>

#if !WIO_SD

WioSdState wio_sd_begin() {
  return WIO_SD_OFF;
}
WioSdState wio_sd_state() {
  return WIO_SD_OFF;
}

#else

#include <Arduino.h>
#include <SPI.h>

#include <cerrno>
#include <cstring>

#include "fatfs/ff.h"

// Seeed_sdcard_hal.cpp: registers the card as a FatFs drive, the drive number
// or 0xFF. Declared here so the Arduino File classes' header stays out.
uint8_t sdcard_init(uint8_t cs, SPIClass* spi, int hz);

#ifndef WIO_SD_HZ
#define WIO_SD_HZ 4000000
#endif

namespace {

constexpr int kMaxFiles = 8;
FATFS g_fs;
FIL g_files[kMaxFiles];
bool g_used[kMaxFiles];
bool g_begun = false;
WioSdState g_state = WIO_SD_NO_CARD;
uint8_t g_drive = 0;

const char* fr_name(FRESULT r) {
  static const char* const kNames[] = {"FR_OK",
                                       "FR_DISK_ERR",
                                       "FR_INT_ERR",
                                       "FR_NOT_READY",
                                       "FR_NO_FILE",
                                       "FR_NO_PATH",
                                       "FR_INVALID_NAME",
                                       "FR_DENIED",
                                       "FR_EXIST",
                                       "FR_INVALID_OBJECT",
                                       "FR_WRITE_PROTECTED",
                                       "FR_INVALID_DRIVE",
                                       "FR_NOT_ENABLED",
                                       "FR_NO_FILESYSTEM",
                                       "FR_MKFS_ABORTED",
                                       "FR_TIMEOUT",
                                       "FR_LOCKED",
                                       "FR_NOT_ENOUGH_CORE",
                                       "FR_TOO_MANY_OPEN_FILES",
                                       "FR_INVALID_PARAMETER"};
  const unsigned i = static_cast<unsigned>(r);
  return i < sizeof(kNames) / sizeof(kNames[0]) ? kNames[i] : "FR_?";
}

// A lookup that found nothing; anything else is the card failing.
bool not_found(FRESULT r) {
  return r == FR_NO_FILE || r == FR_NO_PATH || r == FR_INVALID_NAME;
}

// "<drive>:" WIO_SD_GAME_DIR "/" +rel+ as UTF-16, the API's encoding. False
// when it does not fit in +cap+ units or +rel+ is not UTF-8.
bool card_path(const char* rel, WCHAR* out, size_t cap) {
  size_t n = 0;
  auto put = [&](uint32_t u) {
    if (n + 1 >= cap)
      return false;
    out[n++] = static_cast<WCHAR>(u);
    return true;
  };
  if (!put('0' + g_drive) || !put(':'))
    return false;
  for (const char* p = WIO_SD_GAME_DIR "/"; *p; ++p)
    if (!put(static_cast<unsigned char>(*p)))
      return false;
  const unsigned char* s = reinterpret_cast<const unsigned char*>(rel);
  while (*s == '/')
    ++s;
  while (*s) {
    uint32_t c = *s++;
    int more = c < 0x80             ? 0
               : (c & 0xE0) == 0xC0 ? 1
               : (c & 0xF0) == 0xE0 ? 2
               : (c & 0xF8) == 0xF0 ? 3
                                    : -1;
    if (more < 0)
      return false;
    if (more)
      c &= 0x3F >> more;
    for (; more > 0; --more) {
      if ((*s & 0xC0) != 0x80)
        return false;
      c = (c << 6) | (*s++ & 0x3F);
    }
    if (c >= 0x10000) {  // the long name stores a surrogate pair
      c -= 0x10000;
      if (!put(0xD800 | (c >> 10)) || !put(0xDC00 | (c & 0x3FF)))
        return false;
    } else if (!put(c)) {
      return false;
    }
  }
  out[n] = 0;
  return true;
}

FIL* file_of(int h) {
  return h >= 0 && h < kMaxFiles && g_used[h] ? &g_files[h] : nullptr;
}

WioSdState mount() {
  g_drive = sdcard_init(SDCARD_SS_PIN, &SDCARD_SPI, WIO_SD_HZ);
  if (g_drive == 0xFF) {
    std::fprintf(stderr, "[Wio] SD: the card driver did not start\n");
    return WIO_SD_NO_CARD;
  }
  SDCARD_SPI.begin();
  const WCHAR drive[] = {static_cast<WCHAR>('0' + g_drive), ':', 0};
  FRESULT r = f_mount(&g_fs, drive, 1);
  if (r == FR_NO_FILESYSTEM) {
    std::fprintf(stderr,
                 "[Wio] SD: no FAT volume on the card (FR_NO_FILESYSTEM; "
                 "exFAT is not read)\n");
    return WIO_SD_NO_FILESYSTEM;
  }
  if (r != FR_OK) {
    std::fprintf(stderr, "[Wio] SD: no card (mount: %s)\n", fr_name(r));
    return WIO_SD_NO_CARD;
  }
  WCHAR path[32];
  card_path("RPG_RT.ldb", path, sizeof(path) / sizeof(path[0]));
  FIL probe;
  r = f_open(&probe, path, FA_READ);
  if (r != FR_OK) {
    std::fprintf(stderr, "[Wio] SD: no %s/RPG_RT.ldb on the card (%s)\n",
                 WIO_SD_GAME_DIR, fr_name(r));
    return WIO_SD_NO_GAME;
  }
  f_close(&probe);
  std::fprintf(stderr, "[Wio] SD: game files from the card's %s\n",
               WIO_SD_GAME_DIR);
  return WIO_SD_GAME;
}

}  // namespace

WioSdState wio_sd_begin() {
  if (!g_begun) {
    g_begun = true;
    g_state = mount();
  }
  return g_state;
}

WioSdState wio_sd_state() {
  return g_begun ? g_state : WIO_SD_NO_CARD;
}

int wio_sd_open(const char* rel) {
  if (wio_sd_state() != WIO_SD_GAME)
    return -ENOENT;
  WCHAR path[256];
  if (!card_path(rel, path, sizeof(path) / sizeof(path[0])))
    return -ENOENT;
  int h = 0;
  while (h < kMaxFiles && g_used[h])
    ++h;
  if (h == kMaxFiles) {
    std::fprintf(stderr, "[Wio] SD: %d files open, cannot open %s\n", kMaxFiles,
                 rel);
    return -EMFILE;
  }
  const FRESULT r = f_open(&g_files[h], path, FA_READ);
  if (r != FR_OK) {
    if (not_found(r))
      return -ENOENT;
    std::fprintf(stderr, "[Wio] SD: open %s: %s\n", rel, fr_name(r));
    return -EIO;
  }
  g_used[h] = true;
  return h;
}

void wio_sd_close(int h) {
  if (FIL* f = file_of(h)) {
    f_close(f);
    g_used[h] = false;
  }
}

int wio_sd_read(int h, void* buf, unsigned len) {
  FIL* f = file_of(h);
  if (!f)
    return -EBADF;
  UINT n = 0;
  const FRESULT r = f_read(f, buf, len, &n);
  if (r != FR_OK) {
    std::fprintf(stderr, "[Wio] SD: read: %s\n", fr_name(r));
    return -EIO;
  }
  return static_cast<int>(n);
}

int32_t wio_sd_seek(int h, uint32_t pos) {
  FIL* f = file_of(h);
  if (!f)
    return -EBADF;
  const FRESULT r = f_lseek(f, pos);
  if (r != FR_OK) {
    std::fprintf(stderr, "[Wio] SD: seek: %s\n", fr_name(r));
    return -EIO;
  }
  return static_cast<int32_t>(f_tell(f));
}

uint32_t wio_sd_tell(int h) {
  FIL* f = file_of(h);
  return f ? f_tell(f) : 0;
}

uint32_t wio_sd_size(int h) {
  FIL* f = file_of(h);
  return f ? f_size(f) : 0;
}

#endif  // WIO_SD

const char* wio_sd_state_text(WioSdState state) {
  switch (state) {
    case WIO_SD_OFF:
      return "SD: off (WIO_SD=0)";
    case WIO_SD_NO_CARD:
      return "SD: no card";
    case WIO_SD_NO_FILESYSTEM:
      return "SD: no FAT volume";
    case WIO_SD_NO_GAME:
      return "SD: no " WIO_SD_GAME_DIR "/RPG_RT.ldb";
    case WIO_SD_GAME:
      return "SD: game in " WIO_SD_GAME_DIR;
  }
  return "SD: ?";
}

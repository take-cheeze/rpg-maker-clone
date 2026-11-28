// IMAGE_CACHE glue (wio_image_cache.h): the card's pack, read through
// wio_sd.cxx, and a region of the QSPI flash from the end of the game image
// (or of the code image, without one) to the end of the chip, written while
// the code window stays open (wio_qspi.h, QSPI_WRITE). FILE_CACHE: the same
// region serves the card's database and maps to MAPPED_LCF.
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

#include "lcf_file_map.h"
#include "wio_game_rom.h"
#include "wio_image_cache.h"
#include "wio_qspi_xip.h"
#include "wio_sd.h"

#if WIO_QSPI_XIP && WIO_SD

#include <Arduino.h>

#include "wio_qspi.h"

// The board's 4 MB chip; Renode's window is larger, its model the same chip.
#ifndef WIO_QSPI_FLASH_END
#define WIO_QSPI_FLASH_END 0x04400000u
#endif
// Items the cache keeps track of, 12 bytes of heap each.
#ifndef WIO_IMAGE_CACHE_ITEMS
#define WIO_IMAGE_CACHE_ITEMS 128
#endif
// In the card's game folder, next to RPG_RT.ldb.
#define WIO_IMAGE_PACK "wio_bitmaps.bin"

namespace {

// The smallest region worth a cache: the header, a directory and a few items.
constexpr uint32_t kMinRegion = 64 * 1024;

uintptr_t g_region = 0;
int g_pack = -1;
WicCache* g_cache = nullptr;
uint32_t g_pos = 0;
int g_file = -1;
mrb_state* g_mrb = nullptr;
bool g_cache_ldb = WIO_FILE_CACHE_LDB;

void flash_erase(void*, uint32_t off) {
  wio_qspi_xip_erase_sector(g_region - QSPI_AHB + off);
}

void flash_program(void*, uint32_t off, const uint8_t* data, uint32_t len) {
  wio_qspi_xip_program(g_region - QSPI_AHB + off, data, len);
}

bool pack_read(void*, uint32_t off, uint8_t* buf, uint32_t len) {
  if (g_pos != off) {
    if (wio_sd_seek(g_pack, off) != static_cast<int32_t>(off))
      return false;
    g_pos = off;
  }
  while (len) {
    const int n = wio_sd_read(g_pack, buf, len);
    if (n <= 0)
      return false;
    g_pos += n;
    buf += n;
    len -= n;
  }
  return true;
}

bool file_open(void*, const char* path, uint32_t* size) {
  g_file = wio_sd_open(path);
  if (g_file < 0) {
    if (g_file != -ENOENT)
      std::fprintf(stderr, "[Wio] file cache: %s: the card read failed\n",
                   path);
    return false;
  }
  *size = wio_sd_size(g_file);
  return true;
}

bool file_read(void*, uint8_t* buf, uint32_t len) {
  while (len) {
    const int n = wio_sd_read(g_file, buf, len);
    if (n <= 0)
      return false;
    buf += n;
    len -= n;
  }
  return true;
}

void file_close(void*) {
  wio_sd_close(g_file);
  g_file = -1;
}

// mruby-lcf answers for what the VM still holds (lcf_mapped_in_use).
void file_in_use(void*, const WicRange* ranges, uint32_t n, bool* used) {
  lcf_mapped_range r[16];
  for (uint32_t done = 0; done < n;) {
    const uint32_t k = n - done < 16 ? n - done : 16;
    for (uint32_t i = 0; i < k; ++i)
      r[i] = {ranges[done + i].p, ranges[done + i].len};
    lcf_mapped_in_use(g_mrb, r, k, used + done);
    done += k;
  }
}

// The files MAPPED_LCF asks for that the cache takes: the maps, and the
// database unless wio_file_cache_ldb(false).
bool cached_file(const char* rel) {
  const size_t n = std::strlen(rel);
  if (n > 4 && std::strcmp(rel + n - 4, ".lmu") == 0)
    return true;
  return g_cache_ldb && std::strcmp(rel, "RPG_RT.ldb") == 0;
}

void log_line(const char* line) {
  std::fprintf(stderr, "[Wio] %s\n", line);
}

uint32_t cycles() {
  return DWT->CYCCNT;
}

}  // namespace

bool wio_image_cache_begin(const char* root, mrb_state* M) {
  if (wio_qspi_xip_status() != WIO_QSPI_XIP_OK || wio_sd_state() != WIO_SD_GAME)
    return false;
  g_pack = wio_sd_open(WIO_IMAGE_PACK);
  if (g_pack < 0) {
    std::fprintf(stderr,
                 "[Wio] image cache: no %s/" WIO_IMAGE_PACK
                 " on the card (scripts/wio/sd_bitmaps.rb writes it): images "
                 "decode from their files\n",
                 WIO_SD_GAME_DIR);
    return false;
  }
  const uintptr_t from = game_rom_base() + wio_game_rom_size();
  g_region = (from + kWicSector - 1) & ~uintptr_t(kWicSector - 1);
  if (g_region + kMinRegion > WIO_QSPI_FLASH_END) {
    std::fprintf(stderr,
                 "[Wio] image cache: no room in the QSPI flash after 0x%08x: "
                 "images decode from their files\n",
                 static_cast<unsigned>(from));
    wio_sd_close(g_pack);
    return false;
  }
  CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;
  DWT->CTRL |= DWT_CTRL_CYCCNTENA_Msk;
  WicCache* c = new (std::nothrow) WicCache{};
  WicItem* items = new (std::nothrow) WicItem[WIO_IMAGE_CACHE_ITEMS];
  if (!c || !items) {
    std::fprintf(stderr, "[Wio] image cache: out of memory for its table\n");
    delete c;
    delete[] items;
    wio_sd_close(g_pack);
    return false;
  }
  c->log = log_line;
  c->ticks = cycles;
  // The cycle counter's rate against micros(): SystemCoreClock on the board,
  // the model's own under Renode. micros() itself misses the SysTicks of a
  // write, which runs with interrupts off.
  const uint32_t c0 = cycles(), m0 = micros();
  delay(2);
  const uint32_t us = micros() - m0;
  c->ticks_per_us = us ? (cycles() - c0) / us : SystemCoreClock / 1000000;
  const WicFlash flash{reinterpret_cast<const uint8_t*>(g_region),
                       static_cast<uint32_t>(WIO_QSPI_FLASH_END - g_region),
                       flash_erase, flash_program, nullptr};
  const WicPack pack{wio_sd_size(g_pack), pack_read, nullptr};
  char why[96] = "a malformed directory";
  if (!wic_open(c, flash, pack, items, WIO_IMAGE_CACHE_ITEMS, why,
                sizeof(why)) ||
      !rgss_set_rom_bitmap_source(wic_directory(c), c->dir_size, pack.size,
                                  root, &c->source)) {
    std::fprintf(stderr,
                 "[Wio] image cache: %s/" WIO_IMAGE_PACK
                 " not used (%s): images decode from their files\n",
                 WIO_SD_GAME_DIR, why);
    delete c;
    delete[] items;
    wio_sd_close(g_pack);
    return false;
  }
  std::fprintf(stderr, "[Wio] image cache: %u KB of QSPI flash at 0x%08x\n",
               static_cast<unsigned>(flash.size / 1024),
               static_cast<unsigned>(g_region));
  g_mrb = M;
  wic_set_files(c, {file_open, file_read, file_close, file_in_use, nullptr});
  g_cache = c;
  return true;
}

void wio_file_cache_ldb(bool on) {
  g_cache_ldb = on;
}

const void* wio_file_cache_map(const char* path, size_t* len) {
  const size_t root = sizeof(WIO_GAME_ROOT) - 1;
  if (!g_cache || std::strncmp(path, WIO_GAME_ROOT, root) != 0 ||
      path[root] != '/' || !cached_file(path + root + 1))
    return nullptr;
  uint32_t n = 0;
  const uint8_t* p = wic_file(g_cache, path + root + 1, &n);
  if (p)
    *len = n;
  return p;
}

void wio_image_cache_report() {
  if (!g_cache)
    return;
  const WicStats& s = g_cache->stats;
  std::fprintf(
      stderr,
      "[Wio] image cache: %u hits, %u misses (%u bytes copied), %u "
      "erased, %u evicted, %u failed; files: %u hits, %u misses (%u bytes "
      "copied), %u failed, %u in-use passes took back %u\n",
      static_cast<unsigned>(s.hits), static_cast<unsigned>(s.misses),
      static_cast<unsigned>(s.copied_bytes), static_cast<unsigned>(s.erased),
      static_cast<unsigned>(s.evicted), static_cast<unsigned>(s.failed),
      static_cast<unsigned>(s.file_hits), static_cast<unsigned>(s.file_misses),
      static_cast<unsigned>(s.file_bytes), static_cast<unsigned>(s.file_failed),
      static_cast<unsigned>(s.reclaims), static_cast<unsigned>(s.reclaimed));
}

#else

bool wio_image_cache_begin(const char*, mrb_state*) {
  return false;
}

const void* wio_file_cache_map(const char*, size_t*) {
  return nullptr;
}

void wio_file_cache_ldb(bool) {}

void wio_image_cache_report() {}

#endif

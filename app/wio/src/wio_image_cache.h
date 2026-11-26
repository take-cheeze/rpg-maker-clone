// IMAGE_CACHE: a microSD game's palette images, decoded ahead of time into a
// pack on the card (scripts/wio/sd_bitmaps.rb: an RGSSRB01 section, the
// ROM_BITMAP layout of mruby-rgss/src/lib.cxx), copied on first use into a
// region of the QSPI flash and read from there in place, as the image's own
// ROM bitmaps are. The core here is plain C++ over a flash and a pack
// interface (app/wio/test/image_cache_test.cxx runs it on the host);
// wio_image_cache_begin is the board's glue.
//
// Region layout, in 4 KB sectors: the header, the pack's directory (its bytes
// before the first blob, mapped for the lookups), then the items. An item is
// one entry's blobs, from a sector start: a 32-byte header, the indices, then
// the palette without and (when it differs) with the colour key, 16-aligned.
// Its header is programmed last, so an item only counts once it is whole. A
// miss takes the next run of sectors after the last item written that holds
// no pinned item, evicting what it overlaps: round robin, so every sector is
// erased once per lap. A boot finds the items again by their headers.
#pragma once

#include <cstddef>
#include <cstdint>

#include "rgss_rom_bitmaps.h"

constexpr uint32_t kWicSector = 4096;
constexpr uint32_t kWicPage = 256;

struct WicFlash {
  // The region as the CPU reads it, kWicSector-aligned, `size` bytes.
  const uint8_t* map;
  uint32_t size;
  void (*erase)(void* ctx, uint32_t off);  // one sector
  // Within the region; `data` is never in it.
  void (*program)(void* ctx, uint32_t off, const uint8_t* data, uint32_t len);
  void* ctx;
};

struct WicPack {
  uint32_t size;
  // `len` bytes at `off`; false when the card fails (the glue logs why).
  bool (*read)(void* ctx, uint32_t off, uint8_t* buf, uint32_t len);
  void* ctx;
};

struct WicItem {
  uint32_t seq;
  uint16_t index, sector, nsect, pins;
};

struct WicStats {
  uint32_t items, used_sectors, sectors;
  uint32_t misses, hits, copied_bytes, erased, evicted, failed;
};

struct WicCache {
  WicFlash flash;
  WicPack pack;
  uint32_t count;     // the pack's entries
  uint32_t pack_crc;  // the pack's own, from its header
  uint32_t dir_size;
  uint32_t first, end;  // the item sectors
  uint32_t head;        // where the next miss starts looking
  uint32_t next_seq;
  WicItem* items;
  uint32_t nitems, max_items;
  // The region offset of the last erase or program that did not read back, +1.
  uint32_t bad_write;
  WicStats stats;
  // Called with one line (no newline) per event worth a log line.
  void (*log)(const char* line);
  // A free-running counter, `ticks_per_us` a microsecond, for the times in
  // the log (a span must stay under one wrap); none on the host.
  uint32_t (*ticks)(void);
  uint32_t ticks_per_us;
  rgss_rom_bitmap_source source;
};

// Checks the region against the pack's header, copying the directory over
// when it is another pack's (or nothing's), and finds the items already
// copied. `items` holds room for `max_items` entries. False (with the reason
// in `why`) when the cache cannot be used.
bool wic_open(WicCache* c,
              const WicFlash& flash,
              const WicPack& pack,
              WicItem* items,
              uint32_t max_items,
              char* why,
              size_t why_len);
// The pack's directory in the region (wic_open's result).
const uint8_t* wic_directory(const WicCache* c);
// The rgss_rom_bitmap_source callbacks.
rgss_rom_fetch_result wic_fetch(void* ctx,
                                uint32_t index,
                                rgss_rom_bitmap_view* out);
void wic_release(void* ctx, uint32_t index);

#if defined(WIO_TERMINAL)
// The board's glue: a cache in the QSPI flash after the code and game images
// for the card's /rpg2k/wio_bitmaps.bin, installed as mruby-rgss's
// ROM_BITMAP_SOURCE under `root`. Logs the outcome with a [Wio] tag; false
// leaves every image to its file.
bool wio_image_cache_begin(const char* root);
#endif

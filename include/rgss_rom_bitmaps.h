// ROM_BITMAP (mruby-rgss/src/lib.cxx): palette images decoded ahead of time
// into an "RGSSRB01" section and read in place instead of from the heap.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Installs (or, with a null section, removes) a section held whole in memory,
// whose paths are relative to `root` (the game directory as the loader spells
// it). It must stay mapped while any bitmap may point into it.
bool rgss_set_rom_bitmaps(const void* section, size_t size, const char* root);

// ROM_BITMAP_SOURCE: a section whose directory (header, entries and paths:
// the bytes before the first pixel or palette blob) is mapped, and whose
// pixels and palettes are mapped one entry at a time, on demand. `fetch` maps
// entry `index` and pins it there until the matching `release`; every
// successful fetch is released once.
typedef struct {
  const uint8_t* px;
  // The palette of a load without and with the colour key (may be equal).
  const uint8_t* pal[2];
} rgss_rom_bitmap_view;

typedef enum {
  RGSS_ROM_FETCH_OK,
  // Not mapped (the source logged why): the loader decodes the file instead.
  RGSS_ROM_FETCH_FAILED,
  // No room while other entries stay pinned: the loader collects garbage
  // (releasing the bitmaps nothing holds) and asks once more.
  RGSS_ROM_FETCH_FULL,
} rgss_rom_fetch_result;

typedef struct {
  rgss_rom_fetch_result (*fetch)(void* ctx,
                                 uint32_t index,
                                 rgss_rom_bitmap_view* out);
  void (*release)(void* ctx, uint32_t index);
  void* ctx;
} rgss_rom_bitmap_source;

// `directory` holds `dir_size` bytes of a `section_size`-byte section; the
// source must outlive every bitmap it mapped. Replaces any installed section.
bool rgss_set_rom_bitmap_source(const void* directory,
                                size_t dir_size,
                                size_t section_size,
                                const char* root,
                                const rgss_rom_bitmap_source* source);

#ifdef __cplusplus
}
#endif

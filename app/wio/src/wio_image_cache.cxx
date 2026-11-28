// IMAGE_CACHE core: see wio_image_cache.h. No board code here, so the host
// test (app/wio/test/image_cache_test.cxx) runs this file as it is.
#include "wio_image_cache.h"

#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <initializer_list>

namespace {

constexpr char kRegionMagic[8] = {'W', 'I', 'O', 'I', 'M', 'C', '0', '1'};
constexpr uint32_t kItemMagic = 0x314d4957;  // "WIM1"
constexpr uint32_t kFileMagic = 0x31464957;  // "WIF1"
constexpr uint32_t kItemHeader = 32;
constexpr uint32_t kPackHeader = 16;
constexpr uint32_t kEntry = 32;

// The region's first page.
struct RegionHeader {
  char magic[8];
  uint32_t pack_crc, pack_size, count, dir_size, size, check;
};
struct ItemHeader {
  uint32_t magic, seq, gen;
  uint16_t index, sector, nsect, reserved;
  uint32_t pal1_off, px_bytes, check;
};
static_assert(sizeof(ItemHeader) == kItemHeader, "one item header");
// FILE_CACHE: followed by the path (path_len bytes and a NUL), then the file
// at file_data_off(path_len). `check` also covers the path.
struct FileHeader {
  uint32_t magic, seq, gen;
  uint16_t sector, nsect;
  uint32_t key, size;
  uint16_t path_len, reserved;
  uint32_t check;
};
static_assert(sizeof(FileHeader) == kItemHeader, "one file item header");

// The pack's entry (mruby-rgss/src/lib.cxx's RomBitmapEntry).
struct Entry {
  uint32_t path_off, px_off, w, h;
  uint32_t pal_off[2], bpp[2];
};

// FNV-1a: the headers' self-check, not the pack's identity (its CRC is).
uint32_t fnv(const void* p, size_t n, uint32_t h = 2166136261u) {
  const uint8_t* b = static_cast<const uint8_t*>(p);
  for (size_t i = 0; i < n; ++i)
    h = (h ^ b[i]) * 16777619u;
  return h;
}

uint32_t u32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24);
}

uint32_t sectors(uint32_t bytes) {
  return (bytes + kWicSector - 1) / kWicSector;
}

uint32_t align16(uint32_t n) {
  return (n + 15) & ~15u;
}

// Where a file item's bytes start: after its header and path.
uint32_t file_data_off(uint32_t path_len) {
  return kItemHeader + align16(path_len + 1);
}

uint32_t file_check(const FileHeader& h, const char* path) {
  return fnv(path, h.path_len, fnv(&h, offsetof(FileHeader, check)));
}

bool is_file(const WicItem& it) {
  return it.index == kWicFileItem;
}

// Whether two items hold the same image, or the same file.
bool same_entry(const WicItem& a, const WicItem& b) {
  return a.index == b.index && (!is_file(a) || a.key == b.key);
}

void logf(const WicCache* c, const char* fmt, ...)
    __attribute__((format(printf, 2, 3)));
void logf(const WicCache* c, const char* fmt, ...) {
  if (!c->log)
    return;
  char line[160];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(line, sizeof(line), fmt, ap);
  va_end(ap);
  c->log(line);
}

uint32_t now(const WicCache* c) {
  return c->ticks ? c->ticks() : 0;
}

// Microseconds since `t0`, a now().
unsigned since(const WicCache* c, uint32_t t0) {
  return c->ticks ? (now(c) - t0) / c->ticks_per_us : 0;
}

const Entry& entry(const WicCache* c, uint32_t index) {
  return reinterpret_cast<const Entry*>(c->flash.map + kWicSector +
                                        kPackHeader)[index];
}

const char* path_of(const WicCache* c, uint32_t index) {
  return reinterpret_cast<const char*>(c->flash.map + kWicSector +
                                       entry(c, index).path_off);
}

bool blank(const WicCache* c, uint32_t sector) {
  const uint32_t* p =
      reinterpret_cast<const uint32_t*>(c->flash.map + sector * kWicSector);
  for (uint32_t i = 0; i < kWicSector / 4; ++i)
    if (p[i] != 0xffffffffu)
      return false;
  return true;
}

// Erases what is not erased already: a fresh chip, and the sectors no item
// was ever written to, need no erase. Every write is read back.
bool erase(WicCache* c, uint32_t sector) {
  if (blank(c, sector))
    return true;
  c->flash.erase(c->flash.ctx, sector * kWicSector);
  ++c->stats.erased;
  if (blank(c, sector))
    return true;
  c->bad_write = sector * kWicSector + 1;
  return false;
}

bool program(WicCache* c, uint32_t off, const uint8_t* data, uint32_t len) {
  c->flash.program(c->flash.ctx, off, data, len);
  if (std::memcmp(c->flash.map + off, data, len) == 0)
    return true;
  c->bad_write = off + 1;
  return false;
}

// Copies `len` pack bytes from `from` to region offset `to`, a page at a time
// through a stack buffer.
bool copy(WicCache* c, uint32_t from, uint32_t to, uint32_t len) {
  uint8_t buf[kWicPage];
  while (len) {
    const uint32_t n = len < kWicPage ? len : kWicPage;
    if (!c->pack.read(c->pack.ctx, from, buf, n) || !program(c, to, buf, n))
      return false;
    from += n;
    to += n;
    len -= n;
  }
  return true;
}

// The directory's size: the table and paths, up to the first blob.
bool directory_size(WicCache* c, uint32_t* out) {
  uint32_t dir = c->pack.size;
  uint8_t buf[kEntry * 8];
  for (uint32_t i = 0; i < c->count; i += 8) {
    const uint32_t n = c->count - i < 8 ? c->count - i : 8;
    if (!c->pack.read(c->pack.ctx, kPackHeader + i * kEntry, buf, n * kEntry))
      return false;
    for (uint32_t k = 0; k < n; ++k) {
      Entry e;
      std::memcpy(&e, buf + k * kEntry, kEntry);
      for (const uint32_t off : {e.px_off, e.pal_off[0], e.pal_off[1]})
        if (off < dir)
          dir = off;
    }
  }
  *out = dir;
  return true;
}

bool region_matches(const WicCache* c) {
  RegionHeader h;
  std::memcpy(&h, c->flash.map, sizeof(h));
  return std::memcmp(h.magic, kRegionMagic, 8) == 0 &&
         h.check == fnv(&h, offsetof(RegionHeader, check)) &&
         h.pack_crc == c->pack_crc && h.pack_size == c->pack.size &&
         h.count == c->count && h.size == c->flash.size &&
         h.dir_size >= kPackHeader + c->count * kEntry &&
         sectors(h.dir_size) + 2 <= c->flash.size / kWicSector;
}

// Erases the header first, so a reset part way leaves no region at all.
bool write_region(WicCache* c, uint32_t dir_size) {
  for (uint32_t s = 0; s <= sectors(dir_size); ++s)
    if (!erase(c, s))
      return false;
  if (!copy(c, 0, kWicSector, dir_size))
    return false;
  RegionHeader h;
  std::memcpy(h.magic, kRegionMagic, 8);
  h.pack_crc = c->pack_crc;
  h.pack_size = c->pack.size;
  h.count = c->count;
  h.dir_size = dir_size;
  h.size = c->flash.size;
  h.check = fnv(&h, offsetof(RegionHeader, check));
  return program(c, 0, reinterpret_cast<const uint8_t*>(&h), sizeof(h));
}

uint32_t item_bytes(const WicCache* c, uint32_t index, uint32_t* pal1_off) {
  const Entry& e = entry(c, index);
  const uint32_t pal0 = align16(kItemHeader + e.w * e.h);
  *pal1_off = e.pal_off[1] == e.pal_off[0] ? pal0 : pal0 + 1024;
  return *pal1_off + 1024;
}

bool overlaps(const WicItem& it, uint32_t s, uint32_t n) {
  return it.sector < s + n && s < it.sector + it.nsect;
}

void remove_item(WicCache* c, uint32_t i) {
  c->stats.used_sectors -= c->items[i].nsect;
  c->items[i] = c->items[--c->nitems];
}

// Finds the items left by earlier boots: every header that checks out, less
// those a newer one overlaps (writing it erased the sectors they share) or
// repeats the entry of. With more headers than the table holds, none is kept:
// every sector gets erased before it is written anyway.
void scan(WicCache* c) {
  c->nitems = 0;
  bool overflow = false;
  for (uint32_t s = c->first; s < c->end && !overflow; ++s) {
    const uint8_t* at = c->flash.map + s * kWicSector;
    if (u32(at) == kFileMagic) {
      FileHeader f;
      std::memcpy(&f, at, sizeof(f));
      const char* path = reinterpret_cast<const char*>(at + kItemHeader);
      if (f.path_len > kWicMaxPath || path[f.path_len] != '\0' ||
          f.check != file_check(f, path) || f.gen != c->pack_crc ||
          f.sector != s || f.key != fnv(path, f.path_len) ||
          f.nsect != sectors(file_data_off(f.path_len) + f.size) ||
          s + f.nsect > c->end)
        continue;
      if (c->nitems == c->max_items)
        overflow = true;
      else
        c->items[c->nitems++] = {f.seq,    f.key,   kWicFileItem,
                                 f.sector, f.nsect, 0};
      continue;
    }
    ItemHeader h;
    std::memcpy(&h, at, sizeof(h));
    if (h.magic != kItemMagic ||
        h.check != fnv(&h, offsetof(ItemHeader, check)) ||
        h.gen != c->pack_crc || h.sector != s || h.index >= c->count ||
        h.nsect == 0 || s + h.nsect > c->end)
      continue;
    uint32_t pal1;
    if (h.nsect != sectors(item_bytes(c, h.index, &pal1)) ||
        h.pal1_off != pal1 ||
        h.px_bytes != entry(c, h.index).w * entry(c, h.index).h)
      continue;
    if (c->nitems == c->max_items)
      overflow = true;
    else
      c->items[c->nitems++] = {h.seq, 0, h.index, h.sector, h.nsect, 0};
  }
  if (overflow)
    c->nitems = 0;
  // pins marks the stale ones until the table is compacted.
  for (uint32_t i = 0; i < c->nitems; ++i) {
    WicItem& it = c->items[i];
    for (uint32_t k = 0; k < c->nitems && !it.pins; ++k) {
      const WicItem& o = c->items[k];
      it.pins = o.seq > it.seq &&
                (overlaps(o, it.sector, it.nsect) || same_entry(o, it));
    }
  }
  // The stale ones still decide the head: the newest header is where the
  // last miss wrote.
  c->head = c->first;
  c->next_seq = 1;
  uint32_t kept = 0;
  for (uint32_t i = 0; i < c->nitems; ++i) {
    WicItem it = c->items[i];
    if (it.seq >= c->next_seq) {
      c->next_seq = it.seq + 1;
      c->head = it.sector + it.nsect < c->end ? it.sector + it.nsect : c->first;
    }
    if (!it.pins)
      c->items[kept++] = it;
  }
  c->nitems = kept;
  c->stats.used_sectors = 0;
  for (uint32_t i = 0; i < c->nitems; ++i)
    c->stats.used_sectors += c->items[i].nsect;
}

WicItem* find(WicCache* c, uint32_t index) {
  for (uint32_t i = 0; i < c->nitems; ++i)
    if (c->items[i].index == index)
      return &c->items[i];
  return nullptr;
}

WicItem* find_file(WicCache* c, const char* path, uint32_t key) {
  const size_t n = std::strlen(path);
  for (uint32_t i = 0; i < c->nitems; ++i) {
    const WicItem& it = c->items[i];
    if (!is_file(it) || it.key != key)
      continue;
    FileHeader h;
    std::memcpy(&h, c->flash.map + it.sector * kWicSector, sizeof(h));
    if (h.path_len == n &&
        std::memcmp(c->flash.map + it.sector * kWicSector + kItemHeader, path,
                    n) == 0)
      return &c->items[i];
  }
  return nullptr;
}

// FILE_CACHE: asks WicFiles::in_use which file items handed out are still
// pointed into, a batch at a time, and takes the others back. Whether any was.
bool reclaim(WicCache* c) {
  if (!c->files.in_use)
    return false;
  constexpr uint32_t kBatch = 16;
  WicRange ranges[kBatch];
  bool used[kBatch];
  uint32_t idx[kBatch];
  uint32_t freed = 0;
  for (uint32_t i = 0; i < c->nitems;) {
    uint32_t n = 0;
    for (; i < c->nitems && n < kBatch; ++i) {
      const WicItem& it = c->items[i];
      if (!is_file(it) || !it.pins)
        continue;
      ranges[n] = {c->flash.map + it.sector * kWicSector,
                   it.nsect * kWicSector};
      idx[n++] = i;
    }
    if (!n)
      break;
    ++c->stats.reclaims;
    c->files.in_use(c->files.ctx, ranges, n, used);
    for (uint32_t k = 0; k < n; ++k)
      if (!used[k]) {
        c->items[idx[k]].pins = 0;
        ++freed;
      }
  }
  c->stats.reclaimed += freed;
  return freed > 0;
}

void view(const WicCache* c, const WicItem& it, rgss_rom_bitmap_view* out) {
  const uint8_t* base = c->flash.map + it.sector * kWicSector;
  ItemHeader h;
  std::memcpy(&h, base, sizeof(h));
  out->px = base + kItemHeader;
  out->pal[0] = base + align16(kItemHeader + h.px_bytes);
  out->pal[1] = base + h.pal1_off;
}

// The first run of `need` sectors from the head on that holds no pinned
// item, or false when every such run does.
bool place(WicCache* c, uint32_t need, uint32_t* out) {
  uint32_t p = c->head;
  // Two laps at most: a pinned item moves the start past it.
  for (uint32_t walked = 0; walked <= 2 * (c->end - c->first);) {
    if (p + need > c->end) {
      walked += c->end - p;
      p = c->first;
      continue;
    }
    const WicItem* blocker = nullptr;
    for (uint32_t i = 0; i < c->nitems; ++i)
      if (c->items[i].pins && overlaps(c->items[i], p, need) &&
          (!blocker || c->items[i].sector > blocker->sector))
        blocker = &c->items[i];
    if (!blocker) {
      *out = p;
      return true;
    }
    const uint32_t next = blocker->sector + blocker->nsect;
    walked += next - p;
    p = next;
  }
  return false;
}

// The table is full: drops the oldest item not pinned. False when every one is.
bool drop_oldest(WicCache* c) {
  uint32_t oldest = c->nitems;
  for (uint32_t i = 0; i < c->nitems; ++i)
    if (!c->items[i].pins &&
        (oldest == c->nitems || c->items[i].seq < c->items[oldest].seq))
      oldest = i;
  if (oldest == c->nitems)
    return false;
  remove_item(c, oldest);
  ++c->stats.evicted;
  return true;
}

// A run of `need` erased sectors for a new item and a slot for it in the
// table, evicting what the run overlaps; a file item handed out is taken back
// first when nothing else makes room (reclaim). False when no room.
bool make_room(WicCache* c, uint32_t need, uint32_t* at) {
  if (c->nitems == c->max_items && !drop_oldest(c) &&
      !(reclaim(c) && drop_oldest(c)))
    return false;
  if (!place(c, need, at) && !(reclaim(c) && place(c, need, at)))
    return false;
  for (uint32_t i = 0; i < c->nitems;)
    if (overlaps(c->items[i], *at, need)) {
      remove_item(c, i);
      ++c->stats.evicted;
    } else {
      ++i;
    }
  bool ok = true;
  for (uint32_t s = *at; s < *at + need && ok; ++s)
    ok = erase(c, s);
  return ok;
}

// Copies entry `index` from the pack into a free run; the new item, pinned
// once, or nullptr.
WicItem* fill(WicCache* c, uint32_t index, rgss_rom_fetch_result* why) {
  *why = RGSS_ROM_FETCH_FAILED;
  uint32_t pal1;
  const uint32_t bytes = item_bytes(c, index, &pal1);
  const uint32_t need = sectors(bytes);
  if (need > c->end - c->first) {
    logf(c, "image cache: %s (%u bytes) is larger than the cache",
         path_of(c, index), static_cast<unsigned>(bytes));
    return nullptr;
  }
  const uint32_t t0 = now(c);
  const uint32_t erased0 = c->stats.erased;
  uint32_t at;
  c->bad_write = 0;
  if (!make_room(c, need, &at)) {
    if (!c->bad_write) {
      *why = RGSS_ROM_FETCH_FULL;
      return nullptr;
    }
  }
  bool ok = !c->bad_write;
  const Entry& e = entry(c, index);
  const uint32_t off = at * kWicSector;
  const uint32_t px = e.w * e.h;
  const uint32_t pal0 = align16(kItemHeader + px);
  // The first page, header included, is programmed last. The reads go in the
  // pack's order (an entry's blobs follow its indices), as a card seeks
  // backwards slowly.
  const uint32_t first_px =
      px < kWicPage - kItemHeader ? px : kWicPage - kItemHeader;
  uint8_t page[kWicPage];
  ok = ok &&
       c->pack.read(c->pack.ctx, e.px_off, page + kItemHeader, first_px) &&
       copy(c, e.px_off + first_px, off + kItemHeader + first_px,
            px - first_px) &&
       copy(c, e.pal_off[0], off + pal0, 1024) &&
       (pal1 == pal0 || copy(c, e.pal_off[1], off + pal1, 1024));
  ItemHeader h{kItemMagic,
               c->next_seq,
               c->pack_crc,
               static_cast<uint16_t>(index),
               static_cast<uint16_t>(at),
               static_cast<uint16_t>(need),
               0,
               pal1,
               px,
               0};
  h.check = fnv(&h, offsetof(ItemHeader, check));
  std::memcpy(page, &h, sizeof(h));
  ok = ok && program(c, off, page, kItemHeader + first_px);
  if (!ok) {
    // No header, so no item: the sectors are free for the next miss.
    if (c->bad_write)
      logf(c, "image cache: %s: the QSPI flash did not take a write at +0x%x",
           path_of(c, index), static_cast<unsigned>(c->bad_write - 1));
    else
      logf(c, "image cache: %s: the card read failed", path_of(c, index));
    return nullptr;
  }
  ++c->next_seq;
  WicItem& it = c->items[c->nitems++];
  it = {h.seq, 0, h.index, h.sector, h.nsect, 0};
  c->head = at + need < c->end ? at + need : c->first;
  c->stats.used_sectors += need;
  c->stats.copied_bytes += bytes;
  ++c->stats.misses;
  logf(c,
       "image cache: copied %s (%u bytes, %u sectors, %u erased) in %u us; "
       "%u of %u sectors used",
       path_of(c, index), static_cast<unsigned>(bytes),
       static_cast<unsigned>(need),
       static_cast<unsigned>(c->stats.erased - erased0), since(c, t0),
       static_cast<unsigned>(c->stats.used_sectors),
       static_cast<unsigned>(c->end - c->first));
  *why = RGSS_ROM_FETCH_OK;
  return &it;
}

// FILE_CACHE: copies `len` bytes of the open file to region offset `to`, a
// page at a time.
bool copy_file(WicCache* c, uint32_t to, uint32_t len) {
  uint8_t buf[kWicPage];
  while (len) {
    const uint32_t n = len < kWicPage ? len : kWicPage;
    if (!c->files.read(c->files.ctx, buf, n) || !program(c, to, buf, n))
      return false;
    to += n;
    len -= n;
  }
  return true;
}

// Copies the open file (`size` bytes) at `path` into a free run: the new item,
// or nullptr (logged).
WicItem* fill_file(WicCache* c, const char* path, uint32_t key, uint32_t size) {
  const uint32_t path_len = static_cast<uint32_t>(std::strlen(path));
  const uint32_t data = file_data_off(path_len);
  const uint32_t bytes = data + size;
  const uint32_t need = sectors(bytes);
  if (need > c->end - c->first) {
    logf(c, "file cache: %s (%u bytes) is larger than the cache", path,
         static_cast<unsigned>(size));
    return nullptr;
  }
  const uint32_t t0 = now(c);
  const uint32_t erased0 = c->stats.erased;
  uint32_t at;
  c->bad_write = 0;
  if (!make_room(c, need, &at) && !c->bad_write) {
    logf(c, "file cache: no room for %s (%u bytes) while the rest is in use",
         path, static_cast<unsigned>(size));
    return nullptr;
  }
  // As fill: the first page, header and path included, is programmed last.
  const uint32_t off = at * kWicSector;
  const uint32_t first = size < kWicPage - data ? size : kWicPage - data;
  uint8_t page[kWicPage];
  std::memset(page, 0xff, sizeof(page));
  FileHeader h{kFileMagic,
               c->next_seq,
               c->pack_crc,
               static_cast<uint16_t>(at),
               static_cast<uint16_t>(need),
               key,
               size,
               static_cast<uint16_t>(path_len),
               0xffff,
               0};
  h.check = file_check(h, path);
  std::memcpy(page, &h, sizeof(h));
  std::memcpy(page + kItemHeader, path, path_len + 1);
  const bool ok = !c->bad_write &&
                  c->files.read(c->files.ctx, page + data, first) &&
                  copy_file(c, off + data + first, size - first) &&
                  program(c, off, page, data + first);
  if (!ok) {
    if (c->bad_write)
      logf(c, "file cache: %s: the QSPI flash did not take a write at +0x%x",
           path, static_cast<unsigned>(c->bad_write - 1));
    else
      logf(c, "file cache: %s: the card read failed", path);
    return nullptr;
  }
  ++c->next_seq;
  WicItem& it = c->items[c->nitems++];
  it = {h.seq, key, kWicFileItem, h.sector, h.nsect, 0};
  c->head = at + need < c->end ? at + need : c->first;
  c->stats.used_sectors += need;
  c->stats.file_bytes += size;
  ++c->stats.file_misses;
  logf(c,
       "file cache: copied %s (%u bytes, %u sectors, %u erased) in %u us; "
       "%u of %u sectors used",
       path, static_cast<unsigned>(size), static_cast<unsigned>(need),
       static_cast<unsigned>(c->stats.erased - erased0), since(c, t0),
       static_cast<unsigned>(c->stats.used_sectors),
       static_cast<unsigned>(c->end - c->first));
  return &it;
}

}  // namespace

bool wic_open(WicCache* c,
              const WicFlash& flash,
              const WicPack& pack,
              WicItem* items,
              uint32_t max_items,
              char* why,
              size_t why_len) {
  void (*log)(const char*) = c->log;
  uint32_t (*ticks)(void) = c->ticks;
  const uint32_t ticks_per_us = c->ticks_per_us;
  *c = WicCache{};
  c->log = log;
  c->ticks = ticks;
  c->ticks_per_us = ticks_per_us ? ticks_per_us : 1;
  c->flash = flash;
  c->pack = pack;
  c->items = items;
  c->max_items = max_items;
  uint8_t head[kPackHeader];
  if (pack.size < kPackHeader || !pack.read(pack.ctx, 0, head, kPackHeader) ||
      std::memcmp(head, "RGSSRB01", 8) != 0) {
    std::snprintf(why, why_len, "not an RGSSRB01 pack");
    return false;
  }
  c->count = u32(head + 8);
  c->pack_crc = u32(head + 12);
  if (c->pack_crc == 0) {
    std::snprintf(why, why_len,
                  "the pack has no checksum (rebuild it with "
                  "scripts/wio/sd_bitmaps.rb)");
    return false;
  }
  if (c->count > 0xffff ||
      kPackHeader + uint64_t(c->count) * kEntry > pack.size) {
    std::snprintf(why, why_len, "a malformed pack (%u entries)",
                  static_cast<unsigned>(c->count));
    return false;
  }
  const uint32_t total = flash.size / kWicSector;
  const uint32_t t0 = now(c);
  if (!region_matches(c)) {
    uint32_t dir = 0;
    if (!directory_size(c, &dir)) {
      std::snprintf(why, why_len, "the card read failed");
      return false;
    }
    if (dir < kPackHeader + c->count * kEntry || sectors(dir) + 2 > total) {
      std::snprintf(
          why, why_len, "the pack's %u-byte directory does not fit %u bytes",
          static_cast<unsigned>(dir), static_cast<unsigned>(flash.size));
      return false;
    }
    if (!write_region(c, dir)) {
      if (c->bad_write)
        std::snprintf(why, why_len,
                      "the QSPI flash did not take a write at +0x%x",
                      static_cast<unsigned>(c->bad_write - 1));
      else
        std::snprintf(why, why_len, "the card read failed");
      return false;
    }
    logf(c,
         "image cache: a new pack (crc %08x, %u images): copied its %u-byte "
         "directory in %u us",
         static_cast<unsigned>(c->pack_crc), static_cast<unsigned>(c->count),
         static_cast<unsigned>(dir), since(c, t0));
  }
  RegionHeader h;
  std::memcpy(&h, flash.map, sizeof(h));
  c->dir_size = h.dir_size;
  c->first = 1 + sectors(h.dir_size);
  c->end = total;
  c->stats.sectors = c->end - c->first;
  const uint32_t t1 = now(c);
  scan(c);
  c->stats.items = c->nitems;
  uint32_t files = 0;
  for (uint32_t i = 0; i < c->nitems; ++i)
    files += is_file(c->items[i]);
  logf(c,
       "image cache: %u images, %u already cached, and %u files (%u of %u "
       "sectors), scanned in %u us",
       static_cast<unsigned>(c->count),
       static_cast<unsigned>(c->nitems - files), static_cast<unsigned>(files),
       static_cast<unsigned>(c->stats.used_sectors),
       static_cast<unsigned>(c->stats.sectors), since(c, t1));
  c->source = {wic_fetch, wic_release, c};
  return true;
}

const uint8_t* wic_directory(const WicCache* c) {
  return c->flash.map + kWicSector;
}

rgss_rom_fetch_result wic_fetch(void* ctx,
                                uint32_t index,
                                rgss_rom_bitmap_view* out) {
  WicCache* c = static_cast<WicCache*>(ctx);
  if (index >= c->count)
    return RGSS_ROM_FETCH_FAILED;
  WicItem* it = find(c, index);
  if (it) {
    ++c->stats.hits;
  } else {
    rgss_rom_fetch_result why;
    it = fill(c, index, &why);
    if (!it) {
      if (why == RGSS_ROM_FETCH_FAILED)
        ++c->stats.failed;
      return why;
    }
  }
  ++it->pins;
  view(c, *it, out);
  return RGSS_ROM_FETCH_OK;
}

void wic_release(void* ctx, uint32_t index) {
  WicCache* c = static_cast<WicCache*>(ctx);
  WicItem* it = find(c, index);
  if (it && it->pins) {
    --it->pins;
    return;
  }
  logf(c, "image cache: entry %u released while not pinned",
       static_cast<unsigned>(index));
}

void wic_set_files(WicCache* c, const WicFiles& files) {
  c->files = files;
}

const uint8_t* wic_file(WicCache* c, const char* path, uint32_t* len) {
  const size_t path_len = std::strlen(path);
  if (!c->files.open || path_len == 0 || path_len > kWicMaxPath)
    return nullptr;
  const uint32_t key = fnv(path, path_len);
  WicItem* it = find_file(c, path, key);
  if (it) {
    ++c->stats.file_hits;
  } else {
    uint32_t size = 0;
    if (!c->files.open(c->files.ctx, path, &size)) {
      ++c->stats.file_failed;
      return nullptr;
    }
    it = fill_file(c, path, key, size);
    c->files.close(c->files.ctx);
    if (!it) {
      ++c->stats.file_failed;
      return nullptr;
    }
  }
  it->pins = 1;
  const uint8_t* base = c->flash.map + it->sector * kWicSector;
  FileHeader h;
  std::memcpy(&h, base, sizeof(h));
  *len = h.size;
  return base + file_data_off(h.path_len);
}

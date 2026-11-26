// Host unit test for the Wio's QSPI image cache core (IMAGE_CACHE,
// app/wio/src/wio_image_cache.cxx), run by CTest as `wio_image_cache`. The
// flash here behaves as NOR does (an erase sets a sector to 0xFF, a program
// can only clear bits) and refuses a program over bytes that are not erased,
// so the test also checks that the cache never relies on rewriting in place.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "wio_image_cache.h"

namespace {

int g_checks = 0;
int g_failures = 0;

void check(bool cond, const char* what, int line) {
  ++g_checks;
  if (!cond) {
    ++g_failures;
    std::fprintf(stderr, "FAIL line %d: %s\n", line, what);
  }
}
#define CHECK(c) check((c), #c, __LINE__)

struct Image {
  std::string path;
  uint32_t w, h;
  uint8_t seed;
  bool keyed_differs;
};

void put32(std::vector<uint8_t>& v, size_t at, uint32_t x) {
  for (int i = 0; i < 4; ++i)
    v[at + i] = (x >> (8 * i)) & 0xff;
}

uint32_t get32(const uint8_t* p) {
  return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24);
}

// An RGSSRB01 section as scripts/wio/bitmap_section.rb lays it out (images
// in path order), with `crc` as its checksum word.
std::vector<uint8_t> make_pack(const std::vector<Image>& images, uint32_t crc) {
  const size_t head = 16 + images.size() * 32;
  size_t names = 0;
  for (const Image& im : images)
    names += im.path.size() + 1;
  std::vector<uint8_t> v(head + names, 0);
  std::memcpy(v.data(), "RGSSRB01", 8);
  put32(v, 8, static_cast<uint32_t>(images.size()));
  put32(v, 12, crc);
  auto place = [&](const std::vector<uint8_t>& blob) {
    while (v.size() % 16)
      v.push_back(0);
    const size_t at = v.size();
    v.insert(v.end(), blob.begin(), blob.end());
    return static_cast<uint32_t>(at);
  };
  size_t path_at = head;
  uint32_t shared_pal = 0;
  for (size_t i = 0; i < images.size(); ++i) {
    const Image& im = images[i];
    std::memcpy(v.data() + path_at, im.path.c_str(), im.path.size() + 1);
    std::vector<uint8_t> px(im.w * im.h);
    for (size_t k = 0; k < px.size(); ++k)
      px[k] = static_cast<uint8_t>(k * 7 + im.seed);
    std::vector<uint8_t> pal(1024), keyed(1024);
    for (size_t k = 0; k < 1024; ++k) {
      pal[k] = static_cast<uint8_t>(k + im.seed);
      keyed[k] = static_cast<uint8_t>(k * 3 + im.seed);
    }
    const uint32_t px_off = place(px);
    // Every image without a keyed palette of its own shares the first one,
    // as the packer stores an identical palette once.
    uint32_t pal0;
    if (im.keyed_differs || !shared_pal) {
      pal0 = place(pal);
      if (!im.keyed_differs)
        shared_pal = pal0;
    } else {
      pal0 = shared_pal;
    }
    const uint32_t pal1 = im.keyed_differs ? place(keyed) : pal0;
    const size_t row = 16 + i * 32;
    put32(v, row, static_cast<uint32_t>(path_at));
    put32(v, row + 4, px_off);
    put32(v, row + 8, im.w);
    put32(v, row + 12, im.h);
    put32(v, row + 16, pal0);
    put32(v, row + 20, pal1);
    put32(v, row + 24, 4);
    put32(v, row + 28, 4);
    path_at += im.path.size() + 1;
  }
  return v;
}

struct Flash {
  std::vector<uint8_t> bytes;
  std::vector<uint32_t> erases;
  bool bad_program = false;
  // Programs after this many stop reaching the chip: a reset part way.
  long budget = -1;
};

void flash_erase(void* ctx, uint32_t off) {
  Flash& f = *static_cast<Flash*>(ctx);
  if (off % kWicSector || off >= f.bytes.size()) {
    f.bad_program = true;
    return;
  }
  if (f.budget == 0)
    return;
  std::memset(f.bytes.data() + off, 0xff, kWicSector);
  ++f.erases[off / kWicSector];
}

void flash_program(void* ctx, uint32_t off, const uint8_t* data, uint32_t len) {
  Flash& f = *static_cast<Flash*>(ctx);
  if (off + len > f.bytes.size() ||
      (data >= f.bytes.data() && data < f.bytes.data() + f.bytes.size())) {
    f.bad_program = true;
    return;
  }
  if (f.budget == 0)
    return;
  if (f.budget > 0)
    --f.budget;
  for (uint32_t i = 0; i < len; ++i) {
    if (f.bytes[off + i] != 0xff)
      f.bad_program = true;
    f.bytes[off + i] &= data[i];
  }
}

struct Pack {
  std::vector<uint8_t> bytes;
  bool fail = false;
  uint32_t reads = 0;
};

bool pack_read(void* ctx, uint32_t off, uint8_t* buf, uint32_t len) {
  Pack& p = *static_cast<Pack*>(ctx);
  ++p.reads;
  if (p.fail || off + len > p.bytes.size())
    return false;
  std::memcpy(buf, p.bytes.data() + off, len);
  return true;
}

std::vector<std::string> g_log;
void log_line(const char* line) {
  g_log.push_back(line);
}

struct Rig {
  Flash flash;
  Pack pack;
  WicCache cache{};
  std::vector<WicItem> items;

  Rig(uint32_t sectors, std::vector<uint8_t> pack_bytes, uint32_t max_items) {
    // A chip that held something else before.
    flash.bytes.assign(sectors * kWicSector, 0x5a);
    flash.erases.assign(sectors, 0);
    pack.bytes = std::move(pack_bytes);
    items.resize(max_items);
  }

  bool open() {
    cache.log = log_line;
    char why[96] = "";
    const WicFlash fl{flash.bytes.data(),
                      static_cast<uint32_t>(flash.bytes.size()), flash_erase,
                      flash_program, &flash};
    const WicPack pk{static_cast<uint32_t>(pack.bytes.size()), pack_read,
                     &pack};
    const bool ok =
        wic_open(&cache, fl, pk, items.data(),
                 static_cast<uint32_t>(items.size()), why, sizeof(why));
    if (!ok)
      g_log.push_back(why);
    return ok;
  }

  rgss_rom_fetch_result fetch(uint32_t index, rgss_rom_bitmap_view* v) {
    return wic_fetch(&cache, index, v);
  }
};

// Whether `v` shows entry `index` of the pack as it is there.
bool shows(const Rig& r, uint32_t index, const rgss_rom_bitmap_view& v) {
  const uint8_t* e = r.pack.bytes.data() + 16 + index * 32;
  const uint8_t* p = r.pack.bytes.data();
  const uint32_t n = get32(e + 8) * get32(e + 12);
  return std::memcmp(v.px, p + get32(e + 4), n) == 0 &&
         std::memcmp(v.pal[0], p + get32(e + 16), 1024) == 0 &&
         std::memcmp(v.pal[1], p + get32(e + 20), 1024) == 0 &&
         v.px >= r.flash.bytes.data() &&
         v.pal[1] + 1024 <= r.flash.bytes.data() + r.flash.bytes.size();
}

// Eight images of one to five sectors as items, in path order.
std::vector<Image> images() {
  return {{"CharSet/a.png", 96, 128, 1, false},   // 12288 + palettes: 4 sectors
          {"CharSet/b.png", 96, 128, 2, true},    // 4 sectors
          {"ChipSet/c.png", 120, 160, 3, false},  // 5 sectors
          {"FaceSet/d.png", 48, 48, 4, false},    // 1 sector
          {"System/e.png", 60, 30, 5, true},      // 1 sector
          {"System/f.png", 10, 10, 6, false},     // 1 sector
          {"Title/g.png", 64, 64, 7, true},       // 2 sectors
          {"Title/h.png", 2, 300, 8, false}};     // 1 sector
}

void test_copy_and_hit() {
  Rig r(32, make_pack(images(), 0x1234), 16);
  CHECK(r.open());
  // The directory is the pack's own bytes up to the first blob.
  CHECK(std::memcmp(wic_directory(&r.cache), r.pack.bytes.data(),
                    r.cache.dir_size) == 0);
  CHECK(r.cache.dir_size == get32(r.pack.bytes.data() + 16 + 4));
  rgss_rom_bitmap_view v{};
  for (uint32_t i = 0; i < 8; ++i) {
    CHECK(r.fetch(i, &v) == RGSS_ROM_FETCH_OK);
    CHECK(shows(r, i, v));
    CHECK((v.pal[0] - r.flash.bytes.data()) % 16 == 0);
  }
  CHECK(r.cache.stats.misses == 8);
  const uint32_t reads = r.pack.reads;
  CHECK(r.fetch(2, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 2, v));
  CHECK(r.pack.reads == reads);
  CHECK(r.cache.stats.hits == 1);
  for (uint32_t i = 0; i < 8; ++i)
    wic_release(&r.cache, i);
  wic_release(&r.cache, 2);
  CHECK(!r.flash.bad_program);
  CHECK(r.fetch(8, &v) == RGSS_ROM_FETCH_FAILED);
}

void test_round_robin_and_pins() {
  // 20 sectors: the header, 1 of directory, items in 2..19.
  Rig r(20, make_pack(images(), 0x1234), 16);
  CHECK(r.open());
  CHECK(r.cache.first == 2 && r.cache.end == 20);
  rgss_rom_bitmap_view v{}, va{};
  // a at 2..5 stays pinned; b 6..9, c 10..14, d 15, e 16, g 17..18, h 19.
  CHECK(r.fetch(0, &va) == RGSS_ROM_FETCH_OK);
  for (uint32_t i : {1u, 2u, 3u, 4u, 6u, 7u}) {
    CHECK(r.fetch(i, &v) == RGSS_ROM_FETCH_OK);
    wic_release(&r.cache, i);
  }
  CHECK(r.cache.stats.misses == 7 && r.cache.stats.evicted == 0);
  CHECK(r.cache.head == r.cache.first);
  // f wraps to the start, steps over the pinned a and takes b's place.
  CHECK(r.fetch(5, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 5, v));
  CHECK(v.px == r.flash.bytes.data() + 6 * kWicSector + 32);
  CHECK(r.cache.stats.evicted == 1);
  wic_release(&r.cache, 5);
  CHECK(r.fetch(0, &v) == RGSS_ROM_FETCH_OK);  // a: still a hit
  CHECK(v.px == va.px && shows(r, 0, v));
  CHECK(r.cache.stats.misses == 8);
  // b again: copied anew after f, over c.
  CHECK(r.fetch(1, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 1, v));
  CHECK(v.px == r.flash.bytes.data() + 7 * kWicSector + 32);
  CHECK(r.cache.stats.misses == 9 && r.cache.stats.evicted == 2);
  CHECK(shows(r, 0, va));
  CHECK(!r.flash.bad_program);
}

void test_full() {
  Rig r(12, make_pack(images(), 0x1234), 16);  // 10 item sectors
  CHECK(r.open());
  rgss_rom_bitmap_view v{};
  CHECK(r.fetch(2, &v) == RGSS_ROM_FETCH_OK);    // c: 5
  CHECK(r.fetch(0, &v) == RGSS_ROM_FETCH_OK);    // a: 4
  CHECK(r.fetch(1, &v) == RGSS_ROM_FETCH_FULL);  // b: 4, no room while pinned
  wic_release(&r.cache, 0);
  CHECK(r.fetch(1, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 1, v));
  // Larger than the whole cache: decoded from its file instead.
  Rig tiny(6, make_pack(images(), 0x1234), 16);  // 4 item sectors
  CHECK(tiny.open());
  CHECK(tiny.fetch(2, &v) == RGSS_ROM_FETCH_FAILED);
  CHECK(!r.flash.bad_program && !tiny.flash.bad_program);
}

void test_table_full() {
  Rig r(40, make_pack(images(), 0x1234), 3);
  CHECK(r.open());
  rgss_rom_bitmap_view v{};
  for (uint32_t i : {3u, 5u, 7u}) {
    CHECK(r.fetch(i, &v) == RGSS_ROM_FETCH_OK);
    wic_release(&r.cache, i);
  }
  CHECK(r.fetch(4, &v) == RGSS_ROM_FETCH_OK);  // drops the oldest, d
  CHECK(r.cache.nitems == 3);
  CHECK(r.fetch(5, &v) == RGSS_ROM_FETCH_OK);
  CHECK(r.fetch(7, &v) == RGSS_ROM_FETCH_OK);
  CHECK(r.fetch(3, &v) == RGSS_ROM_FETCH_FULL);  // all three pinned
  // d left the table but not the flash: a boot with a larger table finds it
  // again, and every item it finds shows its entry.
  std::vector<WicItem> items(16);
  WicCache again{};
  const WicFlash fl{r.flash.bytes.data(),
                    static_cast<uint32_t>(r.flash.bytes.size()), flash_erase,
                    flash_program, &r.flash};
  const WicPack pk{static_cast<uint32_t>(r.pack.bytes.size()), pack_read,
                   &r.pack};
  char why[96];
  CHECK(wic_open(&again, fl, pk, items.data(), 16, why, sizeof(why)));
  CHECK(again.nitems == 4);
  for (uint32_t i : {3u, 4u, 5u, 7u}) {
    CHECK(wic_fetch(&again, i, &v) == RGSS_ROM_FETCH_OK);
    CHECK(shows(r, i, v));
  }
  CHECK(again.stats.misses == 0);
}

// A boot after a miss wrote over the tail of an item no longer in the table:
// that item's header is still there, and the newer item wins.
void test_stale_header() {
  Rig r(14, make_pack(images(), 0x1234), 1);  // 12 item sectors, a 1-item table
  CHECK(r.open());
  rgss_rom_bitmap_view v{};
  CHECK(r.fetch(2, &v) == RGSS_ROM_FETCH_OK);  // c at 2..6
  wic_release(&r.cache, 2);
  r.cache.head = 4;  // as if c's start had been reached from elsewhere
  CHECK(r.fetch(0, &v) == RGSS_ROM_FETCH_OK);  // a at 4..7, over c's tail
  CHECK(shows(r, 0, v));
  std::vector<WicItem> items(16);
  WicCache again{};
  const WicFlash fl{r.flash.bytes.data(),
                    static_cast<uint32_t>(r.flash.bytes.size()), flash_erase,
                    flash_program, &r.flash};
  const WicPack pk{static_cast<uint32_t>(r.pack.bytes.size()), pack_read,
                   &r.pack};
  char why[96];
  CHECK(wic_open(&again, fl, pk, items.data(), 16, why, sizeof(why)));
  CHECK(again.nitems == 1 && again.items[0].index == 0);
  CHECK(again.head == 8);
  CHECK(wic_fetch(&again, 2, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 2, v));
  CHECK(again.stats.misses == 1);
}

void test_reboot_and_new_pack() {
  Rig r(24, make_pack(images(), 0x1234), 16);
  CHECK(r.open());
  rgss_rom_bitmap_view v{};
  for (uint32_t i = 0; i < 4; ++i) {
    CHECK(r.fetch(i, &v) == RGSS_ROM_FETCH_OK);
    wic_release(&r.cache, i);
  }
  const uint32_t head = r.cache.head;
  // The same flash and pack, a new boot: every item is found, none copied.
  WicCache again{};
  again.log = log_line;
  std::vector<WicItem> items(16);
  const WicFlash fl{r.flash.bytes.data(),
                    static_cast<uint32_t>(r.flash.bytes.size()), flash_erase,
                    flash_program, &r.flash};
  const WicPack pk{static_cast<uint32_t>(r.pack.bytes.size()), pack_read,
                   &r.pack};
  char why[96];
  const std::vector<uint32_t> erases = r.flash.erases;
  CHECK(wic_open(&again, fl, pk, items.data(), 16, why, sizeof(why)));
  CHECK(r.flash.erases == erases);
  CHECK(again.nitems == 4);
  CHECK(again.head == head);
  for (uint32_t i = 0; i < 4; ++i) {
    CHECK(wic_fetch(&again, i, &v) == RGSS_ROM_FETCH_OK);
    CHECK(shows(r, i, v));
  }
  CHECK(again.stats.misses == 0 && again.stats.hits == 4);

  // A reset while an item is written: no header, so no item, and the rest stay.
  r.flash.budget = 20;
  WicCache third{};
  CHECK(wic_open(&third, fl, pk, items.data(), 16, why, sizeof(why)));
  // The writes stop reaching the chip part way: the read-back notices.
  CHECK(wic_fetch(&third, 6, &v) == RGSS_ROM_FETCH_FAILED);
  CHECK(third.nitems == 4);
  r.flash.budget = -1;
  WicCache fourth{};
  CHECK(wic_open(&fourth, fl, pk, items.data(), 16, why, sizeof(why)));
  CHECK(fourth.nitems == 4);
  CHECK(wic_fetch(&fourth, 6, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 6, v));
  CHECK(fourth.stats.misses == 1);
  CHECK(wic_fetch(&fourth, 1, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 1, v));

  // Another pack: the directory is copied over and no old item counts.
  std::vector<Image> other = images();
  other[1].seed = 99;
  r.pack.bytes = make_pack(other, 0x5678);
  WicCache fifth{};
  const WicPack pk2{static_cast<uint32_t>(r.pack.bytes.size()), pack_read,
                    &r.pack};
  CHECK(wic_open(&fifth, fl, pk2, items.data(), 16, why, sizeof(why)));
  CHECK(fifth.nitems == 0);
  CHECK(wic_fetch(&fifth, 1, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 1, v));
  CHECK(!r.flash.bad_program);
}

void test_card_errors() {
  Rig r(24, make_pack(images(), 0x1234), 16);
  CHECK(r.open());
  rgss_rom_bitmap_view v{};
  r.pack.fail = true;
  CHECK(r.fetch(2, &v) == RGSS_ROM_FETCH_FAILED);
  CHECK(r.cache.nitems == 0);
  r.pack.fail = false;
  CHECK(r.fetch(2, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 2, v));
  CHECK(!r.flash.bad_program);

  // A flash that takes no write: the miss fails, and so does a new region.
  r.flash.budget = 0;
  CHECK(r.fetch(5, &v) == RGSS_ROM_FETCH_FAILED);
  r.flash.budget = -1;
  CHECK(r.fetch(5, &v) == RGSS_ROM_FETCH_OK);
  CHECK(shows(r, 5, v));
  Rig stuck(24, make_pack(images(), 0x1234), 16);
  stuck.flash.budget = 0;
  CHECK(!stuck.open());

  // No checksum, or not a pack at all: no cache.
  Rig bare(24, make_pack(images(), 0), 16);
  CHECK(!bare.open());
  Rig junk(24, std::vector<uint8_t>(64, 0), 16);
  CHECK(!junk.open());
  // A directory with no room after it.
  Rig small(2, make_pack(images(), 0x1234), 16);
  CHECK(!small.open());
}

// Wear: a lap erases each sector once at most. The last few sectors wear
// less, as a lap leaves them out when the next item does not fit there.
void test_wear() {
  std::vector<Image> many;
  for (int i = 0; i < 40; ++i)
    many.push_back({"CharSet/" + std::to_string(100 + i) + ".png",
                    static_cast<uint32_t>(32 + 40 * (i % 7)), 96,
                    static_cast<uint8_t>(i), i % 3 == 0});
  Rig r(66, make_pack(many, 0x1234), 64);  // 64 item sectors of 160 wanted
  CHECK(r.open());
  rgss_rom_bitmap_view v{};
  uint32_t seed = 1;
  for (int k = 0; k < 6000; ++k) {
    seed = seed * 1103515245u + 12345u;
    const uint32_t i = (seed >> 16) % 40;
    if (r.fetch(i, &v) == RGSS_ROM_FETCH_OK) {
      CHECK(shows(r, i, v));
      wic_release(&r.cache, i);
    }
  }
  std::vector<uint32_t> wear(r.flash.erases.begin() + r.cache.first,
                             r.flash.erases.begin() + r.cache.end);
  std::sort(wear.begin(), wear.end());
  const uint32_t median = wear[wear.size() / 2];
  std::printf("wear: %u misses over %zu sectors, %u..%u erases a sector\n",
              r.cache.stats.misses, wear.size(), wear.front(), wear.back());
  CHECK(wear.back() <= median + 1);
  CHECK(!r.flash.bad_program);
}

}  // namespace

int main() {
  test_copy_and_hit();
  test_round_robin_and_pins();
  test_full();
  test_table_full();
  test_stale_header();
  test_reboot_and_new_pack();
  test_card_errors();
  test_wear();
  if (g_failures) {
    for (const std::string& l : g_log)
      std::fprintf(stderr, "  log: %s\n", l.c_str());
  }
  std::printf("wio_image_cache: %d checks, %d failures\n", g_checks,
              g_failures);
  return g_failures ? 1 : 0;
}

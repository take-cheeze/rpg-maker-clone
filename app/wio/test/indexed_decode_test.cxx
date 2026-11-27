// Host unit test for the palette-image decoders
// (include/rgss_indexed_decode.hxx, ONE_BUFFER), run by CTest as
// `indexed_decode`: every PNG bit depth and filter, a stream split over several
// IDATs, a stream longer than the pixels, and XYZ, checked against the indices
// and palette they were written from and against stb_image's own decode of the
// same bytes, and the decode's large allocations counted.
#include <cstddef>
#include <cstdlib>
#include <new>

// Allocations of at least g_big bytes, through operator new or stb_image.
static size_t g_big = 0;
static int g_big_allocs = 0;
static void* counted(size_t n) {
  if (g_big && n >= g_big)
    ++g_big_allocs;
  return std::malloc(n ? n : 1);
}
void* operator new(size_t n) {
  if (void* p = counted(n))
    return p;
  throw std::bad_alloc();
}
void operator delete(void* p) noexcept {
  std::free(p);
}
void operator delete(void* p, size_t) noexcept {
  std::free(p);
}
#define STBI_MALLOC(n) counted(n)
#define STBI_REALLOC(p, n)                                          \
  ((g_big && static_cast<size_t>(n) >= g_big ? ++g_big_allocs : 0), \
   std::realloc(p, n))
#define STBI_FREE(p) std::free(p)
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static void set_bitmap_load_error(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::vfprintf(stderr, fmt, ap);
  va_end(ap);
  std::fputc('\n', stderr);
}

#include "rgss_indexed_decode.hxx"

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

uint32_t g_seed = 12345;
int rnd(int n) {
  g_seed = g_seed * 1103515245u + 12345u;
  return static_cast<int>((g_seed >> 8) % static_cast<uint32_t>(n));
}

void put_be32(std::vector<uint8_t>& v, uint32_t x) {
  for (int i = 3; i >= 0; --i)
    v.push_back((x >> (8 * i)) & 0xff);
}

void chunk(std::vector<uint8_t>& png,
           const char* type,
           const std::vector<uint8_t>& body) {
  put_be32(png, static_cast<uint32_t>(body.size()));
  std::vector<uint8_t> tb(type, type + 4);
  tb.insert(tb.end(), body.begin(), body.end());
  png.insert(png.end(), tb.begin(), tb.end());
  put_be32(png, stbiw__crc32(tb.data(), static_cast<int>(tb.size())));
}

std::vector<uint8_t> deflate(const std::vector<uint8_t>& raw) {
  int n = 0;
  unsigned char* z = stbi_zlib_compress(const_cast<uint8_t*>(raw.data()),
                                        static_cast<int>(raw.size()), &n, 8);
  std::vector<uint8_t> v(z, z + n);
  STBIW_FREE(z);
  return v;
}

int paeth(int a, int b, int c) {
  const int p = a + b - c, pa = std::abs(p - a), pb = std::abs(p - b),
            pc = std::abs(p - c);
  return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

struct Case {
  int w, h, depth, colours, idats;
  size_t extra;  // bytes past the pixels in the stream
};

// A colour type 3 PNG of random indices below `colours`, each row with a
// random filter; `idx` gets the indices.
std::vector<uint8_t> make_png(const Case& c,
                              std::vector<uint8_t>& idx,
                              std::vector<uint8_t>& plte) {
  const size_t rowbytes = (static_cast<size_t>(c.w) * c.depth + 7) / 8;
  const int per = 8 / c.depth;
  idx.assign(static_cast<size_t>(c.w) * c.h, 0);
  std::vector<uint8_t> raw, prev(rowbytes, 0);
  for (int y = 0; y < c.h; ++y) {
    std::vector<uint8_t> row(rowbytes, 0);
    for (int x = 0; x < c.w; ++x) {
      const int v = rnd(c.colours);
      idx[static_cast<size_t>(y) * c.w + x] = static_cast<uint8_t>(v);
      row[x / per] |= v << ((per - 1 - x % per) * c.depth);
    }
    const int ft = rnd(5);
    raw.push_back(static_cast<uint8_t>(ft));
    for (size_t x = 0; x < rowbytes; ++x) {
      const int a = x ? row[x - 1] : 0, b = prev[x], cc = x ? prev[x - 1] : 0;
      const int p = ft == 1   ? a
                    : ft == 2 ? b
                    : ft == 3 ? (a + b) >> 1
                    : ft == 4 ? paeth(a, b, cc)
                              : 0;
      raw.push_back(static_cast<uint8_t>(row[x] - p));
    }
    prev = row;
  }
  raw.insert(raw.end(), c.extra, 0);
  const std::vector<uint8_t> z = deflate(raw);
  plte.clear();
  for (int k = 0; k < c.colours * 3; ++k)
    plte.push_back(static_cast<uint8_t>(rnd(256)));
  std::vector<uint8_t> png = {0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a};
  std::vector<uint8_t> ihdr;
  put_be32(ihdr, c.w);
  put_be32(ihdr, c.h);
  ihdr.insert(ihdr.end(), {static_cast<uint8_t>(c.depth), 3, 0, 0, 0});
  chunk(png, "IHDR", ihdr);
  chunk(png, "PLTE", plte);
  // An empty IDAT first, then the stream in `idats` pieces.
  chunk(png, "IDAT", {});
  size_t at = 0;
  for (int i = 0; i < c.idats; ++i) {
    const size_t end =
        i + 1 == c.idats ? z.size() : z.size() * (i + 1) / c.idats;
    chunk(png, "IDAT", std::vector<uint8_t>(z.begin() + at, z.begin() + end));
    at = end;
  }
  chunk(png, "IEND", {});
  return png;
}

void png_case(const Case& c) {
  std::vector<uint8_t> want, plte;
  const std::vector<uint8_t> png = make_png(c, want, plte);
  IndexedImage ix;
  g_big = want.size();
  g_big_allocs = 0;
  CHECK(load_png_indexed(png.data(), png.size(), false, ix));
  g_big = 0;
  // ONE_BUFFER: with the stream in one IDAT, the indices' block is the only
  // one their size.
  CHECK(c.extra || c.idats > 1 || g_big_allocs == 1);
  CHECK(ix.w == c.w && ix.h == c.h);
  CHECK(ix.idx == want);
  CHECK(ix.direct_bpp == 3);
  // stb's own decode of the file, through the indices and palette.
  int w = 0, h = 0, n = 0;
  stbi__png_transparent_palette = false;
  stbi__png_to_bgr_palette = false;
  unsigned char* rgb = stbi_load_from_memory(
      png.data(), static_cast<int>(png.size()), &w, &h, &n, 3);
  CHECK(rgb != nullptr);
  if (!rgb)
    return;
  bool same = w == c.w && h == c.h;
  for (size_t p = 0; same && p < want.size(); ++p)
    for (int ch = 0; ch < 3; ++ch)
      same = same && rgb[p * 3 + ch] == ix.pal[want[p] * 4 + 2 - ch];
  CHECK(same);
  stbi_image_free(rgb);
}

void xyz_cases() {
  for (const int extra : {0, 64}) {
    const int w = 37, h = 11;
    std::vector<uint8_t> raw;
    for (int k = 0; k < 768 + w * h + extra; ++k)
      raw.push_back(static_cast<uint8_t>(rnd(256)));
    std::vector<uint8_t> xyz = {'X', 'Y', 'Z', '1', w, 0, h, 0};
    const std::vector<uint8_t> z = deflate(raw);
    xyz.insert(xyz.end(), z.begin(), z.end());
    IndexedImage ix;
    g_big = w * h;
    g_big_allocs = 0;
    CHECK(load_xyz_indexed(xyz.data(), xyz.size(), "test.xyz", true, ix));
    g_big = 0;
    CHECK(extra || g_big_allocs == 1);
    CHECK(ix.w == w && ix.h == h);
    CHECK(ix.idx ==
          std::vector<uint8_t>(raw.begin() + 768, raw.begin() + 768 + w * h));
    CHECK(ix.pal[0] == raw[2] && ix.pal[1] == raw[1] && ix.pal[2] == raw[0] &&
          ix.pal[3] == 0);
    CHECK(ix.pal[4] == raw[5] && ix.pal[7] == 255);
    // One byte short of the pixels does not decode.
    std::vector<uint8_t> shrt = {'X', 'Y', 'Z', '1', w, 0, h, 0};
    const std::vector<uint8_t> zs =
        deflate(std::vector<uint8_t>(raw.begin(), raw.begin() + 767 + w * h));
    shrt.insert(shrt.end(), zs.begin(), zs.end());
    IndexedImage bad;
    CHECK(!load_xyz_indexed(shrt.data(), shrt.size(), "short.xyz", false, bad));
  }
}

}  // namespace

int main() {
  for (const int depth : {1, 2, 4, 8})
    for (const int w : {1, 3, 17, 64, 481})
      for (const int idats : {1, 3})
        for (const size_t extra : {size_t{0}, size_t{100}})
          png_case({w, 1 + rnd(20), depth, 1 + rnd(1 << depth), idats, extra});
  xyz_cases();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures ? 1 : 0;
}

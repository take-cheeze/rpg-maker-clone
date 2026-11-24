// The palette-image decoders, shared by mruby-rgss/src/lib.cxx and the game
// ROM packer (scripts/wio/rom_bitmaps.cxx): a ROM bitmap is these functions'
// own output, so it cannot drift from what a runtime decode gives.
#pragma once

// After the includer's own stb_image.h, which may carry the implementation.
#ifndef STBI_INCLUDE_STB_IMAGE_H
#include <stb_image.h>
#endif

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

// Records why a decoder gave up; each includer defines it.
static void set_bitmap_load_error(const char* fmt, ...)
    __attribute__((format(printf, 1, 2)));

// Decode an RPG Maker 2000/2003 XYZ image. The format is a tiny header
//
//   "XYZ1"                     4-byte magic
//   uint16 LE width, height    picture dimensions
//   zlib stream                768-byte RGB palette + width*height indices
//
// which stb_image does not understand, so games that ship their System
// (windowskin) or other graphics as .xyz would otherwise fail to load. This
// returns the inflated palette-and-indices block (free with stbi_image_free)
// and sets *w/*h, or nullptr when the bytes are not an XYZ image or do not
// decode.
//
// Takes the bytes rather than a path so the same decoder serves a loose file
// and an entry pulled out of an encrypted RGSSAD archive; `label` only names
// the source in the diagnostics.
static char* xyz_inflate(const uint8_t* data,
                         size_t sz,
                         const char* label,
                         int* w,
                         int* h) {
  // Not an XYZ file: stay silent and let the caller keep stb_image's own error.
  if (sz < 8 || std::memcmp(data, "XYZ1", 4) != 0)
    return nullptr;

  const int width = data[4] | (data[5] << 8);
  const int height = data[6] | (data[7] << 8);
  if (width <= 0 || height <= 0) {
    set_bitmap_load_error("XYZ: invalid dimensions %dx%d in '%s'", width,
                          height, label);
    return nullptr;
  }

  const char* stream = reinterpret_cast<const char*>(data + 8);
  const int stream_len = (int)(sz - 8);
  // A 768-byte (256*3) RGB palette followed by one index per pixel.
  const long expected = 768L + (long)width * height;

  int outlen = 0;
  // RPG Maker writes a standard zlib stream (header byte 0x78). Decode that
  // first; if stb rejects it -- e.g. "bad dist" on a stream some tools emit as
  // raw DEFLATE with no zlib header -- retry without the 2-byte header before
  // giving up, so a wider range of System graphics still loads.
  char* raw = stbi_zlib_decode_malloc(stream, stream_len, &outlen);
  if (!raw) {
    char zerr[128];
    std::snprintf(zerr, sizeof(zerr), "%s", stbi_failure_reason());
    raw = stbi_zlib_decode_noheader_malloc(stream, stream_len, &outlen);
    if (!raw) {
      set_bitmap_load_error(
          "XYZ %dx%d '%s': zlib inflate failed (%s); zlib header 0x%02x%02x, "
          "%d compressed bytes, expected %ld decompressed",
          width, height, label, zerr, (unsigned)data[8], (unsigned)data[9],
          stream_len, expected);
      return nullptr;
    }
  }

  if ((long)outlen < expected) {
    set_bitmap_load_error(
        "XYZ %dx%d '%s': short data, got %d bytes, expected %ld (768 palette + "
        "%d pixels)",
        width, height, label, outlen, expected, width * height);
    stbi_image_free(raw);
    return nullptr;
  }
  *w = width;
  *h = height;
  return raw;
}

// ---- Tolerant PNG fallback ------------------------------------------------
//
// Some PNGs -- notably RPG Maker System/windowskin graphics -- ship an IDAT
// deflate stream with back-references that reach before the start of the
// output. The PNG/zlib spec forbids this, so strict inflaters (stb_image's
// bundled zlib, and zlib itself) reject them with "bad dist" / "invalid
// distance too far back". The producers rely on the missing pre-history reading
// as zeros. This self-contained decoder reproduces that behaviour so those
// images load instead of falling back to the plain panel. It runs only as a
// fallback after stb_image has already refused the file.
namespace png_tol {

struct BitReader {
  const uint8_t* p;
  const uint8_t* end;
  uint32_t buf = 0;
  int cnt = 0;
  bool fail = false;
  int bit() {
    if (cnt == 0) {
      if (p >= end) {
        fail = true;
        return 0;
      }
      buf = *p++;
      cnt = 8;
    }
    int b = buf & 1;
    buf >>= 1;
    cnt--;
    return b;
  }
  int bits(int n) {
    int v = 0;
    for (int i = 0; i < n; i++)
      v |= bit() << i;
    return v;
  }
};

struct Huff {
  short count[16];
  short symbol[288];
};

void huff_build(Huff& h, const uint8_t* len, int n) {
  for (int i = 0; i < 16; i++)
    h.count[i] = 0;
  for (int i = 0; i < n; i++)
    h.count[len[i]]++;
  h.count[0] = 0;
  short offs[16];
  offs[1] = 0;
  for (int l = 1; l < 15; l++)
    offs[l + 1] = offs[l] + h.count[l];
  for (int i = 0; i < n; i++)
    if (len[i])
      h.symbol[offs[len[i]]++] = (short)i;
}

int huff_decode(BitReader& br, const Huff& h) {
  int code = 0, first = 0, index = 0;
  for (int len = 1; len <= 15; len++) {
    code |= br.bit();
    int count = h.count[len];
    if (code - count < first)
      return h.symbol[index + (code - first)];
    index += count;
    first += count;
    first <<= 1;
    code <<= 1;
  }
  return -1;
}

const short LBASE[29] = {3,  4,  5,  6,   7,   8,   9,   10,  11, 13,
                         15, 17, 19, 23,  27,  31,  35,  43,  51, 59,
                         67, 83, 99, 115, 131, 163, 195, 227, 258};
const short LEXT[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
                        2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
const short DBASE[30] = {1,    2,    3,    4,     5,     7,    9,    13,
                         17,   25,   33,   49,    65,    97,   129,  193,
                         257,  385,  513,  769,   1025,  1537, 2049, 3073,
                         4097, 6145, 8193, 12289, 16385, 24577};
const short DEXT[30] = {0, 0, 0, 0, 1, 1, 2, 2,  3,  3,  4,  4,  5,  5,  6,
                        6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

// Inflate `in` into `out` (pre-sized to the expected length). Distances that
// reach before the start of the output produce zeros rather than an error.
// Returns the number of bytes produced, or -1 on a hard failure.
long inflate_tolerant(const uint8_t* in,
                      size_t in_len,
                      std::vector<uint8_t>& out) {
  size_t off = 0;
  if (in_len >= 2 && (in[0] & 0x0f) == 8 && ((in[0] << 8 | in[1]) % 31) == 0)
    off = 2;  // skip the 2-byte zlib header when present
  BitReader br{in + off, in + in_len};
  size_t outcnt = 0;
  auto put = [&](int v) {
    if (outcnt < out.size())
      out[outcnt] = (uint8_t)v;
    outcnt++;
  };

  Huff fixed_l, fixed_d;
  {
    uint8_t l[288];
    for (int i = 0; i < 144; i++)
      l[i] = 8;
    for (int i = 144; i < 256; i++)
      l[i] = 9;
    for (int i = 256; i < 280; i++)
      l[i] = 7;
    for (int i = 280; i < 288; i++)
      l[i] = 8;
    huff_build(fixed_l, l, 288);
    uint8_t d[30];
    for (int i = 0; i < 30; i++)
      d[i] = 5;
    huff_build(fixed_d, d, 30);
  }

  for (;;) {
    int last = br.bit();
    int type = br.bits(2);
    if (br.fail)
      return -1;
    if (type == 0) {  // stored
      br.buf = 0;
      br.cnt = 0;  // align to byte boundary
      if (br.p + 4 > br.end)
        return -1;
      int len = br.p[0] | (br.p[1] << 8);
      br.p += 4;  // LEN + NLEN
      for (int i = 0; i < len; i++) {
        if (br.p >= br.end)
          return -1;
        put(*br.p++);
      }
    } else if (type == 1 || type == 2) {  // fixed or dynamic Huffman
      Huff dyn_l, dyn_d;
      const Huff* lc;
      const Huff* dc;
      if (type == 1) {
        lc = &fixed_l;
        dc = &fixed_d;
      } else {
        int hlit = br.bits(5) + 257;
        int hdist = br.bits(5) + 1;
        int hclen = br.bits(4) + 4;
        static const int ord[19] = {16, 17, 18, 0, 8,  7, 9,  6, 10, 5,
                                    11, 4,  12, 3, 13, 2, 14, 1, 15};
        uint8_t cl[19] = {0};
        for (int i = 0; i < hclen; i++)
          cl[ord[i]] = (uint8_t)br.bits(3);
        Huff clh;
        huff_build(clh, cl, 19);
        uint8_t lens[288 + 32] = {0};
        int n = 0;
        while (n < hlit + hdist) {
          int sym = huff_decode(br, clh);
          if (sym < 0)
            return -1;
          if (sym < 16) {
            lens[n++] = (uint8_t)sym;
          } else if (sym == 16) {
            if (n == 0)
              return -1;
            int r = br.bits(2) + 3;
            uint8_t prev = lens[n - 1];
            while (r-- && n < hlit + hdist)
              lens[n++] = prev;
          } else if (sym == 17) {
            int r = br.bits(3) + 3;
            while (r-- && n < hlit + hdist)
              lens[n++] = 0;
          } else {
            int r = br.bits(7) + 11;
            while (r-- && n < hlit + hdist)
              lens[n++] = 0;
          }
        }
        huff_build(dyn_l, lens, hlit);
        huff_build(dyn_d, lens + hlit, hdist);
        lc = &dyn_l;
        dc = &dyn_d;
      }
      for (;;) {
        int sym = huff_decode(br, *lc);
        if (sym < 0)
          return -1;
        if (sym == 256)
          break;
        if (sym < 256) {
          put(sym);
        } else {
          sym -= 257;
          if (sym >= 29)
            return -1;
          int len = LBASE[sym] + br.bits(LEXT[sym]);
          int dsym = huff_decode(br, *dc);
          if (dsym < 0 || dsym >= 30)
            return -1;
          long dist = DBASE[dsym] + br.bits(DEXT[dsym]);
          while (len--) {
            int v = ((long)outcnt < dist) ? 0 : out[outcnt - dist];
            put(v);
          }
        }
        if (br.fail)
          return -1;
      }
    } else {
      return -1;  // reserved block type
    }
    if (last)
      break;
  }
  return (long)outcnt;
}

int paeth(int a, int b, int c) {
  int p = a + b - c, pa = std::abs(p - a), pb = std::abs(p - b),
      pc = std::abs(p - c);
  return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
}

uint32_t be32(const uint8_t* p) {
  return ((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3];
}

// Reverse the per-scanline filters of `h` rows of `rowbytes` (each preceded by
// its filter byte in `filt`) into `raw`. An unknown filter type reads as none.
void unfilter(const uint8_t* filt,
              size_t rowbytes,
              int bpp,
              int h,
              std::vector<uint8_t>& raw) {
  raw.assign((size_t)rowbytes * h, 0);
  std::vector<uint8_t> prev(rowbytes, 0);
  for (int r = 0; r < h; r++) {
    const uint8_t* srow = &filt[(rowbytes + 1) * (size_t)r];
    const int ft = srow[0];
    uint8_t* cur = &raw[(size_t)rowbytes * r];
    for (size_t x = 0; x < rowbytes; x++) {
      const int a = (x >= (size_t)bpp) ? cur[x - bpp] : 0;
      const int b = prev[x];
      const int cc = (x >= (size_t)bpp) ? prev[x - bpp] : 0;
      int v = srow[1 + x];
      switch (ft) {
        case 1:
          v += a;
          break;
        case 2:
          v += b;
          break;
        case 3:
          v += (a + b) >> 1;
          break;
        case 4:
          v += paeth(a, b, cc);
          break;
        default:
          break;
      }
      cur[x] = (uint8_t)v;
    }
    std::memcpy(prev.data(), cur, rowbytes);
  }
}

}  // namespace png_tol

// A palette image decoded to indices rather than colours (INDEXED_BITMAP).
struct IndexedImage {
  int w = 0, h = 0;
  std::vector<uint8_t> idx;
  // 256 B, G, R, A entries: the colours the direct decode gives each index.
  std::vector<uint8_t> pal = std::vector<uint8_t>(256 * 4, 0);
  // Bytes per pixel of what that direct decode would have produced: 4 for
  // ARGB8888, 3 for RGB888.
  int direct_bpp = 4;
};

// A colour type 3 PNG kept as indices. Exactness rests on accepting only what
// the usual chain decodes, to the same colours and channel count: stb_image,
// or the tolerant fallback where stb rejects only the pixel data. Anything
// else -- a chunk layout stb refuses, an index past the end of the palette --
// answers false, and the caller's usual chain decodes it as before.
static bool load_png_indexed(const uint8_t* d,
                             size_t sz,
                             bool trans,
                             IndexedImage& out) {
  static const uint8_t sig[8] = {0x89, 0x50, 0x4e, 0x47,
                                 0x0d, 0x0a, 0x1a, 0x0a};
  if (sz < 8 || std::memcmp(d, sig, 8) != 0)
    return false;
  int w = 0, h = 0, depth = 0;
  const uint8_t *plte = nullptr, *trns = nullptr;
  size_t plte_len = 0, trns_len = 0;
  bool iend = false;
  std::vector<uint8_t> idat;
  for (size_t i = 8; i + 12 <= sz;) {
    const uint32_t len = png_tol::be32(d + i);
    const uint8_t* typ = d + i + 4;
    const uint8_t* body = d + i + 8;
    if (len > sz - i - 12)
      return false;
    if (i == 8) {
      if (std::memcmp(typ, "IHDR", 4) != 0 || len != 13)
        return false;
      w = (int)png_tol::be32(body);
      h = (int)png_tol::be32(body + 4);
      depth = body[8];
      if (body[9] != 3 || body[10] != 0 || body[11] != 0 || body[12] != 0)
        return false;
      if (depth != 1 && depth != 2 && depth != 4 && depth != 8)
        return false;
      if (w <= 0 || h <= 0 || w > (1 << 24) || h > (1 << 24) ||
          (1 << 30) / w / 4 < h)
        return false;
    } else if (!std::memcmp(typ, "PLTE", 4)) {
      if (plte || !idat.empty() || len == 0 || len > 768 || len % 3 != 0)
        return false;
      plte = body;
      plte_len = len / 3;
    } else if (!std::memcmp(typ, "tRNS", 4)) {
      if (trns || !plte || !idat.empty() || len > plte_len)
        return false;
      trns = body;
      trns_len = len;
    } else if (!std::memcmp(typ, "IDAT", 4)) {
      if (!plte)
        return false;
      idat.insert(idat.end(), body, body + len);
    } else if (!std::memcmp(typ, "IEND", 4)) {
      iend = true;
      break;
    } else if (!(typ[0] & 0x20) || !std::memcmp(typ, "CgBI", 4)) {
      return false;  // a critical chunk stb does not know
    }
    i += 12 + len;
  }
  if (!iend || idat.empty())
    return false;

  const size_t rowbytes = ((size_t)w * depth + 7) / 8;
  const size_t need = (rowbytes + 1) * (size_t)h;
  int got = 0;
  std::unique_ptr<char, void (*)(void*)> z(
      stbi_zlib_decode_malloc_guesssize_headerflag(
          reinterpret_cast<const char*>(idat.data()), (int)idat.size(),
          (int)need, &got, 1),
      stbi_image_free);
  bool by_stb = z && (size_t)got >= need;
  for (int r = 0; by_stb && r < h; ++r)
    by_stb = (uint8_t)z.get()[(rowbytes + 1) * (size_t)r] <= 4;
  // Where stb gives up on the pixel data, the tolerant fallback decodes it,
  // always to ARGB8888 (see load_png_tolerant_mem).
  std::vector<uint8_t> tol;
  if (!by_stb) {
    z.reset();
    tol.assign(need, 0);
    if (png_tol::inflate_tolerant(idat.data(), idat.size(), tol) < (long)need)
      return false;
  }
  const uint8_t* filt =
      by_stb ? reinterpret_cast<const uint8_t*>(z.get()) : tol.data();
  std::vector<uint8_t> raw;
  png_tol::unfilter(filt, rowbytes, 1, h, raw);
  z.reset();
  std::vector<uint8_t>().swap(tol);

  out.w = w;
  out.h = h;
  out.idx.resize((size_t)w * h);
  const int per = 8 / depth;
  const int mask = (1 << depth) - 1;
  for (int y = 0; y < h; ++y) {
    const uint8_t* row = &raw[rowbytes * (size_t)y];
    uint8_t* o = &out.idx[(size_t)w * y];
    for (int x = 0; x < w; ++x) {
      const int v =
          depth == 8 ? row[x]
                     : (row[x / per] >> ((per - 1 - x % per) * depth)) & mask;
      if ((size_t)v >= plte_len)
        return false;
      o[x] = (uint8_t)v;
    }
  }
  // stb's palette alpha: opaque, index 0 cleared for a colour-keyed load, then
  // tRNS over the top; and its channel count (see bmp_decode_into's `req`).
  const bool alpha = trans || trns;
  for (size_t k = 0; k < plte_len; ++k) {
    uint8_t* e = &out.pal[k * 4];
    e[0] = plte[k * 3 + 2];
    e[1] = plte[k * 3 + 1];
    e[2] = plte[k * 3 + 0];
    e[3] = k < trns_len ? trns[k] : (trans && k == 0) ? 0 : 255;
  }
  out.direct_bpp = (alpha || !by_stb) ? 4 : 3;
  return true;
}

// An XYZ image kept as indices, coloured exactly as load_xyz_mem expands it.
static bool load_xyz_indexed(const uint8_t* d,
                             size_t sz,
                             const char* label,
                             bool trans,
                             IndexedImage& out) {
  int w = 0, h = 0;
  std::unique_ptr<char, void (*)(void*)> raw(xyz_inflate(d, sz, label, &w, &h),
                                             stbi_image_free);
  if (!raw)
    return false;
  const uint8_t* pal = reinterpret_cast<const uint8_t*>(raw.get());
  out.w = w;
  out.h = h;
  out.idx.assign(pal + 768, pal + 768 + (size_t)w * h);
  for (int k = 0; k < 256; ++k) {
    uint8_t* e = &out.pal[k * 4];
    e[0] = pal[k * 3 + 2];
    e[1] = pal[k * 3 + 1];
    e[2] = pal[k * 3 + 0];
    e[3] = (trans && k == 0) ? 0 : 255;
  }
  out.direct_bpp = 4;
  return true;
}

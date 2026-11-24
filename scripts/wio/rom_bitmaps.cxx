// Host half of scripts/wio/game_rom.rb's ROM bitmaps: decodes each image
// named on stdin (one path per line) with the runtime's own indexed decoders
// (include/rgss_indexed_decode.hxx) and writes, per image, to stdout:
//   u8 0                       not a palette image the runtime keeps indexed
//   u8 1, u32 w, u32 h, u8 bpp without / with the colour key,
//   1024-byte palette without / with it, w*h indices
// All little-endian. A file that cannot be read is an error (exit 1).

#define STBI_NO_GIF
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_HDR
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

#include <cstdarg>
#include <cstdio>
#include <iostream>
#include <string>

#include "rgss_indexed_decode.hxx"

static void set_bitmap_load_error(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::vfprintf(stderr, fmt, ap);
  va_end(ap);
  std::fputc('\n', stderr);
}

static void put_u32(uint32_t v) {
  for (int i = 0; i < 4; ++i)
    std::putchar((v >> (8 * i)) & 0xff);
}

int main() {
  std::string path;
  while (std::getline(std::cin, path)) {
    std::FILE* fp = std::fopen(path.c_str(), "rb");
    if (!fp) {
      std::fprintf(stderr, "rom_bitmaps: cannot open %s\n", path.c_str());
      return 1;
    }
    std::vector<uint8_t> d;
    uint8_t buf[65536];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof(buf), fp)) > 0)
      d.insert(d.end(), buf, buf + n);
    const bool bad = std::ferror(fp);
    std::fclose(fp);
    if (bad) {
      std::fprintf(stderr, "rom_bitmaps: cannot read %s\n", path.c_str());
      return 1;
    }
    IndexedImage ix[2];
    bool ok = true;
    for (int t = 0; t < 2 && ok; ++t)
      ok = load_png_indexed(d.data(), d.size(), t, ix[t]) ||
           load_xyz_indexed(d.data(), d.size(), path.c_str(), t, ix[t]);
    // The colour key only touches the palette; anything else is a decoder
    // this packer does not understand, so leave the file to the runtime.
    ok = ok && ix[0].w == ix[1].w && ix[0].h == ix[1].h &&
         ix[0].idx == ix[1].idx;
    if (!ok) {
      std::putchar(0);
      continue;
    }
    std::putchar(1);
    put_u32(ix[0].w);
    put_u32(ix[0].h);
    std::putchar(ix[0].direct_bpp);
    std::putchar(ix[1].direct_bpp);
    std::fwrite(ix[0].pal.data(), 1, ix[0].pal.size(), stdout);
    std::fwrite(ix[1].pal.data(), 1, ix[1].pal.size(), stdout);
    std::fwrite(ix[0].idx.data(), 1, ix[0].idx.size(), stdout);
  }
  return std::fflush(stdout) == 0 ? 0 : 1;
}

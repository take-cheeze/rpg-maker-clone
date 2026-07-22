#include "iterm.hxx"

#include <cstdint>
#include <string>
#include <vector>

#include "terminal.hxx"

// stb_image_write brings its own deflate implementation, so PNG encoding needs
// no external zlib.  STBI_WRITE_NO_STDIO drops the FILE*-based helpers (we only
// use the in-memory *_to_func API), and the implementation lives in this one
// translation unit.
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <stb_image_write.h>

namespace {

// Reused across frames to avoid per-frame allocation churn.
std::vector<uint8_t> g_rgb;  // RGB888, upscaled frame fed to the PNG encoder
std::string g_png;           // encoded PNG bytes
std::string g_b64;           // base64 of g_png
std::string g_out;           // full OSC 1337 sequence written to the terminal

// Standard base64 alphabet; iTerm2 expects the image payload base64-encoded.
void base64_append(std::string& out, const std::string& in) {
  static const char tbl[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const size_t n = in.size();
  out.reserve(out.size() + ((n + 2) / 3) * 4);
  size_t i = 0;
  for (; i + 3 <= n; i += 3) {
    const uint32_t v = static_cast<uint8_t>(in[i]) << 16 |
                       static_cast<uint8_t>(in[i + 1]) << 8 |
                       static_cast<uint8_t>(in[i + 2]);
    out += tbl[(v >> 18) & 63];
    out += tbl[(v >> 12) & 63];
    out += tbl[(v >> 6) & 63];
    out += tbl[v & 63];
  }
  if (n - i == 1) {
    const uint32_t v = static_cast<uint8_t>(in[i]) << 16;
    out += tbl[(v >> 18) & 63];
    out += tbl[(v >> 12) & 63];
    out += '=';
    out += '=';
  } else if (n - i == 2) {
    const uint32_t v = static_cast<uint8_t>(in[i]) << 16 |
                       static_cast<uint8_t>(in[i + 1]) << 8;
    out += tbl[(v >> 18) & 63];
    out += tbl[(v >> 12) & 63];
    out += tbl[(v >> 6) & 63];
    out += '=';
  }
}

// stbi_write_png_to_func sink: append the encoded bytes to a std::string.
void png_sink(void* ctx, void* data, int size) {
  auto* s = static_cast<std::string*>(ctx);
  s->append(static_cast<const char*>(data), static_cast<size_t>(size));
}

void iterm_encode_frame(int w, int h, int scale, const uint16_t* pix) {
  const int out_w = w * scale;
  const int out_h = h * scale;

  // Expand RGB565 to RGB888, upscaling by nearest-neighbour, into g_rgb.
  g_rgb.resize(static_cast<size_t>(out_w) * out_h * 3);
  for (int oy = 0; oy < out_h; ++oy) {
    const uint16_t* row = pix + (oy / scale) * w;
    uint8_t* dst = g_rgb.data() + static_cast<size_t>(oy) * out_w * 3;
    for (int ox = 0; ox < out_w; ++ox) {
      const uint16_t p = row[ox / scale];
      *dst++ = static_cast<uint8_t>(((p >> 11) & 0x1f) << 3);  // R
      *dst++ = static_cast<uint8_t>(((p >> 5) & 0x3f) << 2);   // G
      *dst++ = static_cast<uint8_t>((p & 0x1f) << 3);          // B
    }
  }

  g_png.clear();
  stbi_write_png_to_func(png_sink, &g_png, out_w, out_h, 3, g_rgb.data(),
                         out_w * 3);

  g_b64.clear();
  base64_append(g_b64, g_png);

  // iTerm2 inline-image protocol: OSC 1337 ; File = <args> : <base64> BEL.
  // `size` lets the terminal show a progress indicator; width/height in px pin
  // the on-screen size to the encoded resolution; preserveAspectRatio=0 avoids
  // extra letterboxing since the two already match.  A leading cursor-home lets
  // each frame overdraw the previous one in place.
  std::string& s = g_out;
  s.clear();
  s += "\x1b[H";
  s += "\x1b]1337;File=inline=1;size=";
  s += std::to_string(g_png.size());
  s += ";width=";
  s += std::to_string(out_w);
  s += "px;height=";
  s += std::to_string(out_h);
  s += "px;preserveAspectRatio=0:";
  s += g_b64;
  s += "\x07";  // BEL terminates the OSC sequence
  terminal_write(s.data(), s.size());
}

}  // namespace

lv_display_t* iterm_display_create(int32_t hor_res,
                                   int32_t ver_res,
                                   int scale) {
  // Trade a little PNG size for encode speed: this runs once per frame on the
  // game loop, so favour latency over the last few percent of compression.
  stbi_write_png_compression_level = 6;
  return terminal_display_create(hor_res, ver_res, scale, iterm_encode_frame);
}

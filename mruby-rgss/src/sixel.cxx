#include "sixel.hxx"

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "terminal.hxx"

namespace {

// Reused across frames to avoid per-frame allocation churn.
std::string g_out;
std::vector<uint8_t> g_oidx;
std::string g_line;

// ---------------------------------------------------------------------------
// Sixel encoding
// ---------------------------------------------------------------------------
// Fixed 6x6x6 colour cube (216 registers).  Direct quantisation keeps encoding
// O(pixels) with no palette search, which is important for interactive frame
// rates.
inline int quant6(int v) {
  const int q = (v * 6) / 256;
  return q > 5 ? 5 : q;
}

const std::string& palette_definition() {
  static const std::string def = [] {
    std::string s;
    for (int i = 0; i < 216; ++i) {
      const int r = ((i / 36) % 6) * 255 / 5;
      const int g = ((i / 6) % 6) * 255 / 5;
      const int b = (i % 6) * 255 / 5;
      s += '#';
      s += std::to_string(i);
      s += ";2;";
      s += std::to_string(r * 100 / 255);
      s += ';';
      s += std::to_string(g * 100 / 255);
      s += ';';
      s += std::to_string(b * 100 / 255);
    }
    return s;
  }();
  return def;
}

// Run-length-encode a line of sixel bytes onto `s`, trimming trailing empties.
void emit_rle(std::string& s, const std::string& line) {
  size_t n = line.size();
  while (n > 0 && line[n - 1] == '?')  // trailing background needs no output
    --n;
  size_t i = 0;
  while (i < n) {
    const char c = line[i];
    size_t j = i + 1;
    while (j < n && line[j] == c)
      ++j;
    const size_t run = j - i;
    if (run >= 4) {
      s += '!';
      s += std::to_string(run);
      s += c;
    } else {
      s.append(run, c);
    }
    i = j;
  }
}

void sixel_encode_frame(int w, int h, int scale, const uint16_t* pix) {
  const int out_w = w * scale;
  const int out_h = h * scale;

  // Quantise (and upscale) the whole frame once into a palette-index buffer.
  g_oidx.resize(static_cast<size_t>(out_w) * out_h);
  for (int oy = 0; oy < out_h; ++oy) {
    const uint16_t* row = pix + (oy / scale) * w;
    uint8_t* dst = g_oidx.data() + static_cast<size_t>(oy) * out_w;
    for (int ox = 0; ox < out_w; ++ox) {
      const uint16_t p = row[ox / scale];
      // RGB565 -> 8 bit per channel.
      const int r = ((p >> 11) & 0x1f) << 3;
      const int g = ((p >> 5) & 0x3f) << 2;
      const int b = (p & 0x1f) << 3;
      dst[ox] =
          static_cast<uint8_t>(quant6(r) * 36 + quant6(g) * 6 + quant6(b));
    }
  }

  std::string& s = g_out;
  s.clear();
  s += "\x1b[H";  // cursor home: overdraw the previous frame in place
  terminal_append_legend(s);  // one-line key reference pinned above the image
  terminal_append_stats(s);   // emit-rate report row (no-op if --noterm_stats)
  s += "\x1bPq";              // enter sixel mode
  s += "\"1;1;";              // raster attributes: 1:1 aspect ratio
  s += std::to_string(out_w);
  s += ';';
  s += std::to_string(out_h);
  s += palette_definition();

  bool used[216];
  int used_list[216];
  for (int by = 0; by < out_h; by += 6) {
    const int bh = (out_h - by < 6) ? (out_h - by) : 6;

    // Collect the colours present in this 6-row band.
    std::memset(used, 0, sizeof(used));
    int used_count = 0;
    for (int r = 0; r < bh; ++r) {
      const uint8_t* rowp = g_oidx.data() + static_cast<size_t>(by + r) * out_w;
      for (int ox = 0; ox < out_w; ++ox) {
        const uint8_t c = rowp[ox];
        if (!used[c]) {
          used[c] = true;
          used_list[used_count++] = c;
        }
      }
    }

    for (int u = 0; u < used_count; ++u) {
      const int c = used_list[u];
      s += '#';
      s += std::to_string(c);
      g_line.assign(out_w, 0);  // raw 6-bit accumulators (one bit per row)
      for (int r = 0; r < bh; ++r) {
        const uint8_t* rowp =
            g_oidx.data() + static_cast<size_t>(by + r) * out_w;
        const char bit = static_cast<char>(1 << r);
        for (int ox = 0; ox < out_w; ++ox)
          if (rowp[ox] == c)
            g_line[ox] = static_cast<char>(g_line[ox] | bit);
      }
      // A sixel data byte is 0x3F ('?') plus the 6-bit column value.
      for (char& ch : g_line)
        ch = static_cast<char>('?' + ch);
      emit_rle(s, g_line);
      s += (u + 1 < used_count) ? '$' : '-';  // overlay next colour / new band
    }
    if (used_count == 0)
      s += '-';
  }

  s += "\x1b\\";  // exit sixel mode
  terminal_write(s.data(), s.size());
}

}  // namespace

lv_display_t* sixel_display_create(int32_t hor_res,
                                   int32_t ver_res,
                                   int scale) {
  return terminal_display_create(hor_res, ver_res, scale, sixel_encode_frame);
}

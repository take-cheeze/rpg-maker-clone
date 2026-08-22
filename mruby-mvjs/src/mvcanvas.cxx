// The Canvas2D -> RGBA-buffer bridge for RPG Maker MV support (milestone M4).
//
// MV renders through PIXI.js. Its WebGL renderer needs a real GL context, so we
// return null for 'webgl' (see the canvas getContext shim) and PIXI falls back
// to its Canvas2D renderer, which draws through a CanvasRenderingContext2D.
// This file backs those canvases with plain RGBA8 buffers and implements the
// subset of the 2D API PIXI's canvas path and MV's Bitmap use.
//
// Keeping the canvas a self-contained byte buffer (rather than an
// mruby-rgss::Bitmap) makes the drawing primitives independent of the display
// and unit-testable by reading pixels back. Presenting the main canvas
// on-screen (copying it into a Sprite's Bitmap each frame) is a separate, thin
// step handled with the game loop.

#include "mvhost.hxx"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// stb_image is compiled (STB_IMAGE_IMPLEMENTATION) by mruby-rgss (lib.cxx), so
// we include only the declarations here and the decode symbols resolve at link.
#include <stb_image.h>

// stb_truetype backs text drawing (fillText/strokeText/measureText). Its
// implementation is compiled once in mruby-rgss (src/lib.cxx), which this gem
// depends on, so here we only need the header — the glyph symbols resolve at
// link. Defining STB_TRUETYPE_IMPLEMENTATION here too would duplicate them.
#include <cstdio>

#include <dirent.h>
#include <stb_truetype.h>

// The engine's fallback font, for projects that ship none (also mruby-rgss).
#include "default_font.hxx"
// log_bridge_write_stderr (mruby-rgss/src/log_bridge.cxx), so the font-load
// warnings below also reach ng-log; see include/terminal.hxx.
#include "terminal.hxx"

namespace {

// The game font, loaded once on first text draw. MV renders all window/menu
// text through the Canvas2D context's fillText using the project's bundled
// TrueType font (the CSS `GameFont`, typically fonts/mplus-1m-regular.ttf). We
// find the first .ttf/.otf under the game's fonts/ dir and rasterise glyphs
// with stb_truetype. Loading is lazy and cached; if no font is found, text
// draws no-op and measureText falls back to a rough advance estimate.
struct GameFont {
  bool tried = false;
  bool ok = false;
  std::vector<uint8_t> data;
  stbtt_fontinfo info{};
};

// Lowercased extension of `name`, including the dot ("" if it has none).
std::string lower_ext(const std::string& name) {
  const size_t dot = name.rfind('.');
  if (dot == std::string::npos)
    return std::string();
  std::string ext = name.substr(dot);
  for (char& ch : ext)
    ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  return ext;
}

// Find the game's font. A bare sfnt (.ttf/.otf) is preferred because it needs
// no unpacking, but .woff is accepted too and is what actually matters in
// practice:
// **RPG Maker MZ projects ship `fonts/*.woff`** (mplus-1m-regular.woff and
// friends), so a loader that only looked for .ttf/.otf found nothing and every
// MZ game drew blank windows.
//
// A project that ships no font at all (the MZ sample, and anything whose
// deployment left the RTP font behind) falls back to the engine's default font
// — every glyph MV draws goes through here, so without one its whole UI is
// blank rather than merely wrong-looking. Returns "" only when that is missing
// too.
std::string font_dir_first_font() {
  const std::string dir = mv_resolve_path("fonts");
  DIR* d = opendir(dir.c_str());
  if (!d)
    return rgss::default_font_path();
  std::string sfnt, woff;
  while (dirent* e = readdir(d)) {
    const std::string ext = lower_ext(e->d_name);
    if (sfnt.empty() && (ext == ".ttf" || ext == ".otf"))
      sfnt = dir + "/" + e->d_name;
    else if (woff.empty() && ext == ".woff")
      woff = dir + "/" + e->d_name;
  }
  closedir(d);
  if (!sfnt.empty())
    return sfnt;
  if (!woff.empty())
    return woff;
  // Nothing usable in the project's own fonts/ — fall back to the engine's
  // default font (assets/fonts), so the windows still draw.
  return rgss::default_font_path();
}

// Big-endian readers over a byte buffer, bounds-checked by the caller.
uint32_t be32(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) |
         (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | static_cast<uint32_t>(p[3]);
}
uint16_t be16(const uint8_t* p) {
  return static_cast<uint16_t>((p[0] << 8) | p[1]);
}
void put32(std::vector<uint8_t>& v, size_t at, uint32_t x) {
  v[at] = static_cast<uint8_t>(x >> 24);
  v[at + 1] = static_cast<uint8_t>(x >> 16);
  v[at + 2] = static_cast<uint8_t>(x >> 8);
  v[at + 3] = static_cast<uint8_t>(x);
}
void put16(std::vector<uint8_t>& v, size_t at, uint16_t x) {
  v[at] = static_cast<uint8_t>(x >> 8);
  v[at + 1] = static_cast<uint8_t>(x);
}

// Unpack a WOFF 1.0 file into the bare sfnt (TrueType/OpenType) font it wraps,
// which is what stb_truetype can parse. WOFF is just a table-by-table
// container: a 44-byte header, a directory of (tag, offset, compLength,
// origLength, checksum) entries, and each table stored either raw or
// zlib-compressed — exactly the zlib stb_image already implements, so no new
// dependency.
//
// The rebuilt sfnt needs its own 12-byte header and 16-byte-per-table
// directory, with tables 4-byte aligned. Table *checksums* are copied from the
// WOFF directory rather than recomputed; stb_truetype does not verify them.
//
// WOFF2 (signature "wOF2") is a different format — Brotli, plus a transformed
// glyf table — and is deliberately not handled; it is reported instead of being
// half-parsed into garbage.
bool woff_to_sfnt(const std::vector<uint8_t>& in, std::vector<uint8_t>& out) {
  if (in.size() < 44)
    return false;
  if (std::memcmp(in.data(), "wOFF", 4) != 0)
    return false;

  const uint32_t flavor = be32(in.data() + 4);
  const uint16_t num_tables = be16(in.data() + 12);
  if (num_tables == 0 || in.size() < 44 + static_cast<size_t>(num_tables) * 20)
    return false;

  struct Entry {
    uint32_t tag, offset, comp_len, orig_len, checksum;
  };
  std::vector<Entry> tables(num_tables);
  size_t total = 12 + static_cast<size_t>(num_tables) * 16;
  for (uint16_t i = 0; i < num_tables; ++i) {
    const uint8_t* p = in.data() + 44 + static_cast<size_t>(i) * 20;
    tables[i] = {be32(p), be32(p + 4), be32(p + 8), be32(p + 12), be32(p + 16)};
    const Entry& t = tables[i];
    // Every table must lie inside the file, and a stored table's lengths match.
    if (t.comp_len > in.size() || t.offset > in.size() - t.comp_len)
      return false;
    if (t.comp_len > t.orig_len)
      return false;
    total += (t.orig_len + 3) & ~3u;  // 4-byte aligned
  }

  out.assign(total, 0);
  // sfnt header: version, numTables, and the binary-search fields (derived, and
  // unused by stb_truetype, but written correctly so the result is a valid
  // font).
  uint16_t entry_selector = 0;
  while ((1u << (entry_selector + 1)) <= num_tables)
    ++entry_selector;
  const uint16_t search_range =
      static_cast<uint16_t>((1u << entry_selector) * 16);
  put32(out, 0, flavor);
  put16(out, 4, num_tables);
  put16(out, 6, search_range);
  put16(out, 8, entry_selector);
  put16(out, 10, static_cast<uint16_t>(num_tables * 16 - search_range));

  size_t dst = 12 + static_cast<size_t>(num_tables) * 16;
  for (uint16_t i = 0; i < num_tables; ++i) {
    const Entry& t = tables[i];
    const size_t dir = 12 + static_cast<size_t>(i) * 16;
    put32(out, dir, t.tag);
    put32(out, dir + 4, t.checksum);
    put32(out, dir + 8, static_cast<uint32_t>(dst));
    put32(out, dir + 12, t.orig_len);

    if (dst + t.orig_len > out.size())
      return false;
    const char* src = reinterpret_cast<const char*>(in.data() + t.offset);
    if (t.comp_len == t.orig_len) {
      std::memcpy(out.data() + dst, src, t.orig_len);  // stored, not deflated
    } else {
      const int n = stbi_zlib_decode_buffer(
          reinterpret_cast<char*>(out.data() + dst),
          static_cast<int>(t.orig_len), src, static_cast<int>(t.comp_len));
      if (n != static_cast<int>(t.orig_len))
        return false;
    }
    dst += (t.orig_len + 3) & ~3u;
  }
  return true;
}

GameFont& game_font() {
  static GameFont f;
  if (f.tried)
    return f;
  f.tried = true;
  const std::string path = font_dir_first_font();
  if (path.empty())
    return f;
  std::FILE* fp = std::fopen(path.c_str(), "rb");
  if (!fp)
    return f;
  std::fseek(fp, 0, SEEK_END);
  long sz = std::ftell(fp);
  std::fseek(fp, 0, SEEK_SET);
  if (sz > 0) {
    f.data.resize(static_cast<size_t>(sz));
    if (std::fread(f.data.data(), 1, static_cast<size_t>(sz), fp) ==
        static_cast<size_t>(sz)) {
      // A WOFF wrapper is unpacked to the sfnt inside it first; anything else
      // is handed to stb_truetype as-is. Report a failure rather than silently
      // drawing no text — blank windows with no explanation is exactly how the
      // missing .woff support hid for so long.
      if (f.data.size() >= 4 && std::memcmp(f.data.data(), "wOF2", 4) == 0) {
        log_bridge_write_stderr(
            ("[MV] font " + path +
             " is WOFF2, which is not supported (it needs Brotli and a "
             "transformed glyf table); text will not draw. Ship a .ttf/.otf "
             "or WOFF 1.0 instead.")
                .c_str());
        f.data.clear();
      } else if (f.data.size() >= 4 &&
                 std::memcmp(f.data.data(), "wOFF", 4) == 0) {
        std::vector<uint8_t> sfnt;
        if (woff_to_sfnt(f.data, sfnt)) {
          f.data.swap(sfnt);
        } else {
          log_bridge_write_stderr(
              ("[MV] font " + path + ": could not unpack the WOFF").c_str());
          f.data.clear();
        }
      }
      if (!f.data.empty()) {
        const int off = stbtt_GetFontOffsetForIndex(f.data.data(), 0);
        if (off >= 0 && stbtt_InitFont(&f.info, f.data.data(), off))
          f.ok = true;
        else
          log_bridge_write_stderr(
              ("[MV] font " + path + ": stb_truetype rejected it").c_str());
      }
    }
  }
  std::fclose(fp);
  return f;
}

// Decode the next UTF-8 code point from s[i..n), advancing i. Malformed bytes
// are passed through as Latin-1 so ASCII text (the common case) is exact.
uint32_t utf8_next(const unsigned char* s, size_t n, size_t& i) {
  uint32_t c = s[i++];
  if (c < 0x80)
    return c;
  int extra;
  uint32_t cp;
  if ((c & 0xE0) == 0xC0) {
    cp = c & 0x1F;
    extra = 1;
  } else if ((c & 0xF0) == 0xE0) {
    cp = c & 0x0F;
    extra = 2;
  } else if ((c & 0xF8) == 0xF0) {
    cp = c & 0x07;
    extra = 3;
  } else {
    return c;
  }
  for (int k = 0; k < extra && i < n; ++k) {
    const uint32_t cc = s[i];
    if ((cc & 0xC0) != 0x80)
      break;
    cp = (cp << 6) | (cc & 0x3F);
    ++i;
  }
  return cp;
}

// Total advance width of `text` at `pixel` em size, in pixels. `use_game_font`
// is false for a CSS font shorthand that doesn't name "GameFont" (MV's own
// custom-font family, always loaded via Graphics.loadFont as literally
// "GameFont") -- stb_truetype only ever backs that one font, so a generic
// family like plain "sans-serif" gets the same rough per-character estimate
// as an unloaded font, deliberately different from the real metrics below.
// This is what makes Graphics.isFontLoaded's classic detection trick work:
// it measures '40px GameFont, sans-serif' against '40px sans-serif' and
// waits for the two widths to diverge -- with a single font-agnostic
// measurement (the pre-existing behavior) they never would, hanging
// Scene_Boot until its own 20s timeout on any project whose corescript
// doesn't take the newer FontFaceSet-based path (see the document.fonts
// stand-in's own comment, above).
double font_text_width(const std::string& text,
                       double pixel,
                       bool use_game_font = true) {
  GameFont& f = game_font();
  if (!use_game_font || !f.ok)
    return static_cast<double>(text.size()) * pixel * 0.5;
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&f.info, static_cast<float>(pixel));
  const unsigned char* s = reinterpret_cast<const unsigned char*>(text.data());
  double w = 0;
  int prev = 0;
  for (size_t i = 0; i < text.size();) {
    const int cp = static_cast<int>(utf8_next(s, text.size(), i));
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, cp, &adv, &lsb);
    if (prev)
      w += scale * stbtt_GetCodepointKernAdvance(&f.info, prev, cp);
    w += scale * adv;
    prev = cp;
  }
  return w;
}

// An RGBA8 canvas, row-major, straight (non-premultiplied) alpha.
struct Canvas {
  int w = 0;
  int h = 0;
  std::vector<uint8_t> px;

  void resize(int nw, int nh) {
    w = nw < 0 ? 0 : nw;
    h = nh < 0 ? 0 : nh;
    px.assign(static_cast<size_t>(w) * static_cast<size_t>(h) * 4, 0);
  }
};

// Canvases are referenced from JS by an integer handle (index + 1; 0 is the
// null handle). They live for the process for now; disposal lands with the
// bitmap lifetime work.
std::vector<Canvas*> g_canvases;

Canvas* canvas_get(int handle) {
  if (handle < 1 || static_cast<size_t>(handle) > g_canvases.size())
    return nullptr;
  return g_canvases[static_cast<size_t>(handle) - 1];
}

// Source-over alpha blend of (r,g,b,a) onto the RGBA pixel at `d`.
void blend(uint8_t* d, int r, int g, int b, int a) {
  if (a <= 0)
    return;
  if (a >= 255) {
    d[0] = static_cast<uint8_t>(r);
    d[1] = static_cast<uint8_t>(g);
    d[2] = static_cast<uint8_t>(b);
    d[3] = 255;
    return;
  }
  const int ia = 255 - a;
  d[0] = static_cast<uint8_t>((r * a + d[0] * ia) / 255);
  d[1] = static_cast<uint8_t>((g * a + d[1] * ia) / 255);
  d[2] = static_cast<uint8_t>((b * a + d[2] * ia) / 255);
  d[3] = static_cast<uint8_t>((a * 255 + d[3] * ia) / 255);
}

// Additive ("lighter") blend: the source, scaled by its coverage `a`, is added
// to the destination and clamped. This is canvas globalCompositeOperation =
// 'lighter' (PIXI blendMode ADD), which MV uses for battle-animation flashes,
// weather and glow sprites; under plain source-over those effects come out too
// dark.
void blend_add(uint8_t* d, int r, int g, int b, int a) {
  if (a <= 0)
    return;
  d[0] = static_cast<uint8_t>(std::min(255, d[0] + r * a / 255));
  d[1] = static_cast<uint8_t>(std::min(255, d[1] + g * a / 255));
  d[2] = static_cast<uint8_t>(std::min(255, d[2] + b * a / 255));
  d[3] = static_cast<uint8_t>(std::min(255, d[3] + a));
}

// "difference" blend: |dest - source| per channel, mixed in by the source
// coverage `a`. MV uses it (with opaque white / colour fills) to invert the
// frame so a following additive fill subtracts instead of adds -- that is how
// negative screen tones (night, caves, "tint screen" events) darken the map.
// Reachable once the boot feature-probe reports canUseDifferenceBlend, which it
// now does because this makes the probe's white-on-white difference read black.
void blend_difference(uint8_t* d, int r, int g, int b, int a) {
  if (a <= 0)
    return;
  const int ia = 255 - a;
  const int dr = d[0] > r ? d[0] - r : r - d[0];
  const int dg = d[1] > g ? d[1] - g : g - d[1];
  const int db = d[2] > b ? d[2] - b : b - d[2];
  d[0] = static_cast<uint8_t>((dr * a + d[0] * ia) / 255);
  d[1] = static_cast<uint8_t>((dg * a + d[1] * ia) / 255);
  d[2] = static_cast<uint8_t>((db * a + d[2] * ia) / 255);
  d[3] = static_cast<uint8_t>((a * 255 + d[3] * ia) / 255);
}

// "saturation" blend, as MV uses it: a white fill desaturates the backdrop.
// The non-separable saturation mode takes the source's saturation (0 for white)
// with the backdrop's hue and luminosity, so a white source collapses every
// pixel to its own luminosity -- a greyscale that preserves brightness. MV only
// ever fills white here (ToneSprite's grey tone, Sprite grey colour-tone), so
// the source colour is ignored and each channel lerps toward the luminosity by
// the coverage `a`. Reachable once the boot probe reports
// canUseSaturationBlend, which it now does (white-on-black saturation reads
// back black).
void blend_saturation(uint8_t* d, int /*r*/, int /*g*/, int /*b*/, int a) {
  if (a <= 0)
    return;
  // Rec. 601-ish luminosity with 0.30/0.59/0.11 weights scaled to /256.
  const int lum = (77 * d[0] + 151 * d[1] + 28 * d[2]) >> 8;
  d[0] = static_cast<uint8_t>(d[0] + (lum - d[0]) * a / 255);
  d[1] = static_cast<uint8_t>(d[1] + (lum - d[1]) * a / 255);
  d[2] = static_cast<uint8_t>(d[2] + (lum - d[2]) * a / 255);
}

// Dispatch by composite-op mode (0 = source-over, 1 = lighter/additive,
// 2 = difference, 3 = saturation) threaded through from the Ctx.
inline void blend_mode(uint8_t* d, int r, int g, int b, int a, int mode) {
  if (mode == 1)
    blend_add(d, r, g, b, a);
  else if (mode == 2)
    blend_difference(d, r, g, b, a);
  else if (mode == 3)
    blend_saturation(d, r, g, b, a);
  else
    blend(d, r, g, b, a);
}

int ai(JSContext* ctx, int argc, JSValueConst* argv, int i) {
  int32_t v = 0;
  if (i < argc)
    JS_ToInt32(ctx, &v, argv[i]);
  return v;
}

double ad(JSContext* ctx, int argc, JSValueConst* argv, int i, double dflt) {
  double v = dflt;
  if (i < argc)
    JS_ToFloat64(ctx, &v, argv[i]);
  return v;
}

// __mv_canvasCreate(w, h) -> handle
JSValue js_create(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = new Canvas();
  c->resize(ai(ctx, argc, argv, 0), ai(ctx, argc, argv, 1));
  g_canvases.push_back(c);
  return JS_NewInt32(ctx, static_cast<int>(g_canvases.size()));
}

// __mv_canvasResize(handle, w, h)
JSValue js_resize(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (c)
    c->resize(ai(ctx, argc, argv, 1), ai(ctx, argc, argv, 2));
  return JS_UNDEFINED;
}

JSValue js_width(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  return JS_NewInt32(ctx, c ? c->w : 0);
}

JSValue js_height(JSContext* ctx, JSValueConst, int argc, JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  return JS_NewInt32(ctx, c ? c->h : 0);
}

// __mv_canvasFillRect(handle, x, y, w, h, r, g, b, a, mode)
// `mode` (optional, default 0) selects the composite op: 0 = source-over,
// 1 = lighter/additive.
JSValue js_fill_rect(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (!c)
    return JS_UNDEFINED;
  int x = ai(ctx, argc, argv, 1), y = ai(ctx, argc, argv, 2);
  int rw = ai(ctx, argc, argv, 3), rh = ai(ctx, argc, argv, 4);
  const int r = ai(ctx, argc, argv, 5), g = ai(ctx, argc, argv, 6);
  const int b = ai(ctx, argc, argv, 7), a = ai(ctx, argc, argv, 8);
  const int mode = argc > 9 ? ai(ctx, argc, argv, 9) : 0;
  for (int j = 0; j < rh; ++j) {
    const int ty = y + j;
    if (ty < 0 || ty >= c->h)
      continue;
    for (int i = 0; i < rw; ++i) {
      const int tx = x + i;
      if (tx < 0 || tx >= c->w)
        continue;
      blend_mode(&c->px[(static_cast<size_t>(ty) * c->w + tx) * 4], r, g, b, a,
                 mode);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasClearRect(handle, x, y, w, h) -> set the rect to transparent
// black.
JSValue js_clear_rect(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (!c)
    return JS_UNDEFINED;
  int x = ai(ctx, argc, argv, 1), y = ai(ctx, argc, argv, 2);
  int rw = ai(ctx, argc, argv, 3), rh = ai(ctx, argc, argv, 4);
  for (int j = 0; j < rh; ++j) {
    const int ty = y + j;
    if (ty < 0 || ty >= c->h)
      continue;
    for (int i = 0; i < rw; ++i) {
      const int tx = x + i;
      if (tx < 0 || tx >= c->w)
        continue;
      std::memset(&c->px[(static_cast<size_t>(ty) * c->w + tx) * 4], 0, 4);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasDrawImage(dstH, srcH, sx, sy, sw, sh, dx, dy, dw, dh, alpha,
//                      a, b, c, d, e, f, mode)
// Nearest-neighbour blit of a source rect into a dest rect, modulated by a
// global alpha (0-255) and transformed by the current 2D matrix
// [a b c d e f] (device = (a*u+c*v+e, b*u+d*v+f)). This is the workhorse PIXI's
// canvas renderer uses: it positions every sprite via setTransform, so
// honouring the matrix is what makes sprites land where they belong. The matrix
// defaults to identity, in which case this reduces to a plain scaled blit.
// Rasterised by walking the transformed dest rect's device-space bounding box
// and inverse- mapping each pixel back through the matrix and the dest->source
// scale, so rotation/scale/translation all work and there are no gaps.
JSValue js_draw_image(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  Canvas* dst = canvas_get(ai(ctx, argc, argv, 0));
  Canvas* src = canvas_get(ai(ctx, argc, argv, 1));
  if (!dst || !src)
    return JS_UNDEFINED;
  const double sx = ad(ctx, argc, argv, 2, 0), sy = ad(ctx, argc, argv, 3, 0);
  const double sw = ad(ctx, argc, argv, 4, 0), sh = ad(ctx, argc, argv, 5, 0);
  const double dx = ad(ctx, argc, argv, 6, 0), dy = ad(ctx, argc, argv, 7, 0);
  const double dw = ad(ctx, argc, argv, 8, 0), dh = ad(ctx, argc, argv, 9, 0);
  const int ga = argc > 10 ? ai(ctx, argc, argv, 10) : 255;
  const double ma = ad(ctx, argc, argv, 11, 1), mb = ad(ctx, argc, argv, 12, 0);
  const double mc = ad(ctx, argc, argv, 13, 0), md = ad(ctx, argc, argv, 14, 1);
  const double me = ad(ctx, argc, argv, 15, 0), mf = ad(ctx, argc, argv, 16, 0);
  const int mode = argc > 17 ? ai(ctx, argc, argv, 17) : 0;
  if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0)
    return JS_UNDEFINED;
  const double det = ma * md - mb * mc;
  if (det == 0)
    return JS_UNDEFINED;
  const double invdet = 1.0 / det;

  // Device-space bounding box of the four transformed dest-rect corners.
  const double cxs[4] = {dx, dx + dw, dx + dw, dx};
  const double cys[4] = {dy, dy, dy + dh, dy + dh};
  double minx = 1e18, miny = 1e18, maxx = -1e18, maxy = -1e18;
  for (int i = 0; i < 4; ++i) {
    const double X = ma * cxs[i] + mc * cys[i] + me;
    const double Y = mb * cxs[i] + md * cys[i] + mf;
    minx = std::min(minx, X);
    maxx = std::max(maxx, X);
    miny = std::min(miny, Y);
    maxy = std::max(maxy, Y);
  }
  int x0 = static_cast<int>(std::floor(minx));
  int y0 = static_cast<int>(std::floor(miny));
  int x1 = static_cast<int>(std::ceil(maxx));
  int y1 = static_cast<int>(std::ceil(maxy));
  x0 = std::max(x0, 0);
  y0 = std::max(y0, 0);
  x1 = std::min(x1, dst->w);
  y1 = std::min(y1, dst->h);

  for (int py = y0; py < y1; ++py) {
    for (int px = x0; px < x1; ++px) {
      // Inverse-transform the device pixel back to user space.
      const double rx = px - me, ry = py - mf;
      const double u = (md * rx - mc * ry) * invdet;
      const double v = (-mb * rx + ma * ry) * invdet;
      if (u < dx || u >= dx + dw || v < dy || v >= dy + dh)
        continue;
      const int sxx = static_cast<int>(sx + (u - dx) * sw / dw);
      const int syy = static_cast<int>(sy + (v - dy) * sh / dh);
      if (sxx < 0 || sxx >= src->w || syy < 0 || syy >= src->h)
        continue;
      const uint8_t* sp =
          &src->px[(static_cast<size_t>(syy) * src->w + sxx) * 4];
      const int a = sp[3] * ga / 255;
      blend_mode(&dst->px[(static_cast<size_t>(py) * dst->w + px) * 4], sp[0],
                 sp[1], sp[2], a, mode);
    }
  }
  return JS_UNDEFINED;
}

// __mv_fontMeasure(pixelSize, text, hasGameFont) -> advance width in pixels.
// Backs CanvasRenderingContext2D.measureText, which MV's
// Bitmap.measureTextWidth uses to align (centre/right) and lay out text, so it
// must reflect the real font -- except when the caller's own font shorthand
// doesn't name "GameFont" at all (see font_text_width's own comment), where a
// different, rougher estimate is deliberate.
JSValue js_measure_text(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  const double pixel = ad(ctx, argc, argv, 0, 10);
  const char* text = argc > 1 ? JS_ToCString(ctx, argv[1]) : nullptr;
  const bool has_game_font = argc > 2 ? ai(ctx, argc, argv, 2) != 0 : true;
  const double w = text ? font_text_width(text, pixel, has_game_font) : 0.0;
  if (text)
    JS_FreeCString(ctx, text);
  return JS_NewFloat64(ctx, w);
}

// Blit a glyph coverage bitmap (8-bit alpha, `gw`x`gh`) at device (dx,dy) in
// solid colour (r,g,b), coverage scaled by `alpha`. When `dilate` > 0 the
// coverage is spread by that radius (a max filter) to draw a text outline.
void blit_coverage(Canvas* c,
                   const uint8_t* cov,
                   int gw,
                   int gh,
                   int dx,
                   int dy,
                   int r,
                   int g,
                   int b,
                   int alpha,
                   int dilate) {
  for (int j = -dilate; j < gh + dilate; ++j) {
    const int ty = dy + j;
    if (ty < 0 || ty >= c->h)
      continue;
    for (int i = -dilate; i < gw + dilate; ++i) {
      const int tx = dx + i;
      if (tx < 0 || tx >= c->w)
        continue;
      int m = 0;
      if (dilate == 0) {
        m = cov[j * gw + i];
      } else {
        for (int oy = -dilate; oy <= dilate && m < 255; ++oy) {
          const int sy = j + oy;
          if (sy < 0 || sy >= gh)
            continue;
          for (int ox = -dilate; ox <= dilate; ++ox) {
            const int sx = i + ox;
            if (sx < 0 || sx >= gw)
              continue;
            if (cov[sy * gw + sx] > m)
              m = cov[sy * gw + sx];
          }
        }
      }
      if (m <= 0)
        continue;
      blend(&c->px[(static_cast<size_t>(ty) * c->w + tx) * 4], r, g, b,
            m * alpha / 255);
    }
  }
}

// __mv_canvasDrawText(handle, x, y, text, r, g, b, a, size, dilate, baseline,
//                     m0, m1, m2, m3, m4, m5)
// Rasterise `text` at em size `size` with the game font and blend it in colour
// (r,g,b,a). `baseline` selects where y sits (0 alphabetic, 1 top, 2 middle,
// 3 bottom). `dilate` > 0 draws an outline (strokeText). The 2D matrix is
// honoured for translation and uniform scale (MV draws text axis-aligned, so
// rotation/skew are ignored). Text is pre-aligned by the caller, so this always
// lays out left-to-right from x.
JSValue js_draw_text(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  const char* text = argc > 3 ? JS_ToCString(ctx, argv[3]) : nullptr;
  if (!c || !text) {
    if (text)
      JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
  }
  GameFont& f = game_font();
  if (!f.ok) {
    JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
  }
  const double x = ad(ctx, argc, argv, 1, 0), y = ad(ctx, argc, argv, 2, 0);
  const int r = ai(ctx, argc, argv, 4), g = ai(ctx, argc, argv, 5);
  const int b = ai(ctx, argc, argv, 6), a = ai(ctx, argc, argv, 7);
  const double size = ad(ctx, argc, argv, 8, 10);
  const int dilate = ai(ctx, argc, argv, 9);
  const int baseline = ai(ctx, argc, argv, 10);
  const double m0 = ad(ctx, argc, argv, 11, 1), m1 = ad(ctx, argc, argv, 12, 0);
  const double m2 = ad(ctx, argc, argv, 13, 0), m3 = ad(ctx, argc, argv, 14, 1);
  const double m4 = ad(ctx, argc, argv, 15, 0), m5 = ad(ctx, argc, argv, 16, 0);

  // Uniform text scale from the matrix (rotation ignored). Device origin of the
  // baseline point is the matrix applied to (x, y).
  const double sy = std::sqrt(m2 * m2 + m3 * m3);
  const double scaleMul = sy > 0 ? sy : 1.0;
  const float scale = stbtt_ScaleForMappingEmToPixels(
      &f.info, static_cast<float>(size * scaleMul));
  int ascent = 0, descent = 0, lineGap = 0;
  stbtt_GetFontVMetrics(&f.info, &ascent, &descent, &lineGap);
  double baseY = m1 * x + m3 * y + m5;
  if (baseline == 1)  // top
    baseY += scale * ascent;
  else if (baseline == 2)  // middle
    baseY += scale * (ascent + descent) / 2.0;
  else if (baseline == 3)  // bottom
    baseY += scale * descent;
  double penX = m0 * x + m2 * y + m4;

  const unsigned char* s = reinterpret_cast<const unsigned char*>(text);
  const size_t n = std::strlen(text);
  int prev = 0;
  for (size_t i = 0; i < n;) {
    const int cp = static_cast<int>(utf8_next(s, n, i));
    if (prev)
      penX += scale * stbtt_GetCodepointKernAdvance(&f.info, prev, cp);
    int gw = 0, gh = 0, gxoff = 0, gyoff = 0;
    uint8_t* bmp = stbtt_GetCodepointBitmap(&f.info, scale, scale, cp, &gw, &gh,
                                            &gxoff, &gyoff);
    if (bmp) {
      const int dx = static_cast<int>(std::lround(penX)) + gxoff;
      const int dy = static_cast<int>(std::lround(baseY)) + gyoff;
      blit_coverage(c, bmp, gw, gh, dx, dy, r, g, b, a, dilate);
      stbtt_FreeBitmap(bmp, nullptr);
    }
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, cp, &adv, &lsb);
    penX += scale * adv;
    prev = cp;
  }
  JS_FreeCString(ctx, text);
  return JS_UNDEFINED;
}

// Read a numeric JS array into a vector<double> (length via .length, elements
// by index). Non-arrays yield an empty vector.
std::vector<double> js_num_array(JSContext* ctx, JSValueConst v) {
  std::vector<double> out;
  JSValue lenv = JS_GetPropertyStr(ctx, v, "length");
  int64_t len = 0;
  JS_ToInt64(ctx, &len, lenv);
  JS_FreeValue(ctx, lenv);
  for (int64_t i = 0; i < len; ++i) {
    JSValue e = JS_GetPropertyUint32(ctx, v, static_cast<uint32_t>(i));
    double d = 0;
    JS_ToFloat64(ctx, &d, e);
    JS_FreeValue(ctx, e);
    out.push_back(d);
  }
  return out;
}

// Sample a sorted gradient (parallel offset/channel arrays) at position t in
// [0,1], writing the interpolated colour to out[4]. Before the first stop uses
// the first colour; after the last uses the last.
void gradient_sample(const std::vector<double>& off,
                     const std::vector<double>& r,
                     const std::vector<double>& g,
                     const std::vector<double>& b,
                     const std::vector<double>& a,
                     double t,
                     double out[4]) {
  const size_t n = off.size();
  if (t <= off[0]) {
    out[0] = r[0];
    out[1] = g[0];
    out[2] = b[0];
    out[3] = a[0];
    return;
  }
  if (t >= off[n - 1]) {
    out[0] = r[n - 1];
    out[1] = g[n - 1];
    out[2] = b[n - 1];
    out[3] = a[n - 1];
    return;
  }
  for (size_t i = 0; i + 1 < n; ++i) {
    if (t >= off[i] && t <= off[i + 1]) {
      const double span = off[i + 1] - off[i];
      const double f = span > 0 ? (t - off[i]) / span : 0.0;
      out[0] = r[i] + (r[i + 1] - r[i]) * f;
      out[1] = g[i] + (g[i + 1] - g[i]) * f;
      out[2] = b[i] + (b[i + 1] - b[i]) * f;
      out[3] = a[i] + (a[i + 1] - a[i]) * f;
      return;
    }
  }
}

// __mv_canvasFillPattern(dstH, srcH, rx, ry, rw, rh, a, b, c, d, e, f, alpha)
// Fill the user-space rect (rx,ry,rw,rh) with the source canvas tiled
// ('repeat') under the current matrix [a b c d e f]. Like drawImage, but the
// source wraps (mod its size) over the rect and the tiling is anchored at the
// user-space origin, matching createPattern(canvas, 'repeat') + fillRect. MV's
// TilingSprite (map parallax and battlebacks) renders through this.
JSValue js_fill_pattern(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  Canvas* dst = canvas_get(ai(ctx, argc, argv, 0));
  Canvas* src = canvas_get(ai(ctx, argc, argv, 1));
  if (!dst || !src || src->w <= 0 || src->h <= 0)
    return JS_UNDEFINED;
  const double rx = ad(ctx, argc, argv, 2, 0), ry = ad(ctx, argc, argv, 3, 0);
  const double rw = ad(ctx, argc, argv, 4, 0), rh = ad(ctx, argc, argv, 5, 0);
  const double ma = ad(ctx, argc, argv, 6, 1), mb = ad(ctx, argc, argv, 7, 0);
  const double mc = ad(ctx, argc, argv, 8, 0), md = ad(ctx, argc, argv, 9, 1);
  const double me = ad(ctx, argc, argv, 10, 0), mf = ad(ctx, argc, argv, 11, 0);
  const int ga = argc > 12 ? ai(ctx, argc, argv, 12) : 255;
  if (rw <= 0 || rh <= 0)
    return JS_UNDEFINED;
  const double det = ma * md - mb * mc;
  if (det == 0)
    return JS_UNDEFINED;
  const double invdet = 1.0 / det;

  // Device-space bounding box of the four transformed rect corners.
  const double cxs[4] = {rx, rx + rw, rx + rw, rx};
  const double cys[4] = {ry, ry, ry + rh, ry + rh};
  double minx = 1e18, miny = 1e18, maxx = -1e18, maxy = -1e18;
  for (int i = 0; i < 4; ++i) {
    const double X = ma * cxs[i] + mc * cys[i] + me;
    const double Y = mb * cxs[i] + md * cys[i] + mf;
    minx = std::min(minx, X);
    maxx = std::max(maxx, X);
    miny = std::min(miny, Y);
    maxy = std::max(maxy, Y);
  }
  int x0 = std::max(static_cast<int>(std::floor(minx)), 0);
  int y0 = std::max(static_cast<int>(std::floor(miny)), 0);
  int x1 = std::min(static_cast<int>(std::ceil(maxx)), dst->w);
  int y1 = std::min(static_cast<int>(std::ceil(maxy)), dst->h);

  for (int py = y0; py < y1; ++py) {
    for (int px = x0; px < x1; ++px) {
      const double rxp = px - me, ryp = py - mf;
      const double u = (md * rxp - mc * ryp) * invdet;
      const double v = (-mb * rxp + ma * ryp) * invdet;
      if (u < rx || u >= rx + rw || v < ry || v >= ry + rh)
        continue;
      const long iu = static_cast<long>(std::floor(u));
      const long iv = static_cast<long>(std::floor(v));
      const int sxx = static_cast<int>(((iu % src->w) + src->w) % src->w);
      const int syy = static_cast<int>(((iv % src->h) + src->h) % src->h);
      const uint8_t* sp =
          &src->px[(static_cast<size_t>(syy) * src->w + sxx) * 4];
      const int a = sp[3] * ga / 255;
      blend(&dst->px[(static_cast<size_t>(py) * dst->w + px) * 4], sp[0], sp[1],
            sp[2], a);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasFillGradient(handle, rx, ry, rw, rh, x0, y0, x1, y1,
//                         offsets, r, g, b, a, globalAlpha)
// Fill the device rect (rx,ry,rw,rh) with a linear gradient whose axis runs
// (x0,y0)->(x1,y1) in device space; the parallel stop arrays give each colour
// stop's offset and RGBA. Each pixel's colour is its projection onto the axis.
// MV's Bitmap.gradientFillRect (gauges, window dimmers) drives this.
JSValue js_fill_gradient(JSContext* ctx,
                         JSValueConst,
                         int argc,
                         JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (!c || argc < 15)
    return JS_UNDEFINED;
  const int rx = ai(ctx, argc, argv, 1), ry = ai(ctx, argc, argv, 2);
  const int rw = ai(ctx, argc, argv, 3), rh = ai(ctx, argc, argv, 4);
  const double x0 = ad(ctx, argc, argv, 5, 0), y0 = ad(ctx, argc, argv, 6, 0);
  const double x1 = ad(ctx, argc, argv, 7, 0), y1 = ad(ctx, argc, argv, 8, 0);
  const std::vector<double> off = js_num_array(ctx, argv[9]);
  const std::vector<double> r = js_num_array(ctx, argv[10]);
  const std::vector<double> g = js_num_array(ctx, argv[11]);
  const std::vector<double> b = js_num_array(ctx, argv[12]);
  const std::vector<double> a = js_num_array(ctx, argv[13]);
  const double galpha = ad(ctx, argc, argv, 14, 1);
  const size_t n = off.size();
  if (n == 0 || r.size() < n || g.size() < n || b.size() < n || a.size() < n)
    return JS_UNDEFINED;

  const double dx = x1 - x0, dy = y1 - y0;
  const double len2 = dx * dx + dy * dy;
  for (int j = 0; j < rh; ++j) {
    const int ty = ry + j;
    if (ty < 0 || ty >= c->h)
      continue;
    for (int i = 0; i < rw; ++i) {
      const int tx = rx + i;
      if (tx < 0 || tx >= c->w)
        continue;
      double t = 0.0;
      if (len2 > 0)
        t = ((tx + 0.5 - x0) * dx + (ty + 0.5 - y0) * dy) / len2;
      if (t < 0)
        t = 0;
      else if (t > 1)
        t = 1;
      double col[4];
      gradient_sample(off, r, g, b, a, t, col);
      const int alpha = static_cast<int>(std::lround(col[3] * galpha));
      blend(&c->px[(static_cast<size_t>(ty) * c->w + tx) * 4],
            static_cast<int>(std::lround(col[0])),
            static_cast<int>(std::lround(col[1])),
            static_cast<int>(std::lround(col[2])), alpha);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasFillPolygon(handle, xs, ys, r, g, b, a, mode)
// Even-odd scanline fill of the polygon whose vertices are the parallel xs/ys
// arrays (already mapped to device space by the Ctx). Blends (r,g,b,a) under
// the given composite mode. Backs Ctx.fill() and thus Bitmap.drawCircle (arc +
// fill, e.g. Weather's snow) and any plugin vector fill; the path ops
// tessellate arcs to points before calling in.
JSValue js_fill_polygon(JSContext* ctx,
                        JSValueConst,
                        int argc,
                        JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (!c || argc < 7)
    return JS_UNDEFINED;
  const std::vector<double> xs = js_num_array(ctx, argv[1]);
  const std::vector<double> ys = js_num_array(ctx, argv[2]);
  const size_t n = std::min(xs.size(), ys.size());
  if (n < 3)
    return JS_UNDEFINED;
  const int r = ai(ctx, argc, argv, 3), g = ai(ctx, argc, argv, 4);
  const int b = ai(ctx, argc, argv, 5), a = ai(ctx, argc, argv, 6);
  const int mode = argc > 7 ? ai(ctx, argc, argv, 7) : 0;

  double miny = ys[0], maxy = ys[0];
  for (size_t i = 1; i < n; ++i) {
    miny = std::min(miny, ys[i]);
    maxy = std::max(maxy, ys[i]);
  }
  int y0 = std::max(static_cast<int>(std::floor(miny)), 0);
  int y1 = std::min(static_cast<int>(std::ceil(maxy)), c->h);

  std::vector<double> xints;
  for (int y = y0; y < y1; ++y) {
    const double yc = y + 0.5;
    xints.clear();
    for (size_t i = 0; i < n; ++i) {
      const size_t j = (i + 1) % n;
      const double ya = ys[i], yb = ys[j];
      if ((ya <= yc && yb > yc) || (yb <= yc && ya > yc)) {
        const double t = (yc - ya) / (yb - ya);
        xints.push_back(xs[i] + t * (xs[j] - xs[i]));
      }
    }
    std::sort(xints.begin(), xints.end());
    for (size_t k = 0; k + 1 < xints.size(); k += 2) {
      int xa = static_cast<int>(std::ceil(xints[k] - 0.5));
      int xb = static_cast<int>(std::floor(xints[k + 1] - 0.5));
      xa = std::max(xa, 0);
      xb = std::min(xb, c->w - 1);
      for (int x = xa; x <= xb; ++x)
        blend_mode(&c->px[(static_cast<size_t>(y) * c->w + x) * 4], r, g, b, a,
                   mode);
    }
  }
  return JS_UNDEFINED;
}

// __mv_canvasGetPixel(handle, x, y) -> [r, g, b, a] (used by tests and by the
// getImageData path). Out-of-range reads return transparent black.
JSValue js_get_pixel(JSContext* ctx,
                     JSValueConst,
                     int argc,
                     JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  const int x = ai(ctx, argc, argv, 1), y = ai(ctx, argc, argv, 2);
  JSValue arr = JS_NewArray(ctx);
  uint8_t out[4] = {0, 0, 0, 0};
  if (c && x >= 0 && x < c->w && y >= 0 && y < c->h)
    std::memcpy(out, &c->px[(static_cast<size_t>(y) * c->w + x) * 4], 4);
  for (uint32_t k = 0; k < 4; ++k)
    JS_SetPropertyUint32(ctx, arr, k, JS_NewInt32(ctx, out[k]));
  return arr;
}

// __mv_canvasPutData(handle, dx, dy, w, h, data)
// Write a w*h block of RGBA bytes (a flat [r,g,b,a,...] array-like, as
// produced by getImageData or handed in raw) into the canvas at (dx, dy). Per
// the canvas spec putImageData *replaces* pixels (no source-over blend) and
// ignores the current transform, so this is a straight copy, clipped to the
// canvas bounds. Values are clamped to 0-255 defensively -- getImageData's own
// Uint8ClampedArray already clamps `pixels[i] += tone` writes at assignment
// (MV drives this from Bitmap.adjustTone / rotateHue, which read the pixels
// back, recolour them and write them out), but `data` is read generically
// (js_num_array, by .length and index) so a caller handing in a plain array
// or object literal directly -- as a synthetic ImageData, or a value read
// back out of range some other way -- still gets a spec-correct result.
JSValue js_put_data(JSContext* ctx,
                    JSValueConst,
                    int argc,
                    JSValueConst* argv) {
  Canvas* c = canvas_get(ai(ctx, argc, argv, 0));
  if (!c || argc < 6)
    return JS_UNDEFINED;
  const int dx = ai(ctx, argc, argv, 1), dy = ai(ctx, argc, argv, 2);
  const int w = ai(ctx, argc, argv, 3), h = ai(ctx, argc, argv, 4);
  if (w <= 0 || h <= 0)
    return JS_UNDEFINED;
  const std::vector<double> data = js_num_array(ctx, argv[5]);
  if (data.size() < static_cast<size_t>(w) * h * 4)
    return JS_UNDEFINED;
  for (int j = 0; j < h; ++j) {
    const int ty = dy + j;
    if (ty < 0 || ty >= c->h)
      continue;
    for (int i = 0; i < w; ++i) {
      const int tx = dx + i;
      if (tx < 0 || tx >= c->w)
        continue;
      const size_t si = (static_cast<size_t>(j) * w + i) * 4;
      uint8_t* d = &c->px[(static_cast<size_t>(ty) * c->w + tx) * 4];
      for (int k = 0; k < 4; ++k) {
        double v = data[si + k];
        v = v < 0 ? 0 : (v > 255 ? 255 : v);
        d[k] = static_cast<uint8_t>(v);
      }
    }
  }
  return JS_UNDEFINED;
}

// __mv_setWindowTitle(title) -- what `document.title = ...` reaches (see the
// accessor installed in the preamble below). In a browser that names the tab;
// here it names the SDL window, through the same bridge every other maker's
// boot uses (include/terminal.hxx's "Window title bridge"). MV's and MZ's own
// Scene_Boot assigns $dataSystem.gameTitle to document.title, so a game — and
// any plugin that retitles the page — names the window itself.
JSValue js_set_window_title(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (argc < 1)
    return JS_UNDEFINED;
  const char* title = JS_ToCString(ctx, argv[0]);
  if (!title)
    return JS_UNDEFINED;
  window_title_set(title);
  JS_FreeCString(ctx, title);
  return JS_UNDEFINED;
}

// __mv_imageLoad(path) -> a canvas handle holding the decoded image (0 on
// failure). MV's Bitmap loads PNGs through `new Image()`; we decode them with
// stb_image (RGBA8) straight into a canvas so the result can be used as a
// drawImage source, exactly like a canvas. The path is game-relative and rooted
// via mv_resolve_path.
JSValue js_image_load(JSContext* ctx,
                      JSValueConst,
                      int argc,
                      JSValueConst* argv) {
  if (argc < 1)
    return JS_NewInt32(ctx, 0);
  const char* path = JS_ToCString(ctx, argv[0]);
  if (!path)
    return JS_NewInt32(ctx, 0);
  const std::string resolved = mv_resolve_path(path);
  JS_FreeCString(ctx, path);

  int w = 0, h = 0, comp = 0;
  unsigned char* data = stbi_load(resolved.c_str(), &w, &h, &comp, 4);
  if (!data)
    return JS_NewInt32(ctx, 0);

  Canvas* c = new Canvas();
  c->resize(w, h);
  std::memcpy(c->px.data(), data,
              static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
  stbi_image_free(data);
  g_canvases.push_back(c);
  return JS_NewInt32(ctx, static_cast<int>(g_canvases.size()));
}

// __mv_imageLoadBytes(arrayBuffer) -> a canvas handle holding the decoded
// image (0 on failure), the in-memory twin of __mv_imageLoad above.
//
// This is what makes an **encrypted** project loadable. RPG Maker's deployment
// can encrypt every image (`img/**/*.png_` on MZ, `*.rpgmvp` on MV), and the
// engine's own code is what undoes it: it XHRs the file as an ArrayBuffer,
// decrypts it in JavaScript, wraps the plaintext in a Blob and hands the
// resulting object URL to an Image. Nothing reaches the filesystem by name at
// that point, so a loader that can only open a path cannot see the result. See
// ADR 0004 M6.3r.
JSValue js_image_load_bytes(JSContext* ctx,
                            JSValueConst,
                            int argc,
                            JSValueConst* argv) {
  if (argc < 1)
    return JS_NewInt32(ctx, 0);
  size_t len = 0;
  uint8_t* bytes = JS_GetArrayBuffer(ctx, &len, argv[0]);
  if (!bytes || len == 0)
    return JS_NewInt32(ctx, 0);

  int w = 0, h = 0, comp = 0;
  unsigned char* data =
      stbi_load_from_memory(bytes, static_cast<int>(len), &w, &h, &comp, 4);
  if (!data)
    return JS_NewInt32(ctx, 0);

  Canvas* c = new Canvas();
  c->resize(w, h);
  std::memcpy(c->px.data(), data,
              static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
  stbi_image_free(data);
  g_canvases.push_back(c);
  return JS_NewInt32(ctx, static_cast<int>(g_canvases.size()));
}

// The Canvas2D JavaScript shim: document, HTMLCanvasElement and the 2D context.
const char* kCanvasPreamble = R"MVJS(
(function (g) {
  function parseColor(s) {
    if (typeof s !== 'string') return [0, 0, 0, 255];
    s = s.trim();
    if (s.charAt(0) === '#') {
      if (s.length === 4) {
        return [parseInt(s.charAt(1) + s.charAt(1), 16),
                parseInt(s.charAt(2) + s.charAt(2), 16),
                parseInt(s.charAt(3) + s.charAt(3), 16), 255];
      }
      return [parseInt(s.substr(1, 2), 16), parseInt(s.substr(3, 2), 16),
              parseInt(s.substr(5, 2), 16), 255];
    }
    var m = s.match(/rgba?\(([^)]+)\)/);
    if (m) {
      var p = m[1].split(',');
      return [parseInt(p[0], 10) || 0, parseInt(p[1], 10) || 0,
              parseInt(p[2], 10) || 0,
              p.length > 3 ? Math.round(parseFloat(p[3]) * 255) : 255];
    }
    return [0, 0, 0, 255];
  }

  function Ctx(h) {
    this.__h = h;
    this.canvas = null;
    this.fillStyle = '#000000';
    this.strokeStyle = '#000000';
    this.globalAlpha = 1;
    this.globalCompositeOperation = 'source-over';
    this.font = '10px sans-serif';
    this.textAlign = 'left';
    this.textBaseline = 'alphabetic';
    this.lineWidth = 1;
    this.imageSmoothingEnabled = true;
    this._m = [1, 0, 0, 1, 0, 0];  // current transform (a,b,c,d,e,f)
    this._stack = [];
  }
  // Post-multiply the current matrix by T (canvas semantics: new coordinates are
  // transformed by T first, then the existing matrix).
  function matMul(M, T) {
    return [
      M[0] * T[0] + M[2] * T[1],
      M[1] * T[0] + M[3] * T[1],
      M[0] * T[2] + M[2] * T[3],
      M[1] * T[2] + M[3] * T[3],
      M[0] * T[4] + M[2] * T[5] + M[4],
      M[1] * T[4] + M[3] * T[5] + M[5],
    ];
  }
  Ctx.prototype.save = function () {
    this._stack.push([this._m.slice(), this.globalAlpha, this.fillStyle,
                      this.strokeStyle, this.globalCompositeOperation]);
  };
  Ctx.prototype.restore = function () {
    var s = this._stack.pop();
    if (!s) return;
    this._m = s[0];
    this.globalAlpha = s[1];
    this.fillStyle = s[2];
    this.strokeStyle = s[3];
    this.globalCompositeOperation = s[4];
  };
  Ctx.prototype.translate = function (x, y) { this._m = matMul(this._m, [1, 0, 0, 1, x, y]); };
  Ctx.prototype.scale = function (x, y) { this._m = matMul(this._m, [x, 0, 0, y, 0, 0]); };
  Ctx.prototype.rotate = function (r) {
    var c = Math.cos(r), s = Math.sin(r);
    this._m = matMul(this._m, [c, s, -s, c, 0, 0]);
  };
  Ctx.prototype.transform = function (a, b, c, d, e, f) { this._m = matMul(this._m, [a, b, c, d, e, f]); };
  Ctx.prototype.setTransform = function (a, b, c, d, e, f) { this._m = [a, b, c, d, e, f]; };
  Ctx.prototype.resetTransform = function () { this._m = [1, 0, 0, 1, 0, 0]; };
  // Map globalCompositeOperation to the native blend mode: 1 = lighter/additive
  // (flashes, weather, positive tones), 2 = difference (negative screen tones),
  // 3 = saturation (grey/desaturation tones). Everything else (including the
  // default source-over) is 0; unsupported ops stay source-over.
  function compositeMode(op) {
    if (op === 'lighter') return 1;
    if (op === 'difference') return 2;
    if (op === 'saturation') return 3;
    return 0;
  }
  // Map the axis-aligned rect (x,y,w,h) through the current matrix to a device
  // rect. Exact for translate/scale (the common case); for rotation/skew this
  // is the rect's bounding box, which is enough for the solid fills MV uses.
  function mapRect(m, x, y, w, h) {
    var x0 = m[0] * x + m[2] * y + m[4], y0 = m[1] * x + m[3] * y + m[5];
    var x1 = m[0] * (x + w) + m[2] * (y + h) + m[4];
    var y1 = m[1] * (x + w) + m[3] * (y + h) + m[5];
    return [Math.round(Math.min(x0, x1)), Math.round(Math.min(y0, y1)),
            Math.round(Math.abs(x1 - x0)), Math.round(Math.abs(y1 - y0))];
  }
  Ctx.prototype.fillRect = function (x, y, w, h) {
    var fs = this.fillStyle;
    if (fs && fs.__mvGrad) { this._fillGradientRect(fs, x, y, w, h); return; }
    if (fs && fs.__mvPattern) { this._fillPatternRect(fs, x, y, w, h); return; }
    var c = parseColor(fs);
    var a = Math.round(c[3] * this.globalAlpha);
    var r = mapRect(this._m, x, y, w, h);
    var mode = compositeMode(this.globalCompositeOperation);
    g.__mv_canvasFillRect(this.__h, r[0], r[1], r[2], r[3], c[0], c[1], c[2], a,
                          mode);
  };
  // Outline a rect in strokeStyle, as four `lineWidth`-thick bars through the
  // same native fill. MV never calls this, but MZ does on a hot path:
  // Window_Selectable.drawBackgroundRect strokes the frame of *every* item in
  // *every* selectable window (via Bitmap.strokeRect), so the title command
  // window throws "TypeError: not a function" on the first drawn frame without
  // it — which is exactly what stopped MZ's boot at Scene_Title (see ADR 0004
  // M6.3c). Canvas centres a stroke on the path, so each bar straddles the edge
  // by half the line width.
  Ctx.prototype.strokeRect = function (x, y, w, h) {
    var lw = this.lineWidth > 0 ? this.lineWidth : 1;
    var half = lw / 2;
    // Draw through fillRect so the transform, alpha, composite mode and colour
    // parsing all behave exactly as they do for a filled rect. fillStyle is
    // swapped in and restored rather than saved on the stack, which callers own.
    var fs = this.fillStyle;
    this.fillStyle = this.strokeStyle;
    this.fillRect(x - half, y - half, w + lw, lw);          // top
    this.fillRect(x - half, y + h - half, w + lw, lw);      // bottom
    this.fillRect(x - half, y + half, lw, h - lw);          // left
    this.fillRect(x + w - half, y + half, lw, h - lw);      // right
    this.fillStyle = fs;
  };
  // Fill a rect with a gradient fillStyle. The rect and the gradient axis are
  // both mapped through the current transform to device space, then the native
  // rasteriser projects each pixel onto the axis. A radial gradient (no true
  // radial rasteriser yet) falls back to a linear one along its centre line.
  Ctx.prototype._fillGradientRect = function (grad, x, y, w, h) {
    var stops = grad._stops;
    if (!stops.length) return;
    stops = stops.slice().sort(function (p, q) { return p[0] - q[0]; });
    var m = this._m;
    var r = mapRect(m, x, y, w, h);
    function mapPt(px, py) {
      return [m[0] * px + m[2] * py + m[4], m[1] * px + m[3] * py + m[5]];
    }
    var p0 = mapPt(grad.x0, grad.y0), p1 = mapPt(grad.x1, grad.y1);
    var offs = [], rr = [], gg = [], bb = [], aa = [];
    for (var i = 0; i < stops.length; i++) {
      offs.push(stops[i][0]);
      var col = stops[i][1];
      rr.push(col[0]); gg.push(col[1]); bb.push(col[2]); aa.push(col[3]);
    }
    g.__mv_canvasFillGradient(this.__h, r[0], r[1], r[2], r[3],
      p0[0], p0[1], p1[0], p1[1], offs, rr, gg, bb, aa, this.globalAlpha);
  };
  // Fill a rect with a repeating pattern fillStyle (createPattern). The rect and
  // current matrix are handed to the native tiler, which wraps the source over
  // the rect anchored at the user-space origin (canvas 'repeat' semantics).
  Ctx.prototype._fillPatternRect = function (pat, x, y, w, h) {
    if (!pat.__srcH) return;
    var m = this._m;
    var a = Math.round(this.globalAlpha * 255);
    g.__mv_canvasFillPattern(this.__h, pat.__srcH, x, y, w, h,
                             m[0], m[1], m[2], m[3], m[4], m[5], a);
  };
  Ctx.prototype.clearRect = function (x, y, w, h) {
    var r = mapRect(this._m, x, y, w, h);
    g.__mv_canvasClearRect(this.__h, r[0], r[1], r[2], r[3]);
  };
  function srcHandle(img) {
    if (!img) return 0;
    if (img.__h) return img.__h;
    if (img._canvas && img._canvas.__h) return img._canvas.__h;
    return 0;
  }
  Ctx.prototype.drawImage = function (img) {
    var h = srcHandle(img);
    if (!h) return;
    var iw = img.width || 0, ih = img.height || 0;
    var sx = 0, sy = 0, sw = iw, sh = ih, dx, dy, dw, dh;
    if (arguments.length <= 3) {
      dx = arguments[1]; dy = arguments[2]; dw = iw; dh = ih;
    } else if (arguments.length <= 5) {
      dx = arguments[1]; dy = arguments[2]; dw = arguments[3]; dh = arguments[4];
    } else {
      sx = arguments[1]; sy = arguments[2]; sw = arguments[3]; sh = arguments[4];
      dx = arguments[5]; dy = arguments[6]; dw = arguments[7]; dh = arguments[8];
    }
    var a = Math.round(this.globalAlpha * 255);
    var m = this._m;
    var mode = compositeMode(this.globalCompositeOperation);
    g.__mv_canvasDrawImage(this.__h, h, sx, sy, sw, sh, dx, dy, dw, dh, a,
                           m[0], m[1], m[2], m[3], m[4], m[5], mode);
  };
  Ctx.prototype.getImageData = function (x, y, w, h) {
    w = w | 0; h = h | 0;
    // A real Uint8ClampedArray, not a plain Array: third-party code (PIXI's
    // extract.canvas, which Bitmap.snap/snapToBitmap goes through) calls
    // typed-array-only methods like .set() on it, which a plain Array does
    // not have -- see the TypeError this used to throw, caught booting a real
    // MV game (Lunatic-Core) into its title-screen snapshot transition.
    var data = new Uint8ClampedArray(w * h * 4);
    var idx = 0;
    for (var j = 0; j < h; j++) {
      for (var i = 0; i < w; i++) {
        var p = g.__mv_canvasGetPixel(this.__h, (x | 0) + i, (y | 0) + j);
        data[idx++] = p[0]; data[idx++] = p[1]; data[idx++] = p[2]; data[idx++] = p[3];
      }
    }
    return { width: w, height: h, data: data };
  };
  // putImageData(imageData, dx, dy): write pixels straight back (no blend, no
  // transform), the inverse of getImageData. MV uses it in Bitmap.adjustTone and
  // rotateHue to commit recoloured pixels; the optional dirty-rect args of the
  // full spec are unused by MV, so only the 3-arg form is handled.
  Ctx.prototype.putImageData = function (imageData, dx, dy) {
    if (!imageData || !imageData.data) return;
    g.__mv_canvasPutData(this.__h, dx | 0, dy | 0,
                         imageData.width | 0, imageData.height | 0,
                         imageData.data);
  };
  // Pixel (em) size from a CSS font shorthand, e.g. '28px GameFont' -> 28.
  function fontPx(s) {
    var m = /([\d.]+)px/.exec(s || '');
    return m ? parseFloat(m[1]) : 10;
  }
  // Whether a CSS font shorthand names "GameFont", MV's own custom-font
  // family (always loaded as literally that name -- see font_text_width's
  // own comment in mvcanvas.cxx for why this distinction matters).
  function fontHasGameFont(s) {
    return /GameFont/.test(s || '');
  }
  // Map a canvas textBaseline to the native code (0 alphabetic, 1 top,
  // 2 middle, 3 bottom); ideographic/hanging fall back to the nearest.
  function baselineCode(b) {
    if (b === 'top' || b === 'hanging') return 1;
    if (b === 'middle') return 2;
    if (b === 'bottom' || b === 'ideographic') return 3;
    return 0;
  }
  Ctx.prototype.measureText = function (t) {
    return { width: g.__mv_fontMeasure(fontPx(this.font), t == null ? '' : String(t),
                                       fontHasGameFont(this.font) ? 1 : 0) };
  };
  // Shared layout for fill/strokeText: resolve colour, size and the horizontal
  // alignment offset, then hand off to the native rasteriser with the current
  // transform. `dilate` > 0 draws an outline (strokeText).
  function drawText(self, style, dilate, text, x, y) {
    if (text == null) return;
    text = String(text);
    var col = parseColor(style);
    var a = Math.round(col[3] * self.globalAlpha);
    if (a <= 0) return;
    var size = fontPx(self.font);
    var hasGameFont = fontHasGameFont(self.font) ? 1 : 0;
    var ax = x;
    if (self.textAlign === 'center') {
      ax -= g.__mv_fontMeasure(size, text, hasGameFont) / 2;
    } else if (self.textAlign === 'right' || self.textAlign === 'end') {
      ax -= g.__mv_fontMeasure(size, text, hasGameFont);
    }
    var m = self._m;
    g.__mv_canvasDrawText(self.__h, ax, y, text, col[0], col[1], col[2], a,
                          size, dilate, baselineCode(self.textBaseline),
                          m[0], m[1], m[2], m[3], m[4], m[5]);
  }
  Ctx.prototype.fillText = function (text, x, y) {
    drawText(this, this.fillStyle, 0, text, x, y);
  };
  Ctx.prototype.strokeText = function (text, x, y) {
    var d = Math.round((this.lineWidth || 1) / 2);
    if (d < 1) d = 1;
    if (d > 2) d = 2;
    drawText(this, this.strokeStyle, d, text, x, y);
  };
  // Gradients: MV's Bitmap.gradientFillRect builds a linear gradient, chains
  // .addColorStop, assigns it to fillStyle and fillRects. Return an object that
  // records its axis and colour stops; fillRect rasterises it (see
  // _fillGradientRect). Each stop's colour is parsed once, at add time.
  function makeGradient(kind, x0, y0, x1, y1) {
    return {
      __mvGrad: kind, x0: x0, y0: y0, x1: x1, y1: y1, _stops: [],
      addColorStop: function (offset, color) {
        this._stops.push([offset, parseColor(color)]);
      },
    };
  }
  Ctx.prototype.createLinearGradient = function (x0, y0, x1, y1) {
    return makeGradient('linear', x0, y0, x1, y1);
  };
  // No true radial rasteriser yet: approximate a radial gradient as a linear one
  // from the inner circle's centre to the outer circle's edge, so it renders a
  // reasonable ramp instead of falling back to black.
  Ctx.prototype.createRadialGradient = function (x0, y0, r0, x1, y1, r1) {
    return makeGradient('radial', x1, y1, x1 + (r1 || 0), y1);
  };
  // createPattern(image, repetition): a pattern usable as a fillStyle, tiling
  // the image's canvas. Only 'repeat' is modelled (what MV's TilingSprite uses);
  // _fillPatternRect reads __srcH to tile it.
  Ctx.prototype.createPattern = function (image, repetition) {
    return {
      __mvPattern: true,
      __srcH: srcHandle(image),
      repeat: repetition || 'repeat',
    };
  };
  // Path and text operations MV/PIXI call but that the buffer path does not need
  // yet: accept and ignore. Real implementations land as needed. (Transform ops
  // — save/restore/translate/scale/rotate/transform/setTransform/resetTransform
  // — are implemented above and deliberately excluded here.)
  // Minimal path support: build one polygon from moveTo/lineTo/arc/rect and
  // scanline-fill it on fill(). Enough for Bitmap.drawCircle (arc + fill, used by
  // Weather's snow) and simple vector fills. Arcs tessellate to segments; stroke,
  // clip and multi-subpath aren't modelled (they stay no-ops below).
  Ctx.prototype.beginPath = function () { this._path = []; };
  Ctx.prototype.moveTo = function (x, y) {
    (this._path || (this._path = [])).push([x, y]);
  };
  Ctx.prototype.lineTo = Ctx.prototype.moveTo;
  Ctx.prototype.rect = function (x, y, w, h) {
    var p = this._path || (this._path = []);
    p.push([x, y], [x + w, y], [x + w, y + h], [x, y + h]);
  };
  Ctx.prototype.arc = function (cx, cy, r, a0, a1) {
    var p = this._path || (this._path = []);
    var segs = 32;
    for (var i = 0; i <= segs; i++) {
      var t = a0 + (a1 - a0) * (i / segs);
      p.push([cx + r * Math.cos(t), cy + r * Math.sin(t)]);
    }
  };
  Ctx.prototype.fill = function () {
    var path = this._path;
    if (!path || path.length < 3) return;
    var fs = this.fillStyle;
    if (fs && (fs.__mvGrad || fs.__mvPattern)) return; // only solid fills
    var col = parseColor(fs);
    var a = Math.round(col[3] * this.globalAlpha);
    var m = this._m, xs = [], ys = [];
    for (var i = 0; i < path.length; i++) {
      var pt = path[i];
      xs.push(m[0] * pt[0] + m[2] * pt[1] + m[4]);
      ys.push(m[1] * pt[0] + m[3] * pt[1] + m[5]);
    }
    g.__mv_canvasFillPolygon(this.__h, xs, ys, col[0], col[1], col[2], a,
                             compositeMode(this.globalCompositeOperation));
  };
  // Stroke the current path: draw each segment as a lineWidth-thick quad
  // (perpendicular offset) filled through the polygon rasteriser. No core MV
  // consumer, but plugins commonly draw HUD/gauge borders this way. Butt caps,
  // no joins — enough for the thin lines plugins use; honors the transform,
  // globalAlpha and composite mode like fill().
  Ctx.prototype.stroke = function () {
    var path = this._path;
    if (!path || path.length < 2) return;
    var ss = this.strokeStyle;
    if (ss && (ss.__mvGrad || ss.__mvPattern)) return; // only solid strokes
    var col = parseColor(ss);
    var a = Math.round(col[3] * this.globalAlpha);
    var hw = (this.lineWidth || 1) / 2;
    var m = this._m;
    var mode = compositeMode(this.globalCompositeOperation);
    function dev(pt) {
      return [m[0] * pt[0] + m[2] * pt[1] + m[4],
              m[1] * pt[0] + m[3] * pt[1] + m[5]];
    }
    for (var i = 0; i + 1 < path.length; i++) {
      var pa = dev(path[i]), pb = dev(path[i + 1]);
      var dx = pb[0] - pa[0], dy = pb[1] - pa[1];
      var len = Math.sqrt(dx * dx + dy * dy) || 1;
      var nx = -dy / len * hw, ny = dx / len * hw;
      g.__mv_canvasFillPolygon(this.__h,
        [pa[0] + nx, pb[0] + nx, pb[0] - nx, pa[0] - nx],
        [pa[1] + ny, pb[1] + ny, pb[1] - ny, pa[1] - ny],
        col[0], col[1], col[2], a, mode);
    }
  };
  // Path/text ops MV or PIXI may call that the buffer path does not need yet:
  // accept and ignore. (clip is the notable one; fill/stroke above cover the
  // path drawing MV core and plugins use.)
  var noops = ['closePath', 'arcTo', 'clip',
    'setLineDash',
    'drawFocusIfNeeded', 'scrollPathIntoView'];
  noops.forEach(function (m) {
    if (!Ctx.prototype[m]) Ctx.prototype[m] = function () {};
  });

  function Canvas(w, h) {
    var self = this;
    this._w = w || 0;
    this._h = h || 0;
    this.__h = g.__mv_canvasCreate(this._w, this._h);
    this._ctx = null;
    this.style = {};
    // Resizing the canvas resizes its backing buffer *and*, when a WebGL
    // context has been taken from it, that context's off-screen render target.
    // MZ creates its context while the canvas is still 0x0 and only sizes it in
    // Scene_Boot.resizeScreen -> Graphics.resize -> PIXI's renderer.resize,
    // which assigns these properties; without following through, the whole game
    // renders into the 1x1 target the context was created with.
    function resized() {
      g.__mv_canvasResize(self.__h, self._w, self._h);
      if (self._glctx && self._glctx.__mv_resize)
        self._glctx.__mv_resize(self._w, self._h);
    }
    Object.defineProperty(this, 'width', {
      get: function () { return self._w; },
      set: function (v) { self._w = v | 0; resized(); },
    });
    Object.defineProperty(this, 'height', {
      get: function () { return self._h; },
      set: function (v) { self._h = v | 0; resized(); },
    });
  }
  Canvas.prototype.getContext = function (type) {
    if (type === '2d') {
      if (!this._ctx) { this._ctx = new Ctx(this.__h); this._ctx.canvas = this; }
      return this._ctx;
    }
    // WebGL1 (MZ / PIXI v5). The wrapper is only installed where the native
    // EGL/GLES2 backend compiled in (mvwebgl.cxx); without it __mv_glCreate is
    // absent and we fall through to null, so Utils.canUseWebGL() reports false
    // and PIXI takes its Canvas path (the MV route) as before. 'webgl2' stays
    // null: MZ's PIXI v5 uses WebGL1.
    if (type === 'webgl' || type === 'experimental-webgl') {
      if (typeof g.WebGLRenderingContext !== 'function' || !g.__mv_glCreate)
        return null;
      if (!this._glctx) this._glctx = new g.WebGLRenderingContext(this);
      return this._glctx.__gl ? this._glctx : null;
    }
    return null;
  };
  Canvas.prototype.addEventListener = function () {};
  Canvas.prototype.removeEventListener = function () {};
  Canvas.prototype.getBoundingClientRect = function () {
    return { left: 0, top: 0, right: this._w, bottom: this._h,
             width: this._w, height: this._h };
  };
  g.HTMLCanvasElement = Canvas;

  // A permissive stand-in for a DOM element. MV attaches error printers, font
  // <style> rules, the mode box and video elements to the document during
  // Graphics.initialize, so the surface here is what that init path touches:
  // child insertion (returning the child, as the DOM does), a CSSStyleSheet with
  // insertRule (font loader), classList, and the usual accessors.
  function stubElement(tag) {
    var el = {
      tagName: ('' + tag).toUpperCase(),
      style: {}, dataset: {}, className: '', id: '', innerHTML: '', textContent: '',
      // <style> elements expose a .sheet whose insertRule the font loader calls.
      sheet: { insertRule: function () {}, deleteRule: function () {}, cssRules: [] },
      classList: { add: function () {}, remove: function () {}, toggle: function () {},
                   contains: function () { return false; } },
      getContext: function () { return null; },
      appendChild: function (c) { return c; },
      insertBefore: function (c) { return c; },
      removeChild: function (c) { return c; },
      remove: function () {},
      cloneNode: function () { return stubElement(tag); },
      setAttribute: function () {}, getAttribute: function () { return null; },
      removeAttribute: function () {}, hasAttribute: function () { return false; },
      addEventListener: function () {}, removeEventListener: function () {},
      querySelector: function () { return null; },
      querySelectorAll: function () { return []; },
      // Graphics._disableContextMenu walks document.body.getElementsByTagName('*').
      getElementsByTagName: function () { return []; },
      getElementsByClassName: function () { return []; },
      // A real browser's document.body/documentElement report the viewport
      // size here; some MV/MZ corescript builds compute their initial screen
      // resolution from this rect rather than (or as well as) window.innerWidth
      // /innerHeight -- an all-zero stand-in made that path land on a 0x0
      // Graphics.width/height, which PIXI then silently fails to render into
      // (Graphics.initialize returns false, "Failed to initialize graphics.").
      // Match window.innerWidth/innerHeight, our fixed viewport, so both paths
      // agree.
      getBoundingClientRect: function () {
        var w = g.innerWidth, h = g.innerHeight;
        return { left: 0, top: 0, right: w, bottom: h, width: w, height: h };
      },
      focus: function () {}, blur: function () {}, click: function () {},
    };
    return el;
  }
  var docHead = stubElement('head');
  var docBody = stubElement('body');
  // A FontFaceSet stand-in. When document.fonts is present MV takes its CSS
  // font-loading path (Graphics._cssFontLoading) and detects the game font via
  // fonts.check() instead of comparing measured text widths — which our
  // font-agnostic measureText can't distinguish, so Scene_Boot would otherwise
  // wait forever for the font and never advance to the title. Report the font
  // as ready so boot proceeds (we render text through the engine, not CSS).
  var fontFaceSet = {
    check: function () { return true; },
    load: function () { return Promise.resolve([]); },
    add: function () {}, delete: function () {}, clear: function () {},
    forEach: function () {}, size: 0, status: 'loaded',
  };
  fontFaceSet.ready = Promise.resolve(fontFaceSet);
  g.document = {
    createElement: function (tag) {
      tag = ('' + tag).toLowerCase();
      return tag === 'canvas' ? new Canvas() : stubElement(tag);
    },
    createTextNode: function () { return stubElement('#text'); },
    getElementById: function () { return null; },
    getElementsByTagName: function (tag) {
      tag = ('' + tag).toLowerCase();
      if (tag === 'head') return [docHead];
      if (tag === 'body') return [docBody];
      if (tag === 'script') {
        // Utils.canReadGameFiles reads the last <script>'s src over XHR to
        // verify local-file access; point it at a file that is always present
        // (rpg_core.js is a required MV marker) so the probe succeeds here.
        var sc = stubElement('script');
        sc.src = 'js/rpg_core.js';
        return [sc];
      }
      return [];
    },
    querySelector: function () { return null; },
    querySelectorAll: function () { return []; },
    createEvent: function () { return { initEvent: function () {} }; },
    addEventListener: function () {}, removeEventListener: function () {},
    body: docBody,
    documentElement: stubElement('html'),
    head: docHead,
    fonts: fontFaceSet,
  };

  // document.title: Scene_Boot assigns $dataSystem.gameTitle to it once the
  // database is loaded, which is how an MV/MZ game names the browser tab. Make
  // it a real accessor so that assignment reaches the host and names the game
  // window instead, and so a plugin reading it back gets what it wrote.
  var docTitle = '';
  Object.defineProperty(g.document, 'title', {
    get: function () { return docTitle; },
    set: function (v) {
      docTitle = v === undefined || v === null ? '' : '' + v;
      g.__mv_setWindowTitle(docTitle);
    },
  });

  // Image: MV's Bitmap loads PNGs with `new Image()` + `.src = url`. We decode
  // synchronously (stb_image, via __mv_imageLoad) into a canvas handle, but fire
  // onload/onerror on the next host frame (via requestAnimationFrame) to match
  // the browser contract MV's loader relies on — handlers are attached after src
  // is set, and MV polls ImageManager.isReady() across frames. rAF is used
  // rather than setTimeout so the deferral is independent of the host clock. The
  // decoded canvas handle is exposed as `__h`, so drawImage(image, ...) works
  // through the same srcHandle() path a canvas does.
  //
  // `onload`/`onerror` and addEventListener('load'/'error', ...) are kept as
  // independent listener slots, matching the real DOM (the `onload` IDL
  // attribute is just one more listener alongside ones added via
  // addEventListener, not a replacement for them). PIXI's BaseTexture sets
  // `.onload` directly on an incomplete Image to know when its source is
  // ready, *after* Bitmap#_requestImage has already registered its own
  // handler via addEventListener('load', ...); aliasing both to a single
  // slot let PIXI's later assignment silently discard MV's own load handler,
  // so Bitmap never left `_loadingState: 'requesting'` and the map scene
  // never became ready. Both must fire.
  function ImageEl() {
    this.__h = 0;
    this.width = 0;
    this.height = 0;
    this.onload = null;
    this.onerror = null;
    this.complete = false;
    this._src = '';
    this._gen = 0;
    this._loadListeners = [];
    this._errorListeners = [];
  }
  Object.defineProperty(ImageEl.prototype, 'src', {
    get: function () { return this._src; },
    set: function (v) {
      var self = this;
      this._src = v;
      this.complete = false;
      // MV pools and reuses Image instances via Bitmap._reuseImages: a
      // discarded bitmap sets `.src = ''` to release its image back to the
      // pool (Bitmap#_clearImgInstance), and the very next bitmap request can
      // pop and reassign that same instance before the empty-src completion
      // below has fired. A real browser aborts the in-flight decode when
      // `.src` is reassigned, so only the *latest* assignment's load/error
      // ever fires; `_gen` reproduces that abort so the stale completion from
      // a discarded request can't land after reuse and clobber (or
      // prematurely complete) the new owner's bitmap.
      var gen = ++this._gen;
      // An object URL carries decrypted bytes rather than naming a file: it is
      // what the engines hand us for an encrypted asset, after decrypting it in
      // their own JavaScript. Nothing on disk answers to that name, so it is
      // decoded from the registry instead (see the Blob shim in mvjs.cxx).
      var h;
      if (typeof v === 'string' && v.lastIndexOf('blob:', 0) === 0 &&
          typeof g.__mv_blobBytes === 'function') {
        var bytes = g.__mv_blobBytes(v);
        h = bytes ? g.__mv_imageLoadBytes(bytes.buffer) : 0;
      } else {
        h = g.__mv_imageLoad(v);
      }
      g.requestAnimationFrame(function () {
        if (self._gen !== gen) return;
        // A missing or undecodable image resolves as a 1x1 transparent bitmap
        // (via onload), not an error. MV reserves system art (Window, IconSet,
        // …) and blocks on ImageManager.isReady() until it loads, so an absent
        // file would otherwise stall the boot forever. A project running
        // without its (optional) art still boots and reaches the map; the empty
        // bitmap draws nothing (drawImage clamps out-of-range source reads), so
        // e.g. a degenerate windowskin is invisible rather than fatal.
        if (!h) h = g.__mv_canvasCreate(1, 1);
        self.__h = h;
        self.width = g.__mv_canvasWidth(h);
        self.height = g.__mv_canvasHeight(h);
        self.complete = true;
        // Snapshot before dispatch: a listener may itself reassign `.onload`
        // (or call addEventListener again), which must not affect this fire.
        var listeners = self._loadListeners.slice();
        if (typeof self.onload === 'function') listeners.push(self.onload);
        for (var i = 0; i < listeners.length; i++) {
          try { listeners[i].call(self); } catch (e) { if (g.console) console.error(e); }
        }
      });
    },
  });
  ImageEl.prototype.addEventListener = function (type, cb) {
    if (typeof cb !== 'function') return;
    if (type === 'load') this._loadListeners.push(cb);
    else if (type === 'error') this._errorListeners.push(cb);
  };
  ImageEl.prototype.removeEventListener = function (type, cb) {
    var arr = type === 'load' ? this._loadListeners :
              type === 'error' ? this._errorListeners : null;
    if (!arr) return;
    var idx = arr.indexOf(cb);
    if (idx >= 0) arr.splice(idx, 1);
  };
  g.Image = ImageEl;
})(this);
)MVJS";

void install(JSContext* ctx,
             JSValue global,
             const char* name,
             JSCFunction* fn,
             int argc) {
  JS_SetPropertyStr(ctx, global, name, JS_NewCFunction(ctx, fn, name, argc));
}

}  // namespace

// Expose a canvas's RGBA buffer to the on-screen present path (mvjs.cxx). At
// file scope but still able to reach the anonymous-namespace registry above.
const uint8_t* mv_canvas_pixels(int handle, int* w, int* h) {
  Canvas* c = canvas_get(handle);
  if (!c)
    return nullptr;
  if (w)
    *w = c->w;
  if (h)
    *h = c->h;
  return c->px.data();
}

// Unpack `in` if it is a WOFF 1.0 font (magic "wOFF"), or pass it through
// unchanged otherwise (a bare sfnt, or anything else -- the caller finds out
// via stbtt_InitFont). At file scope so mvjs.cxx can reach the
// anonymous-namespace woff_to_sfnt for MV::Font.unpack_woff, which exists so
// the WOFF unpacker itself has CI coverage: it is exercised at load time by
// game_font() below, but that result is a process-lifetime cache (first text
// draw wins), so a test-authored font dropped in after another test has
// already drawn text is invisible to it.
bool mv_font_unpack(const std::string& in, std::string& out) {
  const std::vector<uint8_t> bytes(in.begin(), in.end());
  if (bytes.size() >= 4 && std::memcmp(bytes.data(), "wOFF", 4) == 0) {
    std::vector<uint8_t> sfnt;
    if (!woff_to_sfnt(bytes, sfnt))
      return false;
    out.assign(sfnt.begin(), sfnt.end());
    return true;
  }
  out = in;
  return true;
}

// Rasterise `codepoint` at `pixel` em size from font bytes given directly
// (WOFF or a bare sfnt), through a *fresh* stbtt_fontinfo -- independent of
// game_font()'s cached singleton, for the same reason mv_font_unpack exists.
// Sets *gw/*gh to the glyph bitmap size and *ink to its count of non-zero
// coverage pixels; false if the bytes do not parse as a font stb_truetype
// accepts.
bool mv_font_smoke_test(const std::string& in,
                        int codepoint,
                        double pixel,
                        int* gw,
                        int* gh,
                        int* ink) {
  std::string sfnt;
  if (!mv_font_unpack(in, sfnt))
    return false;
  stbtt_fontinfo info{};
  const uint8_t* data = reinterpret_cast<const uint8_t*>(sfnt.data());
  const int off = stbtt_GetFontOffsetForIndex(data, 0);
  if (off < 0 || !stbtt_InitFont(&info, data, off))
    return false;
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&info, static_cast<float>(pixel));
  int gxoff = 0, gyoff = 0;
  uint8_t* bmp = stbtt_GetCodepointBitmap(&info, scale, scale, codepoint, gw,
                                          gh, &gxoff, &gyoff);
  *ink = 0;
  if (bmp) {
    const size_t n = static_cast<size_t>(*gw) * static_cast<size_t>(*gh);
    for (size_t i = 0; i < n; ++i)
      if (bmp[i])
        ++*ink;
    stbtt_FreeBitmap(bmp, nullptr);
  }
  return true;
}

void mv_install_canvas(JSContext* ctx) {
  JSValue global = JS_GetGlobalObject(ctx);
  install(ctx, global, "__mv_canvasCreate", js_create, 2);
  install(ctx, global, "__mv_canvasResize", js_resize, 3);
  install(ctx, global, "__mv_canvasWidth", js_width, 1);
  install(ctx, global, "__mv_canvasHeight", js_height, 1);
  install(ctx, global, "__mv_canvasFillRect", js_fill_rect, 10);
  install(ctx, global, "__mv_canvasClearRect", js_clear_rect, 5);
  install(ctx, global, "__mv_canvasDrawImage", js_draw_image, 18);
  install(ctx, global, "__mv_canvasGetPixel", js_get_pixel, 3);
  install(ctx, global, "__mv_canvasPutData", js_put_data, 6);
  install(ctx, global, "__mv_canvasDrawText", js_draw_text, 17);
  install(ctx, global, "__mv_canvasFillGradient", js_fill_gradient, 15);
  install(ctx, global, "__mv_canvasFillPattern", js_fill_pattern, 13);
  install(ctx, global, "__mv_canvasFillPolygon", js_fill_polygon, 8);
  install(ctx, global, "__mv_fontMeasure", js_measure_text, 2);
  install(ctx, global, "__mv_setWindowTitle", js_set_window_title, 1);
  install(ctx, global, "__mv_imageLoad", js_image_load, 1);
  install(ctx, global, "__mv_imageLoadBytes", js_image_load_bytes, 1);
  JS_FreeValue(ctx, global);

  JSValue r = JS_Eval(ctx, kCanvasPreamble, std::strlen(kCanvasPreamble),
                      "<mv-canvas-preamble>", JS_EVAL_TYPE_GLOBAL);
  JS_FreeValue(ctx, r);
}

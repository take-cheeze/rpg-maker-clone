#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/string.h>
#include <mruby/value.h>
#include <mruby/variable.h>

#include <uni_algo/norm.h>
#include <uni_algo/ranges.h>
#include <uni_algo/ranges_conv.h>

#include <lvgl.h>

#include "default_font.hxx"
#include "profiler.hxx"
#include "shinonome.hxx"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <dirent.h>

#include <iostream>

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

// This is the single translation unit that compiles the stb_truetype
// implementation for the whole build. mruby-mvjs depends on this gem and only
// includes the header, so its glyph rasteriser (mvcanvas.cxx) resolves against
// the symbols emitted here — keep exactly one STB_TRUETYPE_IMPLEMENTATION.
#define STB_TRUETYPE_IMPLEMENTATION
#include <stb_truetype.h>

// Defined in terminal.cxx (same gem).  A no-op unless the game was started with
// a terminal backend (--sixel / --iterm); forwards terminal keyboard input to
// RGSS::Input.
extern "C" void rgss_terminal_poll(mrb_state* M);

// Defined in input_bridge.cxx (same gem).  A no-op unless the SDL window
// backend is active and has captured key events; drains them into RGSS::Input.
extern "C" void rgss_sdl_poll(mrb_state* M);

// Defined in input_bridge.cxx (same gem).  Buffers one already-translated key
// transition, the way the executable's SDL event watch does; exposed to Ruby as
// RGSS::Input._push so a headless test can drive an input frame.
extern "C" void rgss_sdl_input_push(int key, bool press);

// Defined in input_bridge.cxx (same gem).  The latest pointer state captured by
// the SDL backend (0 / not-pressed under the other backends); exposed to Ruby
// as RGSS.mouse_x / mouse_y / mouse_pressed? so MV's TouchInput bridge can read
// it.
extern "C" int rgss_mouse_x(void);
extern "C" int rgss_mouse_y(void);
extern "C" int rgss_mouse_pressed(void);

// Defined in audio.cxx (same gem).  Registers the native RGSS::Audio methods
// and drives the audio backend's per-frame work (a no-op when no backend is
// installed).
void rgss_audio_define(mrb_state* M, RClass* rgss);
extern "C" void rgss_audio_frame(void);

#if defined(WIO_TERMINAL)
// Defined in wio_input_bridge.cxx; scans the board's buttons/5-way switch and
// forwards press/release edges to RGSS::Input.  Guarded so the desktop/wasm
// builds, which do not compile the Wio backend, need no such symbol.
extern "C" void rgss_wio_poll(mrb_state* M);
#endif

#if defined(PSP_BUILD)
// Defined in psp_input_bridge.cxx; scans the PSP pad and forwards press/release
// edges to RGSS::Input.  Guarded so the desktop/wasm builds, which do not
// compile the PSP backend, need no such symbol.
extern "C" void rgss_psp_poll(mrb_state* M);
#endif

namespace {
// RGSS.default_font_path -> the bundled default UI font, or nil when none is
// installed (it is downloaded, not committed -- see assets/fonts/README.md).
// The makers whose text expects a TrueType face point RGSS::Font.default_path
// at this on boot; see font_default_path below for why that is opt-in.
mrb_value default_font_path_m(mrb_state* M, mrb_value self) {
  const std::string& path = rgss::default_font_path();
  return path.empty() ? mrb_nil_value()
                      : mrb_str_new(M, path.data(), path.size());
}

mrb_value to_nfd(mrb_state* M, mrb_value self) {
  const char* ptr;
  mrb_int len;
  mrb_get_args(M, "s", &ptr, &len);
  std::string nfd = una::norm::to_nfd_utf8(std::string_view(ptr, len));
  return mrb_str_new(M, nfd.data(), nfd.size());
}

// Inflate a zlib stream and return the decompressed bytes as a String. RGSS
// stores each Data/Scripts.rxdata section (and .xyz graphics) as a standard
// zlib stream (header byte 0x78); the RGSS script host (mruby-rpgxp) needs to
// decompress those sections before it can eval them. Reuses stb_image's zlib
// decoder -- already linked for PNG/XYZ loading -- so no extra dependency is
// pulled in. Falls back to a raw (headerless) DEFLATE decode the way load_xyz
// does, and raises RGSS::RGSSError when the stream cannot be inflated.
mrb_value zlib_inflate(mrb_state* M, mrb_value self) {
  const char* ptr;
  mrb_int len;
  mrb_get_args(M, "s", &ptr, &len);
  int outlen = 0;
  char* raw = stbi_zlib_decode_malloc(ptr, (int)len, &outlen);
  if (!raw)
    raw = stbi_zlib_decode_noheader_malloc(ptr, (int)len, &outlen);
  if (!raw)
    mrb_raisef(M,
               mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "RGSSError"),
               "zlib inflate failed: %s", stbi_failure_reason());
  mrb_value out = mrb_str_new(M, raw, outlen < 0 ? 0 : outlen);
  stbi_image_free(raw);
  return out;
}

using V = ::mrb_value;

double clamp255(double v) {
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

double clamp_signed255(double v) {
  return v < -255 ? -255 : (v > 255 ? 255 : v);
}

struct Rect {
  mrb_int x{0}, y{0}, width{0}, height{0};
};

// RGSS Color: floating point RGBA components in the range 0..255.
struct Color {
  double red{0}, green{0}, blue{0}, alpha{255};
};

// RGSS Tone: red/green/blue in -255..255 and gray in 0..255.
struct Tone {
  double red{0}, green{0}, blue{0}, gray{0};
};

// RGSS Table: 1..3 dimensional array of 16bit integers used for map data.
struct Table {
  int32_t dim{1};
  int32_t xsize{0}, ysize{1}, zsize{1};
  std::vector<int16_t> data;
};

struct Bitmap {
  int32_t width, height;
  lv_color_format_t format;
  std::vector<uint8_t> buffer;
  // Set whenever `buffer` is mutated so Graphics.update can invalidate the
  // sprites showing this bitmap and have LVGL redraw them. Starts true so the
  // initial contents are painted on the first frame after assignment.
  bool dirty = true;

  Bitmap(mrb_int w, mrb_int h, lv_color_format_t f)
      : width(w),
        height(h),
        format(f),
        buffer(w * h * lv_color_format_get_size(f)) {}
};

template <class T>
struct DataType {
  static void free_obj(mrb_state* M, void* p) {
    if (!p)
      return;

    std::destroy_at(reinterpret_cast<T*>(p));
    mrb_free(M, p);
  }

  static mrb_data_type data_type;

  template <class... Args>
  static T& alloc_obj(mrb_state* M, V self, Args... args) {
    mrb_assert(!DATA_PTR(self));
    void* mem_ptr = mrb_malloc(M, sizeof(T));
    T* ptr = new (mem_ptr) T{args...};
    mrb_data_init(self, ptr, &data_type);
    return *ptr;
  }

  // Allocate a brand new instance of class `c` wrapping a freshly constructed
  // T. Used by the Marshal `_load` class methods which receive the class and
  // must return a populated object.
  template <class... Args>
  static V make(mrb_state* M, RClass* c, Args... args) {
    void* mem_ptr = mrb_malloc(M, sizeof(T));
    T* ptr = new (mem_ptr) T{args...};
    return mrb_obj_value(mrb_data_object_alloc(M, c, ptr, &data_type));
  }

  static T& get(mrb_state* M, V self) {
    return *reinterpret_cast<T*>(mrb_data_get_ptr(M, self, &data_type));
  }
};

template <class T>
mrb_data_type DataType<T>::data_type{
    typeid(T).name(),
    &DataType<T>::free_obj,
};

// Generic floating point component getter/setter usable by Color and Tone.
template <class T, double T::* Field>
mrb_value component_get(mrb_state* M, V self) {
  return mrb_float_value(M, DataType<T>::get(M, self).*Field);
}

template <class T, double T::* Field, int Lo, int Hi>
mrb_value component_set(mrb_state* M, V self) {
  mrb_float v;
  mrb_get_args(M, "f", &v);
  if (v < Lo)
    v = Lo;
  if (v > Hi)
    v = Hi;
  DataType<T>::get(M, self).*Field = v;
  return mrb_float_value(M, v);
}

std::string pack_doubles(std::initializer_list<double> vals) {
  std::string s;
  s.reserve(vals.size() * sizeof(double));
  for (double v : vals) {
    char buf[sizeof(double)];
    std::memcpy(buf, &v, sizeof(double));
    s.append(buf, sizeof(double));
  }
  return s;
}

void unpack_doubles(const char* p, mrb_int len, double* out, int n) {
  for (int i = 0; i < n; ++i) {
    if ((mrb_int)((i + 1) * sizeof(double)) <= len)
      std::memcpy(&out[i], p + i * sizeof(double), sizeof(double));
  }
}

// ---- Color ----------------------------------------------------------------

mrb_value color_init(mrb_state* M, V self) {
  mrb_float r = 0, g = 0, b = 0, a = 255;
  mrb_get_args(M, "fff|f", &r, &g, &b, &a);
  Color& c = DataType<Color>::alloc_obj(M, self);
  c.red = clamp255(r);
  c.green = clamp255(g);
  c.blue = clamp255(b);
  c.alpha = clamp255(a);
  return self;
}

mrb_value color_set(mrb_state* M, V self) {
  Color& c = DataType<Color>::get(M, self);
  if (mrb_get_argc(M) == 1) {
    V o;
    mrb_get_args(M, "o", &o);
    c = DataType<Color>::get(M, o);
  } else {
    mrb_float r, g, b, a = 255;
    mrb_get_args(M, "fff|f", &r, &g, &b, &a);
    c.red = clamp255(r);
    c.green = clamp255(g);
    c.blue = clamp255(b);
    c.alpha = clamp255(a);
  }
  return self;
}

mrb_value color_eq(mrb_state* M, V self) {
  V o;
  mrb_get_args(M, "o", &o);
  if (!mrb_obj_is_kind_of(M, o, mrb_class(M, self)))
    return mrb_false_value();
  Color& a = DataType<Color>::get(M, self);
  Color& b = DataType<Color>::get(M, o);
  return mrb_bool_value(a.red == b.red && a.green == b.green &&
                        a.blue == b.blue && a.alpha == b.alpha);
}

mrb_value color_to_s(mrb_state* M, V self) {
  Color& c = DataType<Color>::get(M, self);
  char buf[128];
  std::snprintf(buf, sizeof(buf), "(%g, %g, %g, %g)", c.red, c.green, c.blue,
                c.alpha);
  return mrb_str_new_cstr(M, buf);
}

mrb_value color_dump(mrb_state* M, V self) {
  Color& c = DataType<Color>::get(M, self);
  std::string s = pack_doubles({c.red, c.green, c.blue, c.alpha});
  return mrb_str_new(M, s.data(), s.size());
}

mrb_value color_load(mrb_state* M, V self) {
  const char* p;
  mrb_int len;
  mrb_get_args(M, "s", &p, &len);
  double d[4] = {0, 0, 0, 255};
  unpack_doubles(p, len, d, 4);
  V obj = DataType<Color>::make(M, mrb_class_ptr(self));
  Color& c = DataType<Color>::get(M, obj);
  c.red = d[0];
  c.green = d[1];
  c.blue = d[2];
  c.alpha = d[3];
  return obj;
}

// ---- Tone -----------------------------------------------------------------

mrb_value tone_init(mrb_state* M, V self) {
  mrb_float r = 0, g = 0, b = 0, gray = 0;
  mrb_get_args(M, "fff|f", &r, &g, &b, &gray);
  Tone& t = DataType<Tone>::alloc_obj(M, self);
  t.red = clamp_signed255(r);
  t.green = clamp_signed255(g);
  t.blue = clamp_signed255(b);
  t.gray = clamp255(gray);
  return self;
}

mrb_value tone_set(mrb_state* M, V self) {
  Tone& t = DataType<Tone>::get(M, self);
  if (mrb_get_argc(M) == 1) {
    V o;
    mrb_get_args(M, "o", &o);
    t = DataType<Tone>::get(M, o);
  } else {
    mrb_float r, g, b, gray = 0;
    mrb_get_args(M, "fff|f", &r, &g, &b, &gray);
    t.red = clamp_signed255(r);
    t.green = clamp_signed255(g);
    t.blue = clamp_signed255(b);
    t.gray = clamp255(gray);
  }
  return self;
}

mrb_value tone_eq(mrb_state* M, V self) {
  V o;
  mrb_get_args(M, "o", &o);
  if (!mrb_obj_is_kind_of(M, o, mrb_class(M, self)))
    return mrb_false_value();
  Tone& a = DataType<Tone>::get(M, self);
  Tone& b = DataType<Tone>::get(M, o);
  return mrb_bool_value(a.red == b.red && a.green == b.green &&
                        a.blue == b.blue && a.gray == b.gray);
}

mrb_value tone_to_s(mrb_state* M, V self) {
  Tone& t = DataType<Tone>::get(M, self);
  char buf[128];
  std::snprintf(buf, sizeof(buf), "(%g, %g, %g, %g)", t.red, t.green, t.blue,
                t.gray);
  return mrb_str_new_cstr(M, buf);
}

mrb_value tone_dump(mrb_state* M, V self) {
  Tone& t = DataType<Tone>::get(M, self);
  std::string s = pack_doubles({t.red, t.green, t.blue, t.gray});
  return mrb_str_new(M, s.data(), s.size());
}

mrb_value tone_load(mrb_state* M, V self) {
  const char* p;
  mrb_int len;
  mrb_get_args(M, "s", &p, &len);
  double d[4] = {0, 0, 0, 0};
  unpack_doubles(p, len, d, 4);
  V obj = DataType<Tone>::make(M, mrb_class_ptr(self));
  Tone& t = DataType<Tone>::get(M, obj);
  t.red = d[0];
  t.green = d[1];
  t.blue = d[2];
  t.gray = d[3];
  return obj;
}

// ---- Table ----------------------------------------------------------------

long table_index(const Table& t, mrb_int x, mrb_int y, mrb_int z) {
  if (x < 0 || x >= t.xsize || y < 0 || y >= t.ysize || z < 0 || z >= t.zsize)
    return -1;
  return x + y * (long)t.xsize + z * (long)t.xsize * t.ysize;
}

mrb_value table_init(mrb_state* M, V self) {
  mrb_int a, b = 1, c = 1;
  mrb_get_args(M, "i|ii", &a, &b, &c);
  mrb_int argc = mrb_get_argc(M);
  Table& t = DataType<Table>::alloc_obj(M, self);
  t.dim = argc;
  t.xsize = a;
  t.ysize = argc >= 2 ? b : 1;
  t.zsize = argc >= 3 ? c : 1;
  t.data.assign((size_t)t.xsize * t.ysize * t.zsize, 0);
  return self;
}

mrb_value table_get(mrb_state* M, V self) {
  mrb_int x, y = 0, z = 0;
  mrb_get_args(M, "i|ii", &x, &y, &z);
  Table& t = DataType<Table>::get(M, self);
  long i = table_index(t, x, y, z);
  if (i < 0)
    return mrb_nil_value();
  return mrb_fixnum_value(t.data[i]);
}

// A write outside the table is dropped, and the value is only converted once it
// is going to be stored. The order matters, because a game's own scripts lean
// on it: Pray for You's `map_light` walks `for x in 0..(self.width)` —
// inclusive, so one past the edge — and does `@passages_data[x, y] |= 0x0f`. At
// the edge the read answers nil, `nil | 0x0f` is `true`, and that `true` comes
// back here as the value of a write RGSS was always going to ignore. Converting
// the arguments up front (mrb_get_args "ii|ii") raised "TypeError: true cannot
// be converted to Integer" instead, which killed the game on New Game. An
// *in-range* write of a non-Integer still raises, as it should.
mrb_value table_set(mrb_state* M, V self) {
  mrb_value a0, a1, a2 = mrb_nil_value(), a3 = mrb_nil_value();
  mrb_get_args(M, "oo|oo", &a0, &a1, &a2, &a3);
  const mrb_int argc = mrb_get_argc(M);
  mrb_int x = mrb_as_int(M, a0), y = 0, z = 0;
  mrb_value v;
  if (argc == 2) {
    v = a1;
  } else if (argc == 3) {
    y = mrb_as_int(M, a1);
    v = a2;
  } else {
    y = mrb_as_int(M, a1);
    z = mrb_as_int(M, a2);
    v = a3;
  }
  Table& t = DataType<Table>::get(M, self);
  const long i = table_index(t, x, y, z);
  if (i < 0)
    return v;
  t.data[i] = (int16_t)mrb_as_int(M, v);
  return v;
}

mrb_value table_resize(mrb_state* M, V self) {
  mrb_int a, b = 1, c = 1;
  mrb_get_args(M, "i|ii", &a, &b, &c);
  mrb_int argc = mrb_get_argc(M);
  Table& t = DataType<Table>::get(M, self);
  int32_t nx = a, ny = argc >= 2 ? b : 1, nz = argc >= 3 ? c : 1;
  std::vector<int16_t> nd((size_t)nx * ny * nz, 0);
  for (int32_t z = 0; z < std::min(nz, t.zsize); ++z)
    for (int32_t y = 0; y < std::min(ny, t.ysize); ++y)
      for (int32_t x = 0; x < std::min(nx, t.xsize); ++x)
        nd[x + y * (long)nx + z * (long)nx * ny] =
            t.data[x + y * (long)t.xsize + z * (long)t.xsize * t.ysize];
  t.dim = argc;
  t.xsize = nx;
  t.ysize = ny;
  t.zsize = nz;
  t.data = std::move(nd);
  return self;
}

mrb_value table_dump(mrb_state* M, V self) {
  Table& t = DataType<Table>::get(M, self);
  std::string s;
  auto put32 = [&s](uint32_t v) {
    char b[4];
    std::memcpy(b, &v, 4);
    s.append(b, 4);
  };
  put32(t.dim);
  put32(t.xsize);
  put32(t.ysize);
  put32(t.zsize);
  put32((uint32_t)t.data.size());
  for (int16_t v : t.data) {
    char b[2];
    std::memcpy(b, &v, 2);
    s.append(b, 2);
  }
  return mrb_str_new(M, s.data(), s.size());
}

mrb_value table_load(mrb_state* M, V self) {
  const char* p;
  mrb_int len;
  mrb_get_args(M, "s", &p, &len);
  auto get32 = [p, len](mrb_int off) -> uint32_t {
    uint32_t v = 0;
    if (off + 4 <= len)
      std::memcpy(&v, p + off, 4);
    return v;
  };
  V obj = DataType<Table>::make(M, mrb_class_ptr(self));
  Table& t = DataType<Table>::get(M, obj);
  t.dim = get32(0);
  t.xsize = get32(4);
  t.ysize = get32(8);
  t.zsize = get32(12);
  uint32_t count = get32(16);
  t.data.assign(count, 0);
  for (uint32_t i = 0; i < count; ++i) {
    int16_t v = 0;
    mrb_int off = 20 + (mrb_int)i * 2;
    if (off + 2 <= len)
      std::memcpy(&v, p + off, 2);
    t.data[i] = v;
  }
  return obj;
}

// ---- Bitmap ---------------------------------------------------------------

// Human-readable diagnostic for the most recent Bitmap load that reached (and
// failed inside) a real decoder. Exposed to Ruby via `Bitmap._load_error` so a
// failed windowskin/graphic load can report exactly which decoder gave up and
// why -- e.g. stb's "bad dist" on a corrupt/non-standard XYZ zlib stream --
// instead of a bare "Failed to init bitmap". Left untouched by plain
// file-not-found probes so the informative message survives the loader's
// subsequent extension attempts.
static std::string g_bitmap_load_error;

static void set_bitmap_load_error(const char* fmt, ...) {
  char buf[512];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  g_bitmap_load_error = buf;
}

// Decode an RPG Maker 2000/2003 XYZ image. The format is a tiny header
//
//   "XYZ1"                     4-byte magic
//   uint16 LE width, height    picture dimensions
//   zlib stream                768-byte RGB palette + width*height indices
//
// which stb_image does not understand, so games that ship their System
// (windowskin) or other graphics as .xyz would otherwise fail to load. On
// success returns a freshly stb-allocated buffer (free with stbi_image_free)
// of width*height*4 bytes in LVGL's B, G, R, A byte order and sets *w/*h/*c;
// returns nullptr when the bytes are not an XYZ image. When `trans` is set the
// first palette entry is treated as the transparent colour, matching stb's
// transparent-palette handling for PNGs.
//
// Takes the bytes rather than a path so the same decoder serves a loose file
// and an entry pulled out of an encrypted RGSSAD archive; `label` only names
// the source in the diagnostics.
static uint8_t* load_xyz_mem(const uint8_t* data,
                             size_t sz,
                             const char* label,
                             int* w,
                             int* h,
                             int* c,
                             bool trans) {
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
  const uint8_t* pal = reinterpret_cast<const uint8_t*>(raw);
  const uint8_t* idx = pal + 768;

  uint8_t* out = (uint8_t*)stbi__malloc((size_t)width * height * 4);
  if (!out) {
    stbi_image_free(raw);
    return nullptr;
  }
  for (int i = 0; i < width * height; ++i) {
    const uint8_t p = idx[i];
    out[i * 4 + 0] = pal[p * 3 + 2];               // B
    out[i * 4 + 1] = pal[p * 3 + 1];               // G
    out[i * 4 + 2] = pal[p * 3 + 0];               // R
    out[i * 4 + 3] = (trans && p == 0) ? 0 : 255;  // A
  }
  stbi_image_free(raw);
  *w = width;
  *h = height;
  *c = 4;
  return out;
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

}  // namespace png_tol

// Decode `d` as a PNG using the tolerant inflater above. Returns a freshly
// stb-allocated (free with stbi_image_free) width*height*4 B, G, R, A buffer
// and sets *w/*h/*c, or nullptr when the bytes are not a PNG this fallback
// handles (non-interlaced; bit depth 8, or indexed 1/2/4). `trans` maps palette
// index 0 to transparent, matching the primary loader's colour-key handling.
//
// Takes the bytes rather than a path, like load_xyz_mem above, so an entry read
// out of an encrypted RGSSAD archive gets the same fallback a loose file does;
// `label` only names the source in the diagnostics.
static uint8_t* load_png_tolerant_mem(const uint8_t* d,
                                      size_t sz,
                                      const char* label,
                                      int* wout,
                                      int* hout,
                                      int* c,
                                      bool trans) {
  static const uint8_t sig[8] = {0x89, 0x50, 0x4e, 0x47,
                                 0x0d, 0x0a, 0x1a, 0x0a};
  if (sz < 8 || std::memcmp(d, sig, 8) != 0)
    return nullptr;

  int w = 0, h = 0, depth = 0, ct = 0, interlace = 0;
  std::vector<uint8_t> idat, plte, trns;
  size_t i = 8;
  while (i + 8 <= sz) {
    const uint32_t len = png_tol::be32(d + i);
    const uint8_t* typ = d + i + 4;
    const uint8_t* body = d + i + 8;
    if (i + 12 + len > sz)
      break;
    if (!std::memcmp(typ, "IHDR", 4) && len >= 13) {
      w = (int)png_tol::be32(body);
      h = (int)png_tol::be32(body + 4);
      depth = body[8];
      ct = body[9];
      interlace = body[12];
    } else if (!std::memcmp(typ, "IDAT", 4)) {
      idat.insert(idat.end(), body, body + len);
    } else if (!std::memcmp(typ, "PLTE", 4)) {
      plte.assign(body, body + len);
    } else if (!std::memcmp(typ, "tRNS", 4)) {
      trns.assign(body, body + len);
    } else if (!std::memcmp(typ, "IEND", 4)) {
      break;
    }
    i += 12 + len;
  }
  if (w <= 0 || h <= 0 || interlace != 0)
    return nullptr;
  if (depth != 8 && !(ct == 3 && (depth == 1 || depth == 2 || depth == 4)))
    return nullptr;
  int channels;
  switch (ct) {
    case 0:
      channels = 1;
      break;
    case 2:
      channels = 3;
      break;
    case 3:
      channels = 1;
      break;
    case 4:
      channels = 2;
      break;
    case 6:
      channels = 4;
      break;
    default:
      return nullptr;
  }
  if (ct == 3 && plte.size() < 3)
    return nullptr;

  const size_t rowbytes = ((size_t)w * channels * depth + 7) / 8;
  int bpp = (channels * depth + 7) / 8;
  if (bpp < 1)
    bpp = 1;
  std::vector<uint8_t> filt((rowbytes + 1) * (size_t)h, 0);
  const long need = (long)((rowbytes + 1) * (size_t)h);
  if (png_tol::inflate_tolerant(idat.data(), idat.size(), filt) < need) {
    set_bitmap_load_error(
        "PNG %dx%d depth %d colortype %d '%s': tolerant inflate produced too "
        "little data",
        w, h, depth, ct, label);
    return nullptr;
  }

  // Reverse the per-scanline filters in place.
  std::vector<uint8_t> raw((size_t)rowbytes * h);
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
          v += png_tol::paeth(a, b, cc);
          break;
        default:
          break;
      }
      cur[x] = (uint8_t)v;
    }
    std::memcpy(prev.data(), cur, rowbytes);
  }

  uint8_t* out = (uint8_t*)stbi__malloc((size_t)w * h * 4);
  if (!out)
    return nullptr;
  auto set = [&](int px, int R, int G, int B, int A) {
    out[px * 4 + 0] = (uint8_t)B;
    out[px * 4 + 1] = (uint8_t)G;
    out[px * 4 + 2] = (uint8_t)R;
    out[px * 4 + 3] = (uint8_t)A;
  };
  const int palcount = (int)(plte.size() / 3);
  for (int y = 0; y < h; y++) {
    const uint8_t* row = &raw[(size_t)rowbytes * y];
    for (int x = 0; x < w; x++) {
      const int px = y * w + x;
      if (ct == 3) {
        int idx;
        if (depth == 8) {
          idx = row[x];
        } else {
          const int per = 8 / depth;
          const int shift = (per - 1 - (x % per)) * depth;
          idx = (row[x / per] >> shift) & ((1 << depth) - 1);
        }
        if (idx >= palcount)
          idx = palcount ? palcount - 1 : 0;
        int A = 255;
        if (trans && idx == 0)
          A = 0;
        if ((size_t)idx < trns.size())
          A = trns[idx];
        set(px, plte[idx * 3], plte[idx * 3 + 1], plte[idx * 3 + 2], A);
      } else if (ct == 2) {
        set(px, row[x * 3], row[x * 3 + 1], row[x * 3 + 2], 255);
      } else if (ct == 6) {
        set(px, row[x * 4], row[x * 4 + 1], row[x * 4 + 2], row[x * 4 + 3]);
      } else if (ct == 0) {
        const int g = row[x];
        set(px, g, g, g, 255);
      } else {  // ct == 4, grayscale + alpha
        const int g = row[x * 2];
        set(px, g, g, g, row[x * 2 + 1]);
      }
    }
  }
  *wout = w;
  *hout = h;
  *c = 4;
  return out;
}

// Ruby: Bitmap._load_error -> the detailed diagnostic set by the last decoder
// that opened a file and failed inside it (see g_bitmap_load_error).
mrb_value bmp_load_error(mrb_state* M, V self) {
  (void)self;
  return mrb_str_new_cstr(M, g_bitmap_load_error.c_str());
}

// Ruby: Bitmap._stbi_error -> stb_image's raw failure reason for the most
// recent decode attempt (e.g. "bad dist", "unknown image type").
mrb_value bmp_stbi_error(mrb_state* M, V self) {
  (void)self;
  const char* r = stbi_failure_reason();
  return mrb_str_new_cstr(M, r ? r : "");
}

mrb_value bmp_init_size(mrb_state* M, mrb_value self) {
  mrb_int w, h;
  mrb_get_args(M, "ii", &w, &h);

  DataType<Bitmap>::alloc_obj(M, self, w, h, LV_COLOR_FORMAT_ARGB8888);
  return self;
}

// Read a whole file. Answers false when it cannot be opened or read fully, so
// the caller can fall through to the next candidate path in silence.
static bool slurp_file(const char* f, std::vector<uint8_t>& out) {
  std::FILE* fp = std::fopen(f, "rb");
  if (!fp)
    return false;
  std::fseek(fp, 0, SEEK_END);
  const long sz = std::ftell(fp);
  std::fseek(fp, 0, SEEK_SET);
  if (sz <= 0) {
    std::fclose(fp);
    return false;
  }
  out.resize((size_t)sz);
  const size_t got = std::fread(out.data(), 1, (size_t)sz, fp);
  std::fclose(fp);
  return got == (size_t)sz;
}

// Decode image bytes into `self` (a Bitmap). Shared by Bitmap#_init_file and
// #_init_memory: everything below is format work with no notion of where the
// bytes came from, which is what lets an entry pulled out of an encrypted
// RGSSAD archive go through the exact same decoders — stb, then the XYZ and
// tolerant-PNG fallbacks — as a loose file. `label` only names the source in
// the diagnostics. Answers false when nothing could decode it.
static bool bmp_decode_into(mrb_state* M,
                            mrb_value self,
                            const uint8_t* data,
                            size_t size,
                            const char* label,
                            bool trans) {
  int w, h, c;
  stbi__png_transparent_palette = trans;
  // Every loader here hands back LVGL's B, G, R(, A) byte order (see
  // load_xyz_mem and load_png_tolerant_mem, which build it themselves). stb
  // decodes to R, G, B(, A), so its output is swapped below instead of relying
  // on the vendored palette-only BGR hack: that covered indexed PNGs (all an
  // RPG2000 project has) and left every truecolour PNG and every JPEG with red
  // and blue exchanged -- which is what an RPG Maker XP RTP is full of. Caught
  // by diffing against the genuine RGSS runtime, see
  // docs/adr/0025-rpgxp-cross-runtime-testing.md.
  stbi__png_to_bgr_palette = false;
  // The channel count has to be decided before decoding, because the bitmap's
  // pixel format must follow what we *ask* stb for. It used to follow the
  // file's own channel count instead, so an RGBA image loaded without `trans`
  // allocated a 4-byte-per-pixel bitmap and filled it from 3-channel data --
  // reading past the decoded buffer and drawing garbage. An XP windowskin
  // (truecolour + alpha, loaded opaque) hit exactly that.
  int probe_w = 0, probe_h = 0, probe_c = 0;
  const bool has_alpha =
      stbi_info_from_memory(data, (int)size, &probe_w, &probe_h, &probe_c) &&
      probe_c == 4;
  const int req = (trans || has_alpha) ? 4 : 3;
  // Whether the pixels came from stb (R, G, B order, so they need the swap) or
  // from one of the fallbacks above, which already emit LVGL's order.
  bool from_stb = true;
  std::shared_ptr<uint8_t> img(
      stbi_load_from_memory(data, (int)size, &w, &h, &c, req), stbi_image_free);
  if (!img) {
    from_stb = false;
    img.reset(load_xyz_mem(data, size, label, &w, &h, &c, trans),
              stbi_image_free);
  }
  // stb_image rejects some valid-enough PNGs (e.g. RPG Maker windowskins whose
  // deflate stream references a zero pre-history, giving "bad dist"); retry
  // with the tolerant PNG decoder before giving up.
  if (!img)
    img.reset(load_png_tolerant_mem(data, size, label, &w, &h, &c, trans),
              stbi_image_free);
  if (!img)
    return false;
  // The fallbacks always produce 4 channels; stb produced exactly what was
  // requested.
  const int channels = from_stb ? req : 4;
  Bitmap& bmp = DataType<Bitmap>::alloc_obj(
      M, self, w, h,
      channels == 4 ? LV_COLOR_FORMAT_ARGB8888 : LV_COLOR_FORMAT_RGB888);
  std::memcpy(bmp.buffer.data(), img.get(), bmp.buffer.size());
  if (from_stb) {
    uint8_t* p = bmp.buffer.data();
    for (size_t i = 0; i + 3 <= bmp.buffer.size(); i += (size_t)channels)
      std::swap(p[i], p[i + 2]);
  }
  return true;
}

mrb_value bmp_init_file(mrb_state* M, mrb_value self) {
  const char* f;
  mrb_bool trans = false;
  mrb_get_args(M, "z|b", &f, &trans);
  std::vector<uint8_t> data;
  if (slurp_file(f, data) &&
      bmp_decode_into(M, self, data.data(), data.size(), f, trans))
    return self;
  // Some archives store filenames in NFD form while the game data refers to
  // them in NFC (or vice versa); retry with the decomposed form before giving
  // up so accented paths still resolve.
  const std::string nfd_f = una::norm::to_nfd_utf8(f);
  if (nfd_f != f && slurp_file(nfd_f.c_str(), data) &&
      bmp_decode_into(M, self, data.data(), data.size(), nfd_f.c_str(), trans))
    return self;
  return mrb_nil_value();
}

// Ruby: Bitmap#_init_memory(bytes, transparent = false) -> self or nil.
//
// The same decode as #_init_file over bytes already in hand. RGSS's Cache
// asks for every asset by name (`Bitmap.new("Graphics/Titles/...")`), and a
// released game packs those names into its encrypted Game.rgssad / .rgss2a /
// .rgss3a with nothing loose on disk — so the Ruby loader falls back to the
// archive and hands the decrypted bytes here.
mrb_value bmp_init_memory(mrb_state* M, mrb_value self) {
  const char* data;
  mrb_int size;
  mrb_bool trans = false;
  mrb_get_args(M, "s|b", &data, &size, &trans);
  if (size <= 0)
    return mrb_nil_value();
  if (!bmp_decode_into(M, self, reinterpret_cast<const uint8_t*>(data),
                       (size_t)size, "<archive entry>", trans))
    return mrb_nil_value();
  return self;
}

Bitmap& bmp_self(mrb_state* M, V self) {
  return DataType<Bitmap>::get(M, self);
}

// Write an RGBA color into the bitmap at (x, y). LVGL stores ARGB8888 as
// B, G, R, A bytes (and RGB888 as B, G, R), matching how images are loaded.
void bmp_put(Bitmap& b,
             mrb_int x,
             mrb_int y,
             double r,
             double g,
             double bl,
             double a) {
  if (x < 0 || y < 0 || x >= b.width || y >= b.height)
    return;
  const unsigned bpp = lv_color_format_get_size(b.format);
  uint8_t* p = b.buffer.data() + ((size_t)y * b.width + x) * bpp;
  p[0] = (uint8_t)bl;
  p[1] = (uint8_t)g;
  p[2] = (uint8_t)r;
  if (bpp >= 4)
    p[3] = (uint8_t)a;
}

void bmp_read(const Bitmap& b,
              mrb_int x,
              mrb_int y,
              int& r,
              int& g,
              int& bl,
              int& a) {
  const unsigned bpp = lv_color_format_get_size(b.format);
  const uint8_t* p = b.buffer.data() + ((size_t)y * b.width + x) * bpp;
  bl = p[0];
  g = p[1];
  r = p[2];
  a = bpp >= 4 ? p[3] : 255;
}

// Source-over composite of one pixel in *straight* (non-premultiplied) alpha.
//
// The obvious `src*a + dst*(255-a)` is only right when the destination is
// opaque. Onto a transparent pixel -- which is transparent *black* -- it drags
// the colour toward black while recording alpha `a`, so the composite that
// later draws the bitmap over the screen attenuates the same colour a second
// time. A window background blitted at RGSS's `back_opacity` 160 came out
// showing 8% of its skin instead of 63% (measured against the genuine RGSS
// runtime, which blends at exactly back_opacity/255).
//
// Straight alpha keeps the colour and lets the alpha carry the coverage:
//   out_a   = sa + da*(1 - sa)
//   out_rgb = (src*sa + dst*da*(1 - sa)) / out_a
// which reduces to the old formula when da is 255, so blits onto an opaque
// bitmap are unchanged.
void blend_over(Bitmap& dst,
                mrb_int x,
                mrb_int y,
                int r,
                int g,
                int b,
                int sa,
                int dr,
                int dg,
                int db,
                int da) {
  const int dw = da * (255 - sa) / 255;
  const int out_a = sa + dw;
  if (out_a <= 0)
    return;
  bmp_put(dst, x, y, (r * sa + dr * dw) / out_a, (g * sa + dg * dw) / out_a,
          (b * sa + db * dw) / out_a, out_a);
}

mrb_value bmp_width(mrb_state* M, V self) {
  return mrb_fixnum_value(bmp_self(M, self).width);
}

mrb_value bmp_height(mrb_state* M, V self) {
  return mrb_fixnum_value(bmp_self(M, self).height);
}

mrb_value bmp_rect(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  const V args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                    mrb_fixnum_value(b.width), mrb_fixnum_value(b.height)};
  return mrb_obj_new(
      M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Rect"), 4, args);
}

mrb_value bmp_clear(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  std::fill(b.buffer.begin(), b.buffer.end(), 0);
  b.dirty = true;
  return self;
}

mrb_value bmp_fill_rect(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int x, y, w, h;
  V col;
  if (mrb_get_argc(M) <= 2) {
    V r;
    mrb_get_args(M, "oo", &r, &col);
    Rect& rc = DataType<Rect>::get(M, r);
    x = rc.x;
    y = rc.y;
    w = rc.width;
    h = rc.height;
  } else {
    mrb_get_args(M, "iiiio", &x, &y, &w, &h, &col);
  }
  Color& c = DataType<Color>::get(M, col);
  for (mrb_int j = y; j < y + h; ++j)
    for (mrb_int i = x; i < x + w; ++i)
      bmp_put(b, i, j, c.red, c.green, c.blue, c.alpha);
  b.dirty = true;
  return self;
}

int clamp_channel(int v) {
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

// RGSS Bitmap#tone_blt(src, tone): copy `src` into this bitmap, same size,
// applying an RGSS Tone.
//
// A tone is *not* a colour drawn on top -- it rescales what is already there,
// which is why it cannot be done the way the screen fade and flash are (a solid
// sprite composited at some opacity). Hence a real pixel pass.
//
// RGSS order, which RPG2000's Tint Screen reduces to: desaturate toward
// luminance by `gray` (0..255), then add the per-channel offsets (-255..255).
// Luminance uses the usual 299/587/114 weights. Alpha is copied untouched: a
// tone tints what is visible, it does not make anything more or less so.
//
// It writes into a separate destination rather than transforming in place
// because the caller redraws its layers only when they change; toning in place
// would re-tone an already-toned layer every frame and march it to black.
mrb_value bmp_tone_blt(mrb_state* M, V self) {
  Bitmap& dst = bmp_self(M, self);
  V src_v, tone_v;
  mrb_get_args(M, "oo", &src_v, &tone_v);
  Bitmap& src = DataType<Bitmap>::get(M, src_v);
  Tone& t = DataType<Tone>::get(M, tone_v);

  if (src.width != dst.width || src.height != dst.height) {
    RClass* mod = mrb_module_get(M, "RGSS");
    RClass* err = mrb_class_get_under(M, mod, "RGSSError");
    mrb_raisef(M, err, "tone_blt: size mismatch (self %dx%d, src %dx%d)",
               dst.width, dst.height, src.width, src.height);
  }

  const int tr = (int)t.red;
  const int tg = (int)t.green;
  const int tb = (int)t.blue;
  const int gray = (int)t.gray;
  for (int32_t y = 0; y < src.height; ++y) {
    for (int32_t x = 0; x < src.width; ++x) {
      int r, g, b, a;
      bmp_read(src, x, y, r, g, b, a);
      if (gray > 0) {
        const int lum = (r * 299 + g * 587 + b * 114) / 1000;
        r += (lum - r) * gray / 255;
        g += (lum - g) * gray / 255;
        b += (lum - b) * gray / 255;
      }
      r = clamp_channel(r + tr);
      g = clamp_channel(g + tg);
      b = clamp_channel(b + tb);
      bmp_put(dst, x, y, r, g, b, a);
    }
  }
  dst.dirty = true;
  return self;
}

// RGSS Bitmap#gradient_fill_rect(rect, color1, color2, vertical=false) or
// (x, y, width, height, color1, color2, vertical=false): fill the rect with a
// linear gradient from color1 to color2, left-to-right (or top-to-bottom when
// vertical). Like fill_rect, it overwrites the pixels (colour + alpha).
mrb_value bmp_gradient_fill_rect(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int x, y, w, h;
  V col1, col2;
  mrb_bool vertical = false;
  if (mrb_get_argc(M) <= 4) {
    V r;
    mrb_get_args(M, "ooo|b", &r, &col1, &col2, &vertical);
    Rect& rc = DataType<Rect>::get(M, r);
    x = rc.x;
    y = rc.y;
    w = rc.width;
    h = rc.height;
  } else {
    mrb_get_args(M, "iiiioo|b", &x, &y, &w, &h, &col1, &col2, &vertical);
  }
  Color& c1 = DataType<Color>::get(M, col1);
  Color& c2 = DataType<Color>::get(M, col2);
  const mrb_int span = vertical ? h : w;
  for (mrb_int j = y; j < y + h; ++j) {
    for (mrb_int i = x; i < x + w; ++i) {
      const mrb_int pos = vertical ? (j - y) : (i - x);
      const double t = span > 1 ? static_cast<double>(pos) / (span - 1) : 0.0;
      bmp_put(b, i, j, c1.red + (c2.red - c1.red) * t,
              c1.green + (c2.green - c1.green) * t,
              c1.blue + (c2.blue - c1.blue) * t,
              c1.alpha + (c2.alpha - c1.alpha) * t);
    }
  }
  b.dirty = true;
  return self;
}

// RGSS Bitmap#hue_change(hue): rotate every pixel's hue by `hue` degrees,
// preserving saturation, value and alpha (an RGB -> HSV -> RGB pass, matching
// RMXP's hue rotation). A hue of 0 (mod 360) is a no-op.
// RGSS Bitmap#blur: soften the whole bitmap in place.
//
// A 3x3 box blur, run over a copy so every output pixel reads the *original*
// neighbourhood -- blurring in place would feed already-blurred pixels back in
// and smear along the scan order rather than evenly. Edge pixels average only
// the neighbours that exist, so the border is not darkened toward transparent.
//
// The channels are averaged premultiplied by alpha, which is what stops a
// transparent neighbour dragging colour out of an opaque pixel: a transparent
// pixel has no colour to contribute, only weight. RGSS's own blur is a
// fixed, mild one with no parameters, so there is nothing here to tune.
mrb_value bmp_blur(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  if (b.width < 1 || b.height < 1)
    return self;
  const std::vector<uint8_t> src = b.buffer;
  // Read through the untouched copy, not the bitmap being written.
  auto read_src = [&](int32_t x, int32_t y, int& r, int& g, int& bl, int& a) {
    const unsigned bpp = lv_color_format_get_size(b.format);
    const uint8_t* p = src.data() + ((size_t)y * b.width + x) * bpp;
    bl = p[0];
    g = p[1];
    r = p[2];
    a = bpp >= 4 ? p[3] : 255;
  };
  for (int32_t y = 0; y < b.height; ++y) {
    for (int32_t x = 0; x < b.width; ++x) {
      int rs = 0, gs = 0, bs = 0, as = 0, n = 0;
      for (int32_t dy = -1; dy <= 1; ++dy) {
        for (int32_t dx = -1; dx <= 1; ++dx) {
          const int32_t sx = x + dx, sy = y + dy;
          if (sx < 0 || sy < 0 || sx >= b.width || sy >= b.height)
            continue;
          int r, g, bl, a;
          read_src(sx, sy, r, g, bl, a);
          rs += r * a / 255;
          gs += g * a / 255;
          bs += bl * a / 255;
          as += a;
          ++n;
        }
      }
      if (n == 0)
        continue;
      const int a = as / n;
      // Undo the premultiply. A fully transparent result has no colour to
      // recover, so leave it black rather than dividing by zero.
      const int r = a > 0 ? std::min(255, rs * 255 / n / a) : 0;
      const int g = a > 0 ? std::min(255, gs * 255 / n / a) : 0;
      const int bl = a > 0 ? std::min(255, bs * 255 / n / a) : 0;
      bmp_put(b, x, y, r, g, bl, a);
    }
  }
  b.dirty = true;
  return self;
}

// RGSS Bitmap#radial_blur(angle, division): a rotational blur about the centre.
//
// `division` copies of the image, spread evenly over `angle` degrees and
// centred on the original (so the result is symmetric rather than smeared to
// one side), averaged together. Sampling is nearest-neighbour; samples that
// rotate off the bitmap contribute nothing, which keeps the corners from
// pulling in transparent pixels and going dark. As in #blur the average is
// taken premultiplied.
//
// division < 2 or angle == 0 is the identity, matching "no rotation to spread
// over" rather than dividing by zero.
mrb_value bmp_radial_blur(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int angle, division;
  mrb_get_args(M, "ii", &angle, &division);
  if (division < 2 || angle == 0 || b.width < 1 || b.height < 1)
    return self;
  const std::vector<uint8_t> src = b.buffer;
  const unsigned bpp = lv_color_format_get_size(b.format);
  auto read_src = [&](int32_t x, int32_t y, int& r, int& g, int& bl, int& a) {
    const uint8_t* p = src.data() + ((size_t)y * b.width + x) * bpp;
    bl = p[0];
    g = p[1];
    r = p[2];
    a = bpp >= 4 ? p[3] : 255;
  };
  const double cx = (b.width - 1) / 2.0;
  const double cy = (b.height - 1) / 2.0;
  const double span = angle * 3.14159265358979323846 / 180.0;
  for (int32_t y = 0; y < b.height; ++y) {
    for (int32_t x = 0; x < b.width; ++x) {
      int rs = 0, gs = 0, bs = 0, as = 0, n = 0;
      for (mrb_int k = 0; k < division; ++k) {
        // -span/2 .. +span/2, so the unrotated image sits in the middle.
        const double t = (double)k / (double)(division - 1) - 0.5;
        const double th = span * t;
        const double s = std::sin(th), c = std::cos(th);
        const double dx = x - cx, dy = y - cy;
        const int32_t sx = (int32_t)std::lround(cx + dx * c - dy * s);
        const int32_t sy = (int32_t)std::lround(cy + dx * s + dy * c);
        if (sx < 0 || sy < 0 || sx >= b.width || sy >= b.height)
          continue;
        int r, g, bl, a;
        read_src(sx, sy, r, g, bl, a);
        rs += r * a / 255;
        gs += g * a / 255;
        bs += bl * a / 255;
        as += a;
        ++n;
      }
      if (n == 0)
        continue;
      const int a = as / n;
      const int r = a > 0 ? std::min(255, rs * 255 / n / a) : 0;
      const int g = a > 0 ? std::min(255, gs * 255 / n / a) : 0;
      const int bl = a > 0 ? std::min(255, bs * 255 / n / a) : 0;
      bmp_put(b, x, y, r, g, bl, a);
    }
  }
  b.dirty = true;
  return self;
}

mrb_value bmp_hue_change(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int hue;
  mrb_get_args(M, "i", &hue);
  hue = ((hue % 360) + 360) % 360;
  if (hue == 0)
    return self;
  for (int32_t y = 0; y < b.height; ++y) {
    for (int32_t x = 0; x < b.width; ++x) {
      int r, g, bl, a;
      bmp_read(b, x, y, r, g, bl, a);
      const double rf = r / 255.0, gf = g / 255.0, bf = bl / 255.0;
      const double mx = std::max(rf, std::max(gf, bf));
      const double mn = std::min(rf, std::min(gf, bf));
      const double delta = mx - mn;
      double h = 0.0;
      if (delta > 0.0) {
        if (mx == rf)
          h = 60.0 * std::fmod((gf - bf) / delta, 6.0);
        else if (mx == gf)
          h = 60.0 * ((bf - rf) / delta + 2.0);
        else
          h = 60.0 * ((rf - gf) / delta + 4.0);
        if (h < 0.0)
          h += 360.0;
      }
      const double s = mx == 0.0 ? 0.0 : delta / mx;
      const double v = mx;
      h = std::fmod(h + hue, 360.0);
      // HSV -> RGB.
      const double c = v * s;
      const double xx = c * (1.0 - std::fabs(std::fmod(h / 60.0, 2.0) - 1.0));
      const double m = v - c;
      double nr, ng, nb;
      if (h < 60.0) {
        nr = c;
        ng = xx;
        nb = 0.0;
      } else if (h < 120.0) {
        nr = xx;
        ng = c;
        nb = 0.0;
      } else if (h < 180.0) {
        nr = 0.0;
        ng = c;
        nb = xx;
      } else if (h < 240.0) {
        nr = 0.0;
        ng = xx;
        nb = c;
      } else if (h < 300.0) {
        nr = xx;
        ng = 0.0;
        nb = c;
      } else {
        nr = c;
        ng = 0.0;
        nb = xx;
      }
      bmp_put(b, x, y, (nr + m) * 255.0, (ng + m) * 255.0, (nb + m) * 255.0, a);
    }
  }
  b.dirty = true;
  return self;
}

mrb_value bmp_get_pixel(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int x, y;
  mrb_get_args(M, "ii", &x, &y);
  int r = 0, g = 0, bl = 0, a = 0;
  if (x >= 0 && y >= 0 && x < b.width && y < b.height)
    bmp_read(b, x, y, r, g, bl, a);
  const V args[] = {mrb_float_value(M, r), mrb_float_value(M, g),
                    mrb_float_value(M, bl), mrb_float_value(M, a)};
  return mrb_obj_new(
      M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Color"), 4, args);
}

mrb_value bmp_set_pixel(mrb_state* M, V self) {
  Bitmap& b = bmp_self(M, self);
  mrb_int x, y;
  V col;
  mrb_get_args(M, "iio", &x, &y, &col);
  Color& c = DataType<Color>::get(M, col);
  bmp_put(b, x, y, c.red, c.green, c.blue, c.alpha);
  b.dirty = true;
  return self;
}

mrb_value bmp_blt(mrb_state* M, V self) {
  mrb_int x, y;
  Bitmap* src;
  V srect;
  mrb_int opacity = 255;
  mrb_get_args(M, "iido|i", &x, &y, &src, &DataType<Bitmap>::data_type, &srect,
               &opacity);
  Bitmap& dst = bmp_self(M, self);
  Rect& rc = DataType<Rect>::get(M, srect);
  if (opacity < 0)
    opacity = 0;
  if (opacity > 255)
    opacity = 255;
  for (mrb_int sy = rc.y; sy < rc.y + rc.height; ++sy) {
    for (mrb_int sx = rc.x; sx < rc.x + rc.width; ++sx) {
      if (sx < 0 || sy < 0 || sx >= src->width || sy >= src->height)
        continue;
      int r, g, bl, a;
      bmp_read(*src, sx, sy, r, g, bl, a);
      const int alpha = a * opacity / 255;
      const mrb_int dx = x + (sx - rc.x);
      const mrb_int dy = y + (sy - rc.y);
      if (dx < 0 || dy < 0 || dx >= dst.width || dy >= dst.height)
        continue;
      if (alpha <= 0)
        continue;
      if (alpha >= 255) {
        bmp_put(dst, dx, dy, r, g, bl, 255);
        continue;
      }
      int dr, dg, db, da;
      bmp_read(dst, dx, dy, dr, dg, db, da);
      blend_over(dst, dx, dy, r, g, bl, alpha, dr, dg, db, da);
    }
  }
  dst.dirty = true;
  return self;
}

// Copy src_rect from `src` into dest_rect of self, scaling with nearest
// neighbour sampling. Mirrors RGSS's Bitmap#stretch_blt and is used to stretch
// the small windowskin pieces (32x32 background, 16x8/8x16 border edges) over
// an arbitrarily sized window.
mrb_value bmp_stretch_blt(mrb_state* M, V self) {
  V drect_v, srect_v;
  Bitmap* src;
  mrb_int opacity = 255;
  mrb_get_args(M, "odo|i", &drect_v, &src, &DataType<Bitmap>::data_type,
               &srect_v, &opacity);
  Bitmap& dst = bmp_self(M, self);
  Rect& dr = DataType<Rect>::get(M, drect_v);
  Rect& sr = DataType<Rect>::get(M, srect_v);
  if (opacity < 0)
    opacity = 0;
  if (opacity > 255)
    opacity = 255;
  if (dr.width <= 0 || dr.height <= 0 || sr.width <= 0 || sr.height <= 0)
    return self;
  for (mrb_int j = 0; j < dr.height; ++j) {
    const mrb_int dy = dr.y + j;
    if (dy < 0 || dy >= dst.height)
      continue;
    const mrb_int sy = sr.y + j * sr.height / dr.height;
    for (mrb_int i = 0; i < dr.width; ++i) {
      const mrb_int dx = dr.x + i;
      if (dx < 0 || dx >= dst.width)
        continue;
      const mrb_int sx = sr.x + i * sr.width / dr.width;
      if (sx < 0 || sy < 0 || sx >= src->width || sy >= src->height)
        continue;
      int r, g, bl, a;
      bmp_read(*src, sx, sy, r, g, bl, a);
      const int alpha = a * opacity / 255;
      if (alpha <= 0)
        continue;
      if (alpha >= 255) {
        bmp_put(dst, dx, dy, r, g, bl, 255);
        continue;
      }
      int dr2, dg, db, da;
      bmp_read(dst, dx, dy, dr2, dg, db, da);
      blend_over(dst, dx, dy, r, g, bl, alpha, dr2, dg, db, da);
    }
  }
  dst.dirty = true;
  return self;
}

auto find_char = [](char32_t c, const auto* g, unsigned g_len) -> const auto* {
  auto i = std::lower_bound(g, g + g_len, c, [](const auto& e, char32_t v) {
    return e.codepoint < v;
  });
  if (i == (g + g_len))
    return static_cast<decltype(i)>(nullptr);
  if (i->codepoint != c)
    return static_cast<decltype(i)>(nullptr);
  return i;
};

// --- TrueType text rendering -------------------------------------------------
//
// RPG Maker XP/VX projects ship their UI font as a TrueType/OpenType file under
// the game's `Fonts/` folder and select it by family name through RGSS::Font.
// We rasterise those glyphs with stb_truetype so window/menu/title text honours
// the font's pixel size (plus bold/italic/outline/shadow), instead of the
// fixed-size shinonome bitmap font. When no usable font file is found we fall
// back to the shinonome path below, so text always draws.

struct TtfFont {
  std::vector<uint8_t> data;
  stbtt_fontinfo info{};
  bool ok = false;
};

// Lowercased, alphanumeric-only copy of a font name, so a family such as
// "VL Gothic" leniently matches a file like "VL-Gothic-Regular.ttf".
std::string font_key(std::string_view s) {
  std::string r;
  for (const unsigned char c : s)
    if (std::isalnum(c))
      r.push_back(static_cast<char>(std::tolower(c)));
  return r;
}

bool has_font_ext(const std::string& name) {
  if (name.size() < 4)
    return false;
  std::string ext = name.substr(name.size() - 4);
  for (char& c : ext)
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return ext == ".ttf" || ext == ".otf" || ext == ".ttc";
}

// Value of a String constant on Object (GAME_DIR / RTP_DIR), or "" when it is
// unset or not a String.
std::string object_const_str(mrb_state* M, const char* name) {
  const mrb_sym sym = mrb_intern_cstr(M, name);
  const V obj = mrb_obj_value(M->object_class);
  if (!mrb_const_defined(M, obj, sym))
    return std::string();
  const V v = mrb_const_get(M, obj, sym);
  if (!mrb_string_p(v))
    return std::string();
  return std::string(RSTRING_PTR(v), RSTRING_LEN(v));
}

std::shared_ptr<TtfFont> load_ttf(const std::string& path) {
  auto f = std::make_shared<TtfFont>();
  std::FILE* fp = std::fopen(path.c_str(), "rb");
  if (!fp)
    return f;
  std::fseek(fp, 0, SEEK_END);
  const long sz = std::ftell(fp);
  std::fseek(fp, 0, SEEK_SET);
  if (sz > 0) {
    f->data.resize(static_cast<size_t>(sz));
    if (std::fread(f->data.data(), 1, static_cast<size_t>(sz), fp) ==
        static_cast<size_t>(sz)) {
      const int off = stbtt_GetFontOffsetForIndex(f->data.data(), 0);
      if (off >= 0 && stbtt_InitFont(&f->info, f->data.data(), off))
        f->ok = true;
    }
  }
  std::fclose(fp);
  if (!f->ok)
    std::fprintf(stderr, "[RGSS] failed to load font file: %s\n", path.c_str());
  return f;
}

// First font file under the GAME_DIR/RTP_DIR `Fonts/` folders. With a `name`
// given, prefer an exact (lenient) family match, then a partial one, else the
// first font file found. Returns "" when no font file exists.
std::string find_font_path(mrb_state* M, const std::string& name) {
  const std::string roots[] = {object_const_str(M, "GAME_DIR"),
                               object_const_str(M, "RTP_DIR")};
  const std::string want = font_key(name);
  std::string first_any, partial;
  for (const std::string& root : roots) {
    if (root.empty())
      continue;
    const std::string dir = root + "/Fonts";
    DIR* d = opendir(dir.c_str());
    if (!d)
      continue;
    while (dirent* e = readdir(d)) {
      const std::string fn = e->d_name;
      if (!has_font_ext(fn))
        continue;
      const std::string full = dir + "/" + fn;
      if (first_any.empty())
        first_any = full;
      if (want.empty())
        continue;
      const std::string stem = font_key(fn.substr(0, fn.size() - 4));
      if (stem == want) {
        closedir(d);
        return full;
      }
      if (partial.empty() && stem.find(want) != std::string::npos)
        partial = full;
    }
    closedir(d);
  }
  return partial.empty() ? first_any : partial;
}

// RGSS::Font.default_path, or "" when unset: the font to use for a project that
// ships none of its own. Opt-in per maker rather than automatic, because
// "wrong" differs by maker — RPG Maker XP/VX projects want a real TrueType face
// at the size they asked for (their boot points this at the bundled default
// font, see assets/fonts/README.md), while RPG2000 wants the shinonome bitmap
// font, whose metrics match RPG_RT's MS Gothic and which the render-parity
// comparisons are checked against. RPG2000 therefore leaves this nil.
std::string font_default_path(mrb_state* M) {
  const V rgss_mod = mrb_obj_value(mrb_module_get(M, "RGSS"));
  const mrb_sym font_sym = mrb_intern_lit(M, "Font");
  // Font is defined in this gem's mrblib, which is always loaded alongside the
  // native half -- but text must draw, not raise, for an embedder that loaded
  // only the C side.
  if (!mrb_const_defined(M, rgss_mod, font_sym))
    return std::string();
  const V v =
      mrb_funcall(M, mrb_const_get(M, rgss_mod, font_sym), "default_path", 0);
  if (!mrb_string_p(v))
    return std::string();
  return std::string(RSTRING_PTR(v), RSTRING_LEN(v));
}

// Loaded fonts cached by requested family name (the search roots are fixed for
// a run). A cached entry may hold an unloaded font (ok == false), i.e. "no
// usable font for this name"; that negative result is cached too, so the
// Fonts/ directory is scanned only once per name.
//
// The fallback path is part of the key, not just the name: a game's scripts may
// set Font.default_path (or the boot may set it after the first text has been
// drawn), and the entry cached before that must not outlive it.
std::shared_ptr<TtfFont> ttf_for_name(mrb_state* M, const std::string& name) {
  static std::map<std::string, std::shared_ptr<TtfFont>> cache;
  const std::string fallback = font_default_path(M);
  const std::string key = name + '\n' + fallback;
  const auto it = cache.find(key);
  if (it != cache.end())
    return it->second;
  std::string path = find_font_path(M, name);
  // Nothing under the project's own Fonts/ — fall back to the shared default.
  if (path.empty())
    path = fallback;
  std::shared_ptr<TtfFont> f =
      path.empty() ? std::make_shared<TtfFont>() : load_ttf(path);
  cache[key] = f;
  return f;
}

// The subset of RGSS::Font a draw needs, read once from the bitmap's @font.
struct FontAttr {
  std::shared_ptr<TtfFont> ttf;
  double size = 22;
  bool bold = false, italic = false, outline = true, shadow = false;
  uint8_t color[4] = {0, 0, 0, 255};      // r, g, b, a
  uint8_t out_color[4] = {0, 0, 0, 128};  // r, g, b, a
};

void color_rgba(mrb_state* M, V cv, uint8_t out[4]) {
  if (mrb_nil_p(cv))
    return;
  Color& c = DataType<Color>::get(M, cv);
  out[0] = static_cast<uint8_t>(c.red);
  out[1] = static_cast<uint8_t>(c.green);
  out[2] = static_cast<uint8_t>(c.blue);
  out[3] = static_cast<uint8_t>(c.alpha);
}

FontAttr read_font(mrb_state* M, V self) {
  FontAttr fa;
  std::string name;
  const V fv = mrb_iv_get(M, self, mrb_intern_lit(M, "@font"));
  if (!mrb_nil_p(fv)) {
    const V nv = mrb_funcall(M, fv, "name", 0);
    if (mrb_string_p(nv)) {
      name.assign(RSTRING_PTR(nv), RSTRING_LEN(nv));
    } else if (mrb_array_p(nv) && RARRAY_LEN(nv) > 0 &&
               mrb_string_p(mrb_ary_ref(M, nv, 0))) {
      // RGSS accepts an array of family names; use the first.
      const V n0 = mrb_ary_ref(M, nv, 0);
      name.assign(RSTRING_PTR(n0), RSTRING_LEN(n0));
    }
    const V sv = mrb_funcall(M, fv, "size", 0);
    if (mrb_fixnum_p(sv))
      fa.size = static_cast<double>(mrb_fixnum(sv));
    else if (mrb_float_p(sv))
      fa.size = mrb_float(sv);
    fa.bold = mrb_bool(mrb_funcall(M, fv, "bold", 0));
    fa.italic = mrb_bool(mrb_funcall(M, fv, "italic", 0));
    fa.outline = mrb_bool(mrb_funcall(M, fv, "outline", 0));
    fa.shadow = mrb_bool(mrb_funcall(M, fv, "shadow", 0));
    color_rgba(M, mrb_funcall(M, fv, "color", 0), fa.color);
    color_rgba(M, mrb_funcall(M, fv, "out_color", 0), fa.out_color);
  }
  fa.ttf = ttf_for_name(M, name);
  return fa;
}

// Advance width and line height of `s` at `px` em size, in whole pixels.
void measure_text_ttf(TtfFont& f,
                      std::string_view s,
                      double px,
                      int& width,
                      int& height) {
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&f.info, static_cast<float>(px));
  int asc = 0, desc = 0, gap = 0;
  stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);
  double w = 0;
  int prev = 0;
  for (const char32_t c : s | una::views::utf8) {
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, static_cast<int>(c), &adv, &lsb);
    if (prev)
      w += scale *
           stbtt_GetCodepointKernAdvance(&f.info, prev, static_cast<int>(c));
    w += scale * adv;
    prev = static_cast<int>(c);
  }
  width = static_cast<int>(std::lround(w));
  height = static_cast<int>(std::lround(scale * (asc - desc)));
}

// Blend a glyph coverage bitmap (`cov`, gw x gh, 8-bit alpha) into `bmp` in
// colour (r,g,b) scaled by `a`. `ox,oy` is the coverage's top-left device
// position. `dilate` > 0 spreads the coverage by that radius (a max filter) to
// paint an outline. `slant` shears each row horizontally about `baseline_y` for
// a synthetic italic.
void blit_glyph_cov(Bitmap& bmp,
                    const uint8_t* cov,
                    int gw,
                    int gh,
                    int ox,
                    int oy,
                    int baseline_y,
                    int r,
                    int g,
                    int b,
                    int a,
                    int dilate,
                    double slant) {
  for (int j = -dilate; j < gh + dilate; ++j) {
    const int ty = oy + j;
    if (ty < 0 || ty >= bmp.height)
      continue;
    const int shear =
        slant != 0.0 ? static_cast<int>(std::lround(slant * (baseline_y - ty)))
                     : 0;
    for (int i = -dilate; i < gw + dilate; ++i) {
      int m = 0;
      if (dilate <= 0) {
        m = cov[j * gw + i];
      } else {
        for (int dy = -dilate; dy <= dilate && m < 255; ++dy) {
          const int sy = j + dy;
          if (sy < 0 || sy >= gh)
            continue;
          for (int dx = -dilate; dx <= dilate; ++dx) {
            const int sx = i + dx;
            if (sx < 0 || sx >= gw)
              continue;
            if (cov[sy * gw + sx] > m)
              m = cov[sy * gw + sx];
          }
        }
      }
      if (m <= 0)
        continue;
      const int tx = ox + i + shear;
      if (tx < 0 || tx >= bmp.width)
        continue;
      const int alpha = a * m / 255;
      if (alpha <= 0)
        continue;
      int dr, dg, db, da;
      bmp_read(bmp, tx, ty, dr, dg, db, da);
      const int inv = 255 - alpha;
      bmp_put(bmp, tx, ty, (r * alpha + dr * inv) / 255,
              (g * alpha + dg * inv) / 255, (b * alpha + db * inv) / 255,
              std::max(da, alpha));
    }
  }
}

// Like blit_glyph_cov, but instead of a flat colour the glyph is filled from a
// source region (`src` rect sx,sy,sw,sh) — the System windowskin's text-colour
// swatch — so the swatch's own shading blends into the text (RPG2000 draws its
// message text this way). The fill colour for a device row `ty` is sampled from
// the swatch column centre at the row mapped by the glyph's vertical position
// within the text line [tline_top, tline_top+tline_h], so a vertically-shaded
// swatch reads as a top-to-bottom gradient on the glyphs.
void blit_glyph_tex(Bitmap& bmp,
                    const uint8_t* cov,
                    int gw,
                    int gh,
                    int ox,
                    int oy,
                    int baseline_y,
                    double slant,
                    const Bitmap& src,
                    int sx,
                    int sy,
                    int sw,
                    int sh,
                    double tline_top,
                    double tline_h) {
  const int scol = sx + sw / 2;
  for (int j = 0; j < gh; ++j) {
    const int ty = oy + j;
    if (ty < 0 || ty >= bmp.height)
      continue;
    const int shear =
        slant != 0.0 ? static_cast<int>(std::lround(slant * (baseline_y - ty)))
                     : 0;
    int srow = sy;
    if (sh > 1 && tline_h > 0.0) {
      int r = static_cast<int>(std::lround(
          (static_cast<double>(ty) - tline_top) * (sh - 1) / tline_h));
      srow = sy + std::clamp(r, 0, sh - 1);
    }
    int sr = 255, sg = 255, sb = 255, sa = 255;
    if (scol >= 0 && srow >= 0 && scol < src.width && srow < src.height)
      bmp_read(src, scol, srow, sr, sg, sb, sa);
    for (int i = 0; i < gw; ++i) {
      const int m = cov[j * gw + i];
      if (m <= 0)
        continue;
      const int tx = ox + i + shear;
      if (tx < 0 || tx >= bmp.width)
        continue;
      const int alpha = m * sa / 255;
      if (alpha <= 0)
        continue;
      int dr, dg, db, da;
      bmp_read(bmp, tx, ty, dr, dg, db, da);
      const int inv = 255 - alpha;
      bmp_put(bmp, tx, ty, (sr * alpha + dr * inv) / 255,
              (sg * alpha + dg * inv) / 255, (sb * alpha + db * inv) / 255,
              std::max(da, alpha));
    }
  }
}

// Draw `s` into `bmp` with a TrueType font, laid out in the rect (x,y,w,h) with
// horizontal `align` (0 left, 1 centre, 2 right) and vertically centred. Shadow
// and outline (from the font's out_color) are painted under the fill; bold is a
// second fill offset one pixel; italic shears the glyphs.
void draw_text_ttf(Bitmap& bmp,
                   const FontAttr& fa,
                   TtfFont& f,
                   std::string_view s,
                   mrb_int x,
                   mrb_int y,
                   mrb_int w,
                   mrb_int h,
                   int align) {
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&f.info, static_cast<float>(fa.size));
  int asc = 0, desc = 0, gap = 0;
  stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);

  int tw = 0, th = 0;
  measure_text_ttf(f, s, fa.size, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;

  // Baseline of a block vertically centred within the rect.
  const double top = y + (h - scale * (asc - desc)) / 2.0;
  const double baseY = top + scale * asc;

  const double slant = fa.italic ? 0.25 : 0.0;
  const bool do_outline = fa.outline && fa.out_color[3] > 0;

  double penX = static_cast<double>(x);
  int prev = 0;
  for (const char32_t c : s | una::views::utf8) {
    if (prev)
      penX += scale *
              stbtt_GetCodepointKernAdvance(&f.info, prev, static_cast<int>(c));
    int gw = 0, gh = 0, gx = 0, gy = 0;
    uint8_t* g = stbtt_GetCodepointBitmap(
        &f.info, scale, scale, static_cast<int>(c), &gw, &gh, &gx, &gy);
    if (g) {
      const int by = static_cast<int>(std::lround(baseY));
      const int ox = static_cast<int>(std::lround(penX)) + gx;
      const int oy = by + gy;
      if (fa.shadow)
        blit_glyph_cov(bmp, g, gw, gh, ox + 1, oy + 1, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 0,
                       slant);
      if (do_outline)
        blit_glyph_cov(bmp, g, gw, gh, ox, oy, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 1,
                       slant);
      blit_glyph_cov(bmp, g, gw, gh, ox, oy, by, fa.color[0], fa.color[1],
                     fa.color[2], fa.color[3], 0, slant);
      if (fa.bold)
        blit_glyph_cov(bmp, g, gw, gh, ox + 1, oy, by, fa.color[0], fa.color[1],
                       fa.color[2], fa.color[3], 0, slant);
      stbtt_FreeBitmap(g, nullptr);
    }
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, static_cast<int>(c), &adv, &lsb);
    penX += scale * adv;
    prev = static_cast<int>(c);
  }
  bmp.dirty = true;
}

// Like draw_text_ttf, but the glyph fill is textured from a source swatch
// region (see blit_glyph_tex) rather than a flat colour. Shadow and outline
// stay the font's flat out_colour; only the main (and bold) fill is textured.
void draw_text_tex_ttf(Bitmap& bmp,
                       const FontAttr& fa,
                       TtfFont& f,
                       std::string_view s,
                       mrb_int x,
                       mrb_int y,
                       mrb_int w,
                       mrb_int h,
                       int align,
                       const Bitmap& src,
                       int sx,
                       int sy,
                       int sw,
                       int sh) {
  const float scale =
      stbtt_ScaleForMappingEmToPixels(&f.info, static_cast<float>(fa.size));
  int asc = 0, desc = 0, gap = 0;
  stbtt_GetFontVMetrics(&f.info, &asc, &desc, &gap);

  int tw = 0, th = 0;
  measure_text_ttf(f, s, fa.size, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;

  const double top = y + (h - scale * (asc - desc)) / 2.0;
  const double baseY = top + scale * asc;
  const double tline_h = scale * (asc - desc);
  const double slant = fa.italic ? 0.25 : 0.0;
  const bool do_outline = fa.outline && fa.out_color[3] > 0;

  double penX = static_cast<double>(x);
  int prev = 0;
  for (const char32_t c : s | una::views::utf8) {
    if (prev)
      penX += scale *
              stbtt_GetCodepointKernAdvance(&f.info, prev, static_cast<int>(c));
    int gw = 0, gh = 0, gx = 0, gy = 0;
    uint8_t* g = stbtt_GetCodepointBitmap(
        &f.info, scale, scale, static_cast<int>(c), &gw, &gh, &gx, &gy);
    if (g) {
      const int by = static_cast<int>(std::lround(baseY));
      const int ox = static_cast<int>(std::lround(penX)) + gx;
      const int oy = by + gy;
      if (fa.shadow)
        blit_glyph_cov(bmp, g, gw, gh, ox + 1, oy + 1, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 0,
                       slant);
      if (do_outline)
        blit_glyph_cov(bmp, g, gw, gh, ox, oy, by, fa.out_color[0],
                       fa.out_color[1], fa.out_color[2], fa.out_color[3], 1,
                       slant);
      blit_glyph_tex(bmp, g, gw, gh, ox, oy, by, slant, src, sx, sy, sw, sh,
                     top, tline_h);
      if (fa.bold)
        blit_glyph_tex(bmp, g, gw, gh, ox + 1, oy, by, slant, src, sx, sy, sw,
                       sh, top, tline_h);
      stbtt_FreeBitmap(g, nullptr);
    }
    int adv = 0, lsb = 0;
    stbtt_GetCodepointHMetrics(&f.info, static_cast<int>(c), &adv, &lsb);
    penX += scale * adv;
    prev = static_cast<int>(c);
  }
  bmp.dirty = true;
}

// Measure the pixel width and height of `s` using the shinonome font tables.
void measure_text(std::string_view s, int& width, unsigned& height) {
  width = 0;
  height = 0;
  for (const char32_t c : s | una::views::utf8) {
    auto f = find_char(c, shinonome::GOTHIC, shinonome::GOTHIC_LEN);
    if (f) {
      width += f->WIDTH;
      height = std::max<unsigned>(height, f->HEIGHT);
      continue;
    }
    auto h = find_char(c, shinonome::LATIN1, shinonome::LATIN1_LEN);
    if (h) {
      width += h->WIDTH;
      height = std::max<unsigned>(height, h->HEIGHT);
      continue;
    }
    h = find_char(c, shinonome::HANKAKU, shinonome::HANKAKU_LEN);
    if (h) {
      width += h->WIDTH;
      height = std::max<unsigned>(height, h->HEIGHT);
      continue;
    }
  }
}

// RGSS Bitmap#draw_text, in both the forms RGSS documents:
//
//   draw_text(x, y, width, height, str[, align])
//   draw_text(rect, str[, align])
//
// The Rect form is not a nicety -- `Window_Command#draw_item`, the menu every
// game's title screen is built from, calls it -- so a bitmap that only took the
// four-number form stopped a game's own engine at its first window with
// "wrong number of arguments (given 2, expected 5..6)". Same argc branch as
// #fill_rect, which RGSS overloads the same way.
mrb_value bmp_draw_text(mrb_state* M, mrb_value self) {
  auto& bmp = bmp_self(M, self);

  mrb_int x, y, w, h, len;
  mrb_int align = 0;
  const char* s;
  if (mrb_get_argc(M) <= 3) {
    V r;
    mrb_get_args(M, "os|i", &r, &s, &len, &align);
    Rect& rc = DataType<Rect>::get(M, r);
    x = rc.x;
    y = rc.y;
    w = rc.width;
    h = rc.height;
  } else {
    mrb_get_args(M, "iiiis|i", &x, &y, &w, &h, &s, &len, &align);
  }
  const std::string_view sv(s, len);

  // Prefer the game's TrueType font (RPG Maker XP/VX ship one under Fonts/),
  // rasterising at the font's pixel size. Fall back to the fixed-size shinonome
  // bitmap font when no usable font file is found.
  const FontAttr fa = read_font(M, self);
  if (fa.ttf && fa.ttf->ok) {
    draw_text_ttf(bmp, fa, *fa.ttf, sv, x, y, w, h, static_cast<int>(align));
    return self;
  }

  // Text colour comes from the font (default opaque black when no @font is
  // set), laid out in the bitmap's byte order (B, G, R, A).
  const uint8_t col[4] = {fa.color[2], fa.color[1], fa.color[0], fa.color[3]};

  // Horizontal alignment: 0 left, 1 center, 2 right.
  int tw = 0;
  unsigned th = 0;
  measure_text(sv, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;

  const unsigned col_len = lv_color_format_get_size(bmp.format);
  auto draw = [&x, y, &bmp, &col, col_len](const auto& c) {
    for (unsigned i = 0; i < c.HEIGHT; ++i) {
      for (unsigned j = 0; j < c.WIDTH; ++j) {
        const unsigned idx = i * c.WIDTH + j;
        const mrb_int px = x + j;
        const mrb_int py = y + i;
        if (px < 0 || py < 0 || px >= bmp.width || py >= bmp.height)
          continue;
        if (c.data[idx / 32] & (1 << (idx % 32)))
          std::memcpy(bmp.buffer.data() + (py * bmp.width + px) * col_len, col,
                      col_len);
      }
    }
    x += c.WIDTH;
  };

  for (const char32_t c : sv | una::views::utf8) {
    auto f = find_char(c, shinonome::GOTHIC, shinonome::GOTHIC_LEN);
    if (f) {
      draw(*f);
      continue;
    }
    auto hh = find_char(c, shinonome::LATIN1, shinonome::LATIN1_LEN);
    if (hh) {
      draw(*hh);
      continue;
    }
    hh = find_char(c, shinonome::HANKAKU, shinonome::HANKAKU_LEN);
    if (hh) {
      draw(*hh);
      continue;
    }
  }

  bmp.dirty = true;
  return self;
}

// Draw text whose glyphs are filled from a source region of `src` (a System
// windowskin's text-colour swatch) instead of a flat colour, so the swatch's
// shading blends into the text — RPG2000's message-colour rendering. Same
// layout as draw_text; args: (x, y, w, h, text, src, sx, sy, sw, sh[, align]).
// Uses the TrueType path when a game font is present, else the shinonome bitmap
// font (what RPG2000 games use), sampling the swatch by vertical position for a
// top-to-bottom gradient.
mrb_value bmp_blend_text(mrb_state* M, mrb_value self) {
  auto& bmp = bmp_self(M, self);

  mrb_int x, y, w, h, len, sx, sy, sw, sh;
  mrb_int align = 0;
  const char* s;
  Bitmap* src;
  mrb_get_args(M, "iiiisdiiii|i", &x, &y, &w, &h, &s, &len, &src,
               &DataType<Bitmap>::data_type, &sx, &sy, &sw, &sh, &align);
  const std::string_view sv(s, len);

  const FontAttr fa = read_font(M, self);
  if (fa.ttf && fa.ttf->ok) {
    draw_text_tex_ttf(bmp, fa, *fa.ttf, sv, x, y, w, h, static_cast<int>(align),
                      *src, static_cast<int>(sx), static_cast<int>(sy),
                      static_cast<int>(sw), static_cast<int>(sh));
    return self;
  }

  int tw = 0;
  unsigned th = 0;
  measure_text(sv, tw, th);
  if (align == 1)
    x += (w - tw) / 2;
  else if (align == 2)
    x += w - tw;

  const int scol = static_cast<int>(sx + sw / 2);
  auto draw = [&x, y, &bmp, src, scol, sy, sh](const auto& c) {
    for (unsigned i = 0; i < c.HEIGHT; ++i) {
      // Sample the swatch row for this glyph row so a shaded swatch gradients
      // down the text; a flat swatch reads as a single colour.
      int srow = static_cast<int>(sy);
      if (sh > 1 && c.HEIGHT > 1)
        srow =
            static_cast<int>(sy) +
            std::clamp(static_cast<int>(std::lround(static_cast<double>(i) *
                                                    (sh - 1) / (c.HEIGHT - 1))),
                       0, static_cast<int>(sh) - 1);
      int sr = 255, sg = 255, sb = 255, sa = 255;
      if (scol >= 0 && srow >= 0 && scol < src->width && srow < src->height)
        bmp_read(*src, scol, srow, sr, sg, sb, sa);
      for (unsigned j = 0; j < c.WIDTH; ++j) {
        const unsigned idx = i * c.WIDTH + j;
        const mrb_int px = x + j;
        const mrb_int py = y + i;
        if (px < 0 || py < 0 || px >= bmp.width || py >= bmp.height)
          continue;
        if (c.data[idx / 32] & (1 << (idx % 32)))
          bmp_put(bmp, px, py, sr, sg, sb, sa);
      }
    }
    x += c.WIDTH;
  };

  for (const char32_t c : sv | una::views::utf8) {
    auto f = find_char(c, shinonome::GOTHIC, shinonome::GOTHIC_LEN);
    if (f) {
      draw(*f);
      continue;
    }
    auto hh = find_char(c, shinonome::LATIN1, shinonome::LATIN1_LEN);
    if (hh) {
      draw(*hh);
      continue;
    }
    hh = find_char(c, shinonome::HANKAKU, shinonome::HANKAKU_LEN);
    if (hh) {
      draw(*hh);
      continue;
    }
  }

  bmp.dirty = true;
  return self;
}

mrb_value bmp_text_size(mrb_state* M, mrb_value self) {
  mrb_int len;
  const char* s;
  mrb_get_args(M, "s", &s, &len);
  const std::string_view sv(s, len);

  int w = 0;
  int height = 0;
  const FontAttr fa = read_font(M, self);
  if (fa.ttf && fa.ttf->ok) {
    measure_text_ttf(*fa.ttf, sv, fa.size, w, height);
  } else {
    unsigned uh = 0;
    measure_text(sv, w, uh);
    height = static_cast<int>(uh);
  }

  const mrb_value args[] = {
      mrb_fixnum_value(0),
      mrb_fixnum_value(0),
      mrb_fixnum_value(w),
      mrb_fixnum_value(height),
  };

  return mrb_obj_new(
      M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Rect"), 4, args);
}

// RGSS #disposed?: whether #dispose has already run. The data pointer is
// cleared exactly when it does (see obj_dispose), so a null pointer *is* the
// disposed state -- this used to answer the other way round, reporting every
// live object as disposed and every disposed one as live. The stock scripts
// guard cleanup and redraws with it (`unless bitmap.disposed?`), so inverted it
// meant skipping work on a live object and touching a freed one.
mrb_value obj_disposed(mrb_state* M, mrb_value self) {
  return mrb_bool_value(DATA_PTR(self) == nullptr);
}

mrb_value obj_dispose(mrb_state* M, mrb_value self) {
  if (!DATA_PTR(self))
    return mrb_nil_value();

  DATA_TYPE(self)->dfree(M, DATA_PTR(self));
  DATA_PTR(self) = nullptr;
  return mrb_nil_value();
}

// Array of z-ordered display objects (Sprites and Viewports). Stacking is
// resolved per LVGL parent: sprites sharing a parent (the screen, or a
// Viewport's content layer) are ordered among themselves by their `z`.
// Populated by register_zobj.
mrb_value zorder_objs(mrb_state* M) {
  const mrb_value mod = mrb_obj_value(mrb_module_get(M, "RGSS"));
  const mrb_value ret = mrb_const_get(M, mod, mrb_intern_lit(M, "_zobjs"));
  mrb_assert(mrb_array_p(ret));
  return ret;
}

// Flag the module so the next Graphics.update reshuffles LVGL sibling order to
// match the objects' `z` values. Reordering every frame would be wasteful, so
// callers only mark it dirty when a `z` (or the root set) actually changes.
void update_z(mrb_state* M) {
  const mrb_value mod = mrb_obj_value(mrb_module_get(M, "RGSS"));
  mrb_iv_set(M, mod, mrb_intern_lit(M, "_z_updated"), mrb_true_value());
}

// Drain every backend's buffered key transitions into RGSS::Input. Called from
// Input.update (mrblib/lib.rb) — *not* from Graphics.update, which is where
// this used to live and where it silently broke every game that runs its own
// engine: an RGSS scene loop is
//
//   loop { Graphics.update; Input.update; update; break if $scene != self }
//
// so transitions applied during Graphics.update were wiped by the game's own
// Input.update (which expires the previous frame's triggers) before the scene
// read them — `Input.trigger?` could never be true under the script host, and
// no game could be played. RGSS's contract is that Input.update is what
// refreshes input, so that is where the drain belongs; the built-in flows call
// it once a frame too, so their timing is unchanged.
mrb_value input_poll(mrb_state* M, mrb_value self) {
  rgss_terminal_poll(M);
  rgss_sdl_poll(M);
#if defined(WIO_TERMINAL)
  rgss_wio_poll(M);
#endif
#if defined(PSP_BUILD)
  rgss_psp_poll(M);
#endif
  return mrb_nil_value();
}

// Push a key transition into the same buffer the SDL backend feeds, from Ruby.
// The headless tests use it to drive the loop above without a window.
mrb_value input_push(mrb_state* M, mrb_value self) {
  mrb_int key;
  mrb_bool press;
  mrb_get_args(M, "ib", &key, &press);
  rgss_sdl_input_push(static_cast<int>(key), press);
  return mrb_nil_value();
}

mrb_value gfx_update(mrb_state* M, mrb_value self) {
  const mrb_value rgss_mod = mrb_obj_value(mrb_module_get(M, "RGSS"));

  rgss_audio_frame();

  if (mrb_const_defined(M, mrb_obj_value(M->object_class),
                        mrb_intern_lit(M, "TIMEOUT_MS"))) {
    const mrb_value timeout_ms = mrb_const_get(
        M, mrb_obj_value(M->object_class), mrb_intern_lit(M, "TIMEOUT_MS"));
    mrb_assert(mrb_fixnum_p(timeout_ms));
    const mrb_value start =
        mrb_const_get(M, rgss_mod, mrb_intern_lit(M, "_game_start"));
    mrb_assert(mrb_fixnum_p(start));

    if (mrb_fixnum(timeout_ms) > 0 &&
        (lv_tick_get() - mrb_fixnum(start)) > mrb_fixnum(timeout_ms)) {
      mrb_raisef(M,
                 mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Timeout"),
                 "Timeout");
    }
  }

  // Reapply z ordering when something changed since the last frame. LVGL draws
  // siblings in child order, so within each LVGL parent we sort that parent's
  // z-managed objects by `z` and move them to the foreground from lowest to
  // highest, leaving the greatest `z` on top. Grouping by parent means sprites
  // that live inside a Viewport are ordered among themselves, while the
  // Viewport (and top-level sprites) are ordered against each other on the
  // screen. Disposed objects (null DATA_PTR) are dropped from the set here so
  // it does not grow unbounded.
  if (mrb_bool(mrb_iv_get(M, rgss_mod, mrb_intern_lit(M, "_z_updated")))) {
    ProfilerScope _zscope("gfx.zorder");
    const mrb_value objs = zorder_objs(M);
    const mrb_value live = mrb_ary_new(M);
    std::map<lv_obj_t*, std::multimap<mrb_int, lv_obj_t*>> by_parent;
    for (mrb_int i = 0; i < RARRAY_LEN(objs); ++i) {
      const mrb_value v = RARRAY_PTR(objs)[i];
      if (!DATA_PTR(v))
        continue;
      mrb_ary_push(M, live, v);
      lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(v));
      const mrb_value z = mrb_iv_get(M, v, mrb_intern_lit(M, "@z"));
      mrb_assert(mrb_fixnum_p(z));
      by_parent[lv_obj_get_parent(obj)].insert({mrb_fixnum(z), obj});
    }
    mrb_const_set(M, rgss_mod, mrb_intern_lit(M, "_zobjs"), live);
    for (const auto& group : by_parent)
      for (const auto& order : group.second)
        lv_obj_move_foreground(order.second);
    mrb_iv_set(M, rgss_mod, mrb_intern_lit(M, "_z_updated"), mrb_false_value());
  }

  // Bitmap mutators write straight into the shared pixel buffer, which LVGL
  // does not observe. Walk the live sprites and invalidate any whose bitmap has
  // been touched since the last frame so LVGL repaints them below. Flags are
  // cleared only after the whole sweep so a bitmap shared by several sprites
  // invalidates all of them.
  {
    ProfilerScope _iscope("gfx.invalidate");
    const mrb_value roots = zorder_objs(M);
    const mrb_sym bitmap_sym = mrb_intern_lit(M, "@bitmap");
    for (mrb_int i = 0; i < RARRAY_LEN(roots); ++i) {
      const mrb_value v = RARRAY_PTR(roots)[i];
      lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(v));
      if (!obj)
        continue;
      const mrb_value bmpv = mrb_iv_get(M, v, bitmap_sym);
      if (mrb_nil_p(bmpv) || !DATA_PTR(bmpv))
        continue;
      Bitmap* b = reinterpret_cast<Bitmap*>(DATA_PTR(bmpv));
      if (b->dirty)
        lv_obj_invalidate(obj);
    }
    // Second pass: clear the flags now that every referencing sprite is marked.
    for (mrb_int i = 0; i < RARRAY_LEN(roots); ++i) {
      const mrb_value v = RARRAY_PTR(roots)[i];
      if (!DATA_PTR(v))
        continue;
      const mrb_value bmpv = mrb_iv_get(M, v, bitmap_sym);
      if (mrb_nil_p(bmpv) || !DATA_PTR(bmpv))
        continue;
      reinterpret_cast<Bitmap*>(DATA_PTR(bmpv))->dirty = false;
    }
  }

  {
    ProfilerScope _lvscope("gfx.lvgl");
    lv_timer_handler();
    lv_task_handler();
  }

  // Advance Graphics.frame_count, matching RGSS semantics.
  V gfx = mrb_obj_value(
      mrb_module_get_under(M, mrb_module_get(M, "RGSS"), "Graphics"));
  V fc = mrb_iv_get(M, gfx, mrb_intern_lit(M, "@frame_count"));
  mrb_iv_set(M, gfx, mrb_intern_lit(M, "@frame_count"),
             mrb_fixnum_value((mrb_fixnum_p(fc) ? mrb_fixnum(fc) : 0) + 1));

  // Frame pacing, against an absolute deadline rather than "sleep whatever is
  // left of 16ms". lv_delay_ms overshoots by several milliseconds (it is a
  // usleep at OS timer granularity), and sleeping the remainder every frame
  // lets that overshoot accumulate: measured against a genuine RPG_RT under
  // wine, ~9ms of work per frame settled at 44fps instead of 60, so every timed
  // thing in the game -- walk cycles, animated tiles, message reveal, Wait
  // commands -- ran about a quarter too slow (see ADR 0021). Carrying the
  // deadline forward instead makes the next frame's sleep absorb the previous
  // one's overshoot. If we fall more than one frame behind (a slow map build,
  // a breakpoint), the deadline is re-based on now so we do not then spin
  // through a burst of catch-up frames.
  //
  // A frame is 1000/60 ms, which is not an integer, so the deadline steps by
  // 17,17,16,... driven by a 1/60-ms remainder accumulator rather than a flat
  // 16 (which would run 4% fast).
  static uint32_t next_frame = 0;
  static uint32_t period_acc = 0;
  static bool paced = false;
  const uint32_t now = lv_tick_get();
  period_acc += 1000;
  const uint32_t period = period_acc / 60;
  period_acc %= 60;
  if (!paced ||
      static_cast<int32_t>(now - next_frame) > static_cast<int32_t>(period)) {
    next_frame = now;
    paced = true;
  }
  next_frame += period;
  const int32_t sleep = static_cast<int32_t>(next_frame - lv_tick_get());
  if (sleep > 0) {
    // Report the idle wait so the profiler can subtract it: the frame spans the
    // whole main_loop iteration (see RGSS::Profiler.frame), and we want its
    // "work" figure to measure CPU cost, not the time spent sleeping here.
    profiler_note_idle(sleep);
    lv_delay_ms(sleep);
  }

  return mrb_nil_value();
}

void free_obj(mrb_state* M, void* p) {
  if (!p)
    return;
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(p);
  lv_obj_delete(obj);
}

lv_display_t* get_display(mrb_state* M) {
  mrb_value v = mrb_const_get(M, mrb_obj_value(mrb_module_get(M, "RGSS")),
                              mrb_intern_lit(M, "_display"));
  mrb_assert(mrb_cptr_p(v));
  return reinterpret_cast<lv_display_t*>(mrb_cptr(v));
}

// Report an unimplemented path through RGSS.warn_stub, which dedupes by name.
void RGSS_warn_stub(mrb_state* M, const char* name) {
  mrb_funcall(M, mrb_obj_value(mrb_module_get(M, "RGSS")), "warn_stub", 1,
              mrb_str_new_cstr(M, name));
}

// RGSS Graphics.snap_to_bitmap: the rendered screen as a Bitmap.
//
// lv_snapshot_take re-renders the active screen's object tree into a fresh
// buffer, which is the only capture that works on every backend here -- the SDL
// window, the terminal framebuffer and the wasm canvas all buffer differently,
// and two of them render partially. The buffer comes back in LVGL's ARGB8888
// byte order (B, G, R, A), the same layout Bitmap uses, so the rows copy
// straight across (honouring the snapshot's stride, which is padded).
//
// Answers nil where the module is compiled out (the Wio/PSP builds) rather than
// pretending, and says so once.
mrb_value gfx_snap_to_bitmap(mrb_state* M, mrb_value self) {
#if LV_USE_SNAPSHOT
  lv_obj_t* screen = lv_display_get_screen_active(get_display(M));
  if (!screen)
    return mrb_nil_value();
  lv_draw_buf_t* snap = lv_snapshot_take(screen, LV_COLOR_FORMAT_ARGB8888);
  if (!snap) {
    RGSS_warn_stub(M, "Graphics.snap_to_bitmap (snapshot failed)");
    return mrb_nil_value();
  }
  const mrb_int w = snap->header.w;
  const mrb_int h = snap->header.h;
  RClass* bmp_class =
      mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap");
  const mrb_value out =
      DataType<Bitmap>::make(M, bmp_class, w, h, LV_COLOR_FORMAT_ARGB8888);
  Bitmap& b = DataType<Bitmap>::get(M, out);
  const uint32_t stride = snap->header.stride;
  for (mrb_int y = 0; y < h; ++y) {
    const uint8_t* src = snap->data + static_cast<size_t>(y) * stride;
    uint8_t* dst = b.buffer.data() + static_cast<size_t>(y) * w * 4;
    std::memcpy(dst, src, static_cast<size_t>(w) * 4);
  }
  b.dirty = true;
  lv_draw_buf_destroy(snap);
  return out;
#else
  RGSS_warn_stub(M, "Graphics.snap_to_bitmap");
  return mrb_nil_value();
#endif
}

const mrb_data_type obj_type = {"lv_obj_t", free_obj};

// LVGL fires LV_EVENT_DELETE when an object is destroyed, including when its
// parent is deleted and takes the whole subtree with it. Each wrapped object
// stores its mruby RData in user_data; null the data pointer here so the mruby
// wrapper (and its later dispose/GC) never calls lv_obj_delete on a freed
// object. This is what makes it safe to nest Sprites inside a Viewport that
// owns them: whichever wrapper the GC frees first, the others are invalidated.
void on_lv_delete(lv_event_t* e) {
  lv_obj_t* obj = static_cast<lv_obj_t*>(lv_event_get_target(e));
  if (void* ud = lv_obj_get_user_data(obj))
    static_cast<struct RData*>(ud)->data = nullptr;
}

// Bind an lv_obj to its mruby wrapper: record the wrapper in user_data and hook
// the delete event so the wrapper is invalidated if LVGL frees the object.
void wrap_lv_obj(mrb_state* M, mrb_value self, lv_obj_t* obj) {
  mrb_data_init(self, obj, &obj_type);
  lv_obj_set_user_data(obj, mrb_ptr(self));
  lv_obj_add_event_cb(obj, on_lv_delete, LV_EVENT_DELETE, nullptr);
}

// A Viewport wraps an outer clipping frame whose sole child is an inner content
// layer that actually holds the sprites; new sprites parent to that layer so
// they are clipped to the viewport and scrolled by its ox/oy.
lv_obj_t* viewport_content(lv_obj_t* outer) {
  return lv_obj_get_child(outer, 0);
}

lv_obj_t* parent_object(mrb_state* M, mrb_value vp) {
  if (mrb_nil_p(vp))
    return lv_display_get_screen_active(get_display(M));

  mrb_assert(mrb_type(vp) == MRB_TT_DATA && DATA_TYPE(vp) == &obj_type);
  return viewport_content(reinterpret_cast<lv_obj_t*>(DATA_PTR(vp)));
}

// Register a display object for z-ordering and give it a default z of 0.
void register_zobj(mrb_state* M, mrb_value v) {
  mrb_ary_push(M, zorder_objs(M), v);
  mrb_iv_set(M, v, mrb_intern_lit(M, "@x"), mrb_fixnum_value(0));
  mrb_iv_set(M, v, mrb_intern_lit(M, "@y"), mrb_fixnum_value(0));
  mrb_iv_set(M, v, mrb_intern_lit(M, "@z"), mrb_fixnum_value(0));
  update_z(M);
}

mrb_value spr_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);

  lv_obj_t* p = lv_canvas_create(parent_object(M, vp));
  wrap_lv_obj(M, self, p);
  register_zobj(M, self);
  // Keep the viewport alive as long as the sprite refers to it.
  mrb_iv_set(M, self, mrb_intern_lit(M, "@viewport"), vp);
  return self;
}

// Point the sprite's canvas at the bitmap it should display: the assigned
// bitmap directly, or — when the sprite is mirrored — a horizontally-flipped
// scratch copy (LVGL's lv_image has no flip, so mirroring is a software pass).
// The scratch Bitmap is kept in @_mirror_bitmap so it lives as long as the
// sprite and is freed with it. The flip is a snapshot taken here; a sprite that
// redraws its bitmap contents while mirrored must re-assign bitmap= (or set
// mirror= again) to refresh it (tracked in docs/rpgxp-rgss-api-gap.md).
static int clamp_byte(int v) {
  return v < 0 ? 0 : (v > 255 ? 255 : v);
}

// Apply an RGSS Tone to one pixel: desaturate toward its luminance by `gray`,
// then offset each channel. Shared by every composite that can be toned (a
// sprite, a plane, the tilemap), so they cannot drift apart.
static void apply_tone_px(int& r, int& g, int& b, const Tone& t) {
  const int gy = static_cast<int>(t.gray);
  if (gy != 0) {
    const int lum = (r * 77 + g * 150 + b * 29) / 256;
    r += (lum - r) * gy / 255;
    g += (lum - g) * gy / 255;
    b += (lum - b) * gy / 255;
  }
  r = clamp_byte(r + static_cast<int>(t.red));
  g = clamp_byte(g + static_cast<int>(t.green));
  b = clamp_byte(b + static_cast<int>(t.blue));
}

static bool tone_is_set(const Tone& t) {
  return t.red != 0 || t.green != 0 || t.blue != 0 || t.gray != 0;
}

// The tone of the viewport an object was created in, or a neutral tone when it
// has none. RGSS applies this to everything the viewport draws *after* each
// object's own tone/colour, so each composite folds it in as its last step --
// which is why a display object reads it here rather than the viewport reaching
// into the object. See vp_set_tone for how a change is propagated.
static Tone viewport_tone(mrb_state* M, mrb_value vp) {
  Tone t{};
  if (!mrb_test(vp) || !DATA_PTR(vp))
    return t;
  const mrb_value tv = mrb_iv_get(M, vp, mrb_intern_lit(M, "@tone"));
  if (mrb_test(tv) && DATA_PTR(tv))
    t = DataType<Tone>::get(M, tv);
  return t;
}

// Point the sprite's canvas at the bitmap it should display: the assigned
// bitmap directly, or — when the sprite is mirrored, toned or colour-overlaid —
// a scratch copy with those effects baked in (LVGL can express none of them, so
// they are a software pre-composite). The scratch Bitmap is kept in @_fx_bitmap
// so it lives as long as the sprite. The effects are a snapshot taken here; a
// sprite that redraws its bitmap, or mutates its tone/color in place, must
// re-assign bitmap= / tone= / color= to refresh (tracked in the gap doc).
void spr_bind_display(mrb_state* M, mrb_value self, lv_obj_t* obj) {
  const mrb_value bmp_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@bitmap"));
  if (mrb_nil_p(bmp_v))
    return;
  Bitmap& src = DataType<Bitmap>::get(M, bmp_v);

  const bool mirror =
      mrb_test(mrb_iv_get(M, self, mrb_intern_lit(M, "@mirror")));
  const mrb_value tone_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@tone"));
  const mrb_value color_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@color"));
  Tone tn{};
  Color cl{0, 0, 0, 0};
  if (mrb_test(tone_v) && DATA_PTR(tone_v))
    tn = DataType<Tone>::get(M, tone_v);
  if (mrb_test(color_v) && DATA_PTR(color_v))
    cl = DataType<Color>::get(M, color_v);
  const bool has_tone = tone_is_set(tn);
  const bool has_color = cl.alpha != 0;
  // The viewport's tone applies to everything it draws, so it is folded into
  // this composite after the sprite's own tone/colour/flash (RGSS tints the
  // viewport's contents, not its sources).
  const Tone vtn =
      viewport_tone(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@viewport")));
  const bool has_vp_tone = tone_is_set(vtn);

  // bush_depth: the bottom N rows are drawn at half opacity, so a character
  // wading through bushes fades out below the waist.
  const mrb_value bush_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@bush_depth"));
  const int bush = mrb_test(bush_v) ? mrb_as_int(M, bush_v) : 0;

  // flash: a timed colour pulse (Sprite#flash) that decays over its duration,
  // advanced one frame per Sprite#update. A colour flash overlays that colour
  // at a fading alpha; a nil-colour ("empty") flash instead blinks the sprite
  // out and back in.
  const mrb_value fcnt_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_count"));
  const mrb_value fdur_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_duration"));
  const mrb_value fcol_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_color"));
  const int flash_count = mrb_test(fcnt_v) ? mrb_as_int(M, fcnt_v) : 0;
  const int flash_dur = mrb_test(fdur_v) ? mrb_as_int(M, fdur_v) : 0;
  const bool flash_on = flash_count > 0 && flash_dur > 0;
  const bool flash_color_on = flash_on && mrb_test(fcol_v) && DATA_PTR(fcol_v);
  const bool flash_empty = flash_on && !flash_color_on;
  Color fcl{0, 0, 0, 0};
  if (flash_color_on)
    fcl = DataType<Color>::get(M, fcol_v);
  // Colour flash intensity fades from full (count == duration) to nothing.
  const int fa = flash_color_on
                     ? static_cast<int>(fcl.alpha) * flash_count / flash_dur
                     : 0;

  // src_rect: display only a sub-region of the bitmap (character-animation
  // cells set this every frame). A non-default rect crops to (cx, cy, cw, ch).
  int cx = 0, cy = 0, cw = src.width, ch = src.height;
  bool cropped = false;
  const mrb_value sr_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@src_rect"));
  if (mrb_test(sr_v) && DATA_PTR(sr_v)) {
    Rect& sr = DataType<Rect>::get(M, sr_v);
    if (sr.width > 0 && sr.height > 0 &&
        (sr.x != 0 || sr.y != 0 || sr.width != src.width ||
         sr.height != src.height)) {
      cx = sr.x;
      cy = sr.y;
      cw = sr.width;
      ch = sr.height;
      cropped = true;
    }
  }

  if (cropped || mirror || has_tone || has_color || has_vp_tone || bush > 0 ||
      flash_on) {
    // Reuse the scratch bitmap when its size still matches (src_rect changes
    // every frame, so re-allocating here would churn the GC).
    mrb_value fx_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@_fx_bitmap"));
    Bitmap* fxp = nullptr;
    if (mrb_test(fx_v) && DATA_PTR(fx_v)) {
      Bitmap& e = DataType<Bitmap>::get(M, fx_v);
      if (e.width == cw && e.height == ch && e.format == src.format)
        fxp = &e;
    }
    if (!fxp) {
      RClass* bmp_class =
          mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap");
      fx_v = DataType<Bitmap>::make(M, bmp_class, cw, ch, src.format);
      mrb_iv_set(M, self, mrb_intern_lit(M, "@_fx_bitmap"), fx_v);
      fxp = &DataType<Bitmap>::get(M, fx_v);
    }
    Bitmap& fx = *fxp;
    const int ca = static_cast<int>(cl.alpha);
    for (int y = 0; y < ch; ++y) {
      for (int x = 0; x < cw; ++x) {
        const int srcx = cx + (mirror ? cw - 1 - x : x);
        const int srcy = cy + y;
        int r = 0, g = 0, b = 0, a = 0;
        if (srcx >= 0 && srcy >= 0 && srcx < src.width && srcy < src.height)
          bmp_read(src, srcx, srcy, r, g, b, a);
        if (has_tone)
          apply_tone_px(r, g, b, tn);
        if (has_color) {
          r = clamp_byte(r + (static_cast<int>(cl.red) - r) * ca / 255);
          g = clamp_byte(g + (static_cast<int>(cl.green) - g) * ca / 255);
          b = clamp_byte(b + (static_cast<int>(cl.blue) - b) * ca / 255);
        }
        if (flash_color_on) {
          r = clamp_byte(r + (static_cast<int>(fcl.red) - r) * fa / 255);
          g = clamp_byte(g + (static_cast<int>(fcl.green) - g) * fa / 255);
          b = clamp_byte(b + (static_cast<int>(fcl.blue) - b) * fa / 255);
        }
        if (has_vp_tone)
          apply_tone_px(r, g, b, vtn);
        if (flash_empty)
          a = a * (flash_dur - flash_count) / flash_dur;
        if (bush > 0 && y >= ch - bush)
          a /= 2;
        bmp_put(fx, x, y, r, g, b, a);
      }
    }
    fx.dirty = true;
    lv_canvas_set_buffer(obj, fx.buffer.data(), cw, ch, src.format);
  } else {
    mrb_iv_set(M, self, mrb_intern_lit(M, "@_fx_bitmap"), mrb_nil_value());
    lv_canvas_set_buffer(obj, src.buffer.data(), src.width, src.height,
                         src.format);
  }
  // Repaint on the next Graphics.update, even if the contents were drawn before
  // the bitmap was attached to this sprite.
  src.dirty = true;
}

mrb_value spr_set_bmp(mrb_state* M, mrb_value self) {
  mrb_value bmp;
  mrb_get_args(M, "o", &bmp);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@bitmap"), bmp);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  spr_bind_display(M, self, obj);
  return bmp;
}

// RGSS Sprite#opacity= (0..255). The Sprite's native handle is an lv_canvas,
// which LVGL composites; the object-level style opacity multiplies the bitmap's
// own alpha at blit time, which is exactly RGSS's per-sprite opacity. The value
// is clamped and mirrored into @opacity so the Ruby reader (defaulting to 255)
// returns what was set. A fresh sprite needs no explicit call: LVGL's default
// object opacity is fully opaque, matching RGSS's 255 default.
mrb_value spr_set_opacity(mrb_state* M, mrb_value self) {
  mrb_int opa;
  mrb_get_args(M, "i", &opa);
  if (opa < 0)
    opa = 0;
  else if (opa > 255)
    opa = 255;
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  lv_obj_set_style_opa(obj, static_cast<lv_opa_t>(opa), 0);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@opacity"), mrb_fixnum_value(opa));
  return self;
}

// RGSS Sprite#zoom_x= / #zoom_y= (a float multiplier, 1.0 = normal size). A
// Sprite's native handle is an lv_canvas, an LVGL image that scales its content
// by an integer factor where LV_SCALE_NONE (256) == 1.0. Convert the RGSS float
// to that fixed point and apply it to the canvas; the float is mirrored into
// @zoom_x/@zoom_y so the Ruby reader (defaulting to 1.0) returns it. A fresh
// sprite is already LV_SCALE_NONE, matching RGSS's 1.0 default. mruby's "f"
// coerces an Integer argument (e.g. `zoom_x = 1`) to Float.
mrb_value spr_set_zoom_x(mrb_state* M, mrb_value self) {
  mrb_float z;
  mrb_get_args(M, "f", &z);
  if (z < 0.0)
    z = 0.0;
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  lv_image_set_scale_x(obj, static_cast<uint32_t>(z * LV_SCALE_NONE + 0.5));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@zoom_x"), mrb_float_value(M, z));
  return self;
}

mrb_value spr_set_zoom_y(mrb_state* M, mrb_value self) {
  mrb_float z;
  mrb_get_args(M, "f", &z);
  if (z < 0.0)
    z = 0.0;
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  lv_image_set_scale_y(obj, static_cast<uint32_t>(z * LV_SCALE_NONE + 0.5));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@zoom_y"), mrb_float_value(M, z));
  return self;
}

// RGSS Sprite#angle= (degrees, counter-clockwise, float). LVGL image rotation
// is in 0.1-degree units, clockwise, normalised to [0, 3600), so negate and
// scale. RGSS rotates about the sprite's (ox, oy) origin, which is the LVGL
// image pivot (default 0,0). The @ox/@oy ivars are read here so a script that
// sets the origin before rotating gets the right pivot; a later ox=/oy= that
// must re-pivot simply re-assigns angle. The float is mirrored into @angle for
// the Ruby reader.
mrb_value spr_set_angle(mrb_state* M, mrb_value self) {
  mrb_float deg;
  mrb_get_args(M, "f", &deg);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  long tenths = std::lround(-deg * 10.0) % 3600;
  if (tenths < 0)
    tenths += 3600;
  const mrb_value ox = mrb_iv_get(M, self, mrb_intern_lit(M, "@ox"));
  const mrb_value oy = mrb_iv_get(M, self, mrb_intern_lit(M, "@oy"));
  lv_image_set_pivot(
      obj, mrb_nil_p(ox) ? 0 : static_cast<int32_t>(mrb_as_int(M, ox)),
      mrb_nil_p(oy) ? 0 : static_cast<int32_t>(mrb_as_int(M, oy)));
  lv_image_set_rotation(obj, static_cast<int32_t>(tenths));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@angle"), mrb_float_value(M, deg));
  return self;
}

// RGSS Sprite#mirror= (horizontal flip). LVGL's lv_image has no flip, so this
// re-binds the canvas to a flipped scratch copy of the bitmap (or back to the
// bitmap itself) via spr_bind_display.
mrb_value spr_set_mirror(mrb_state* M, mrb_value self) {
  mrb_bool m;
  mrb_get_args(M, "b", &m);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@mirror"), mrb_bool_value(m));
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  spr_bind_display(M, self, obj);
  return self;
}

// RGSS Sprite#tone= (a Tone tint) and #color= (a Color overlay). Both are baked
// into the sprite's pixels by spr_bind_display, so assigning one re-composites.
mrb_value spr_set_tone(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@tone"), v);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  spr_bind_display(M, self, obj);
  return v;
}

mrb_value spr_set_color(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@color"), v);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  spr_bind_display(M, self, obj);
  return v;
}

// RGSS Sprite#src_rect= displays only a sub-rectangle of the bitmap.
mrb_value spr_set_src_rect(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@src_rect"), v);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  spr_bind_display(M, self, obj);
  return v;
}

// Per-frame tick: stock scripts (Sprite_Character etc.) mutate src_rect in
// place via `src_rect.set(...)` each frame, which does not call src_rect=, so a
// sprite that uses src_rect re-composites here to pick that up (and any
// tone/color change). An active flash also decays one frame here. Sprites with
// neither need no per-frame work.
mrb_value spr_update(mrb_state* M, mrb_value self) {
  bool recomposite = false;

  // Advance an active flash: it fades one frame per update and clears (dropping
  // its colour) once the duration runs out.
  const mrb_value fcnt = mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_count"));
  int fc = mrb_test(fcnt) ? mrb_as_int(M, fcnt) : 0;
  if (fc > 0) {
    --fc;
    mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_count"),
               mrb_fixnum_value(fc));
    if (fc == 0)
      mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_color"), mrb_nil_value());
    recomposite = true;
  }

  const mrb_value sr = mrb_iv_get(M, self, mrb_intern_lit(M, "@src_rect"));
  if (mrb_test(sr) && DATA_PTR(sr)) {
    Rect& r = DataType<Rect>::get(M, sr);
    if (r.width > 0 && r.height > 0)
      recomposite = true;
  }

  if (recomposite) {
    lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
    if (obj)
      spr_bind_display(M, self, obj);
  }
  return self;
}

// RGSS Sprite#blend_type= (0 normal, 1 add, 2 subtract) maps onto the sprite
// canvas object's LVGL blend mode, which the compositor uses when drawing it
// over the scene.
mrb_value spr_set_blend_type(mrb_state* M, mrb_value self) {
  mrb_int t;
  mrb_get_args(M, "i", &t);
  lv_blend_mode_t mode = LV_BLEND_MODE_NORMAL;
  if (t == 1)
    mode = LV_BLEND_MODE_ADDITIVE;
  else if (t == 2)
    mode = LV_BLEND_MODE_SUBTRACTIVE;
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  lv_obj_set_style_blend_mode(obj, mode, 0);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@blend_type"), mrb_fixnum_value(t));
  return self;
}

// RGSS Sprite#bush_depth= fades the bottom N rows of the sprite; baked into the
// composite by spr_bind_display, so assigning it re-composites.
mrb_value spr_set_bush_depth(mrb_state* M, mrb_value self) {
  mrb_int d;
  mrb_get_args(M, "i", &d);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@bush_depth"), mrb_fixnum_value(d));
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  spr_bind_display(M, self, obj);
  return self;
}

// RGSS Sprite#flash(color, duration) starts a timed colour pulse; a nil colour
// is an "empty" flash that blinks the sprite out. The state is baked into the
// composite by spr_bind_display and decayed each frame by spr_update.
mrb_value spr_flash(mrb_state* M, mrb_value self) {
  mrb_value color;
  mrb_int duration;
  mrb_get_args(M, "oi", &color, &duration);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_color"), color);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_duration"),
             mrb_fixnum_value(duration));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_count"),
             mrb_fixnum_value(duration));
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  spr_bind_display(M, self, obj);
  return mrb_nil_value();
}

mrb_value obj_set_x(mrb_state* M, mrb_value self) {
  mrb_int x;
  mrb_get_args(M, "i", &x);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  lv_obj_set_x(obj, x);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@x"), mrb_fixnum_value(x));
  return self;
}

mrb_value obj_set_y(mrb_state* M, mrb_value self) {
  mrb_int y;
  mrb_get_args(M, "i", &y);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  lv_obj_set_y(obj, y);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@y"), mrb_fixnum_value(y));
  return self;
}

mrb_value obj_set_z(mrb_state* M, mrb_value self) {
  mrb_int z;
  mrb_get_args(M, "i", &z);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@z"), mrb_fixnum_value(z));
  update_z(M);
  return self;
}

// Shared visible= for Sprite and Viewport: LVGL's HIDDEN flag also hides the
// whole child subtree, so hiding a Viewport hides everything drawn in it.
mrb_value obj_set_visible(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  if (v)
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_HIDDEN);
  else
    lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@visible"), mrb_bool_value(v));
  return self;
}

mrb_value obj_visible(mrb_state* M, mrb_value self) {
  mrb_value v = mrb_iv_get(M, self, mrb_intern_lit(M, "@visible"));
  return mrb_nil_p(v) ? mrb_true_value() : v;
}

// ---- Plane ----------------------------------------------------------------

// Redraw the plane's canvas: fill it by tiling the source bitmap, wrapping the
// ox/oy scroll around the bitmap's size. The canvas buffer is a scratch Bitmap
// (@_plane_canvas) sized to the viewport; bmp_read/bmp_put bridge any source /
// canvas format difference. The canvas is invalidated directly (its backing
// buffer is not the sprite @bitmap that Graphics.update's dirty sweep watches).
void plane_retile(mrb_state* M, mrb_value self) {
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  if (!obj)
    return;
  const mrb_value canvas_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_plane_canvas"));
  if (mrb_nil_p(canvas_v))
    return;
  Bitmap& dst = DataType<Bitmap>::get(M, canvas_v);
  const mrb_value bmp_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@bitmap"));
  if (mrb_nil_p(bmp_v)) {
    std::fill(dst.buffer.begin(), dst.buffer.end(), static_cast<uint8_t>(0));
    lv_obj_invalidate(obj);
    return;
  }
  Bitmap& src = DataType<Bitmap>::get(M, bmp_v);
  if (src.width <= 0 || src.height <= 0) {
    std::fill(dst.buffer.begin(), dst.buffer.end(), static_cast<uint8_t>(0));
    lv_obj_invalidate(obj);
    return;
  }
  const mrb_int ox =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@ox")));
  const mrb_int oy =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@oy")));

  // zoom_x/zoom_y scale the tiled pattern (nearest-neighbour): a zoom of 2.0
  // samples the source at half the rate, so the bitmap appears twice as large.
  // A non-positive or absent zoom is treated as 1.0 (the fast integer path).
  const mrb_value zx_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@zoom_x"));
  const mrb_value zy_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@zoom_y"));
  double zx = mrb_test(zx_v) ? mrb_as_float(M, zx_v) : 1.0;
  double zy = mrb_test(zy_v) ? mrb_as_float(M, zy_v) : 1.0;
  if (zx <= 0.0)
    zx = 1.0;
  if (zy <= 0.0)
    zy = 1.0;
  const bool scaled = zx != 1.0 || zy != 1.0;

  // Tone (grey desaturation + RGB offset) and colour overlay are baked into the
  // tiled buffer per pixel, the same way Sprite does — so a tinted fog/parallax
  // Plane renders its tint. (Same maths as spr_bind_display.)
  const mrb_value tone_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@tone"));
  const mrb_value color_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@color"));
  Tone tn{};
  Color cl{0, 0, 0, 0};
  if (mrb_test(tone_v) && DATA_PTR(tone_v))
    tn = DataType<Tone>::get(M, tone_v);
  if (mrb_test(color_v) && DATA_PTR(color_v))
    cl = DataType<Color>::get(M, color_v);
  const bool has_tone = tone_is_set(tn);
  const bool has_color = cl.alpha != 0;
  const int ca = static_cast<int>(cl.alpha);
  // ...and then the viewport's tone over the result, as for a sprite.
  const Tone vtn =
      viewport_tone(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@viewport")));
  const bool has_vp_tone = tone_is_set(vtn);

  for (int y = 0; y < dst.height; ++y) {
    const int syb = scaled ? static_cast<int>(std::floor((y + oy) / zy))
                           : static_cast<int>(y + oy);
    const int sy = (syb % src.height + src.height) % src.height;
    for (int x = 0; x < dst.width; ++x) {
      const int sxb = scaled ? static_cast<int>(std::floor((x + ox) / zx))
                             : static_cast<int>(x + ox);
      const int sx = (sxb % src.width + src.width) % src.width;
      int r, g, b, a;
      bmp_read(src, sx, sy, r, g, b, a);
      if (has_tone)
        apply_tone_px(r, g, b, tn);
      if (has_color) {
        r = clamp_byte(r + (static_cast<int>(cl.red) - r) * ca / 255);
        g = clamp_byte(g + (static_cast<int>(cl.green) - g) * ca / 255);
        b = clamp_byte(b + (static_cast<int>(cl.blue) - b) * ca / 255);
      }
      if (has_vp_tone)
        apply_tone_px(r, g, b, vtn);
      bmp_put(dst, x, y, r, g, b, a);
    }
  }
  lv_obj_invalidate(obj);
}

mrb_value plane_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);

  mrb_int w = 0, h = 0;
  if (mrb_nil_p(vp)) {
    lv_display_t* d = get_display(M);
    w = lv_display_get_horizontal_resolution(d);
    h = lv_display_get_vertical_resolution(d);
  } else {
    Rect& r =
        DataType<Rect>::get(M, mrb_iv_get(M, vp, mrb_intern_lit(M, "@rect")));
    w = r.width;
    h = r.height;
  }
  if (w <= 0)
    w = 1;
  if (h <= 0)
    h = 1;

  lv_obj_t* c = lv_canvas_create(parent_object(M, vp));
  wrap_lv_obj(M, self, c);
  register_zobj(M, self);
  lv_obj_set_pos(c, 0, 0);

  RClass* bmp_class =
      mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap");
  const mrb_value canvas_v =
      DataType<Bitmap>::make(M, bmp_class, w, h, LV_COLOR_FORMAT_ARGB8888);
  Bitmap& canvas = DataType<Bitmap>::get(M, canvas_v);
  std::fill(canvas.buffer.begin(), canvas.buffer.end(),
            static_cast<uint8_t>(0));
  lv_canvas_set_buffer(c, canvas.buffer.data(), w, h, LV_COLOR_FORMAT_ARGB8888);

  // Hold the canvas buffer (a Bitmap) and the viewport on the plane so the GC
  // keeps them alive for its lifetime.
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_plane_canvas"), canvas_v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@viewport"), vp);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@bitmap"), mrb_nil_value());
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(0));
  return self;
}

mrb_value plane_set_bmp(mrb_state* M, mrb_value self) {
  mrb_value bmp;
  mrb_get_args(M, "o", &bmp);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@bitmap"), bmp);
  plane_retile(M, self);
  return bmp;
}

mrb_value plane_set_ox(mrb_state* M, mrb_value self) {
  mrb_int ox;
  mrb_get_args(M, "i", &ox);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(ox));
  plane_retile(M, self);
  return self;
}

mrb_value plane_set_oy(mrb_state* M, mrb_value self) {
  mrb_int oy;
  mrb_get_args(M, "i", &oy);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(oy));
  plane_retile(M, self);
  return self;
}

// Plane#tone= / #color= tint the tiled buffer (baked in by plane_retile), so a
// fog/parallax Plane re-tiles with its new tint on assign.
mrb_value plane_set_tone(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@tone"), v);
  plane_retile(M, self);
  return v;
}

mrb_value plane_set_color(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@color"), v);
  plane_retile(M, self);
  return v;
}

// Plane#zoom_x= / #zoom_y= scale the tiled pattern; plane_retile samples the
// source at the reciprocal rate, so assigning a zoom re-tiles.
mrb_value plane_set_zoom_x(mrb_state* M, mrb_value self) {
  mrb_float z;
  mrb_get_args(M, "f", &z);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@zoom_x"), mrb_float_value(M, z));
  plane_retile(M, self);
  return self;
}

mrb_value plane_set_zoom_y(mrb_state* M, mrb_value self) {
  mrb_float z;
  mrb_get_args(M, "f", &z);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@zoom_y"), mrb_float_value(M, z));
  plane_retile(M, self);
  return self;
}

// ---- Tilemap --------------------------------------------------------------

// One RGSS map tile is 32x32 px; a tileset is 8 tiles (256 px) wide.
static const int TILE_SIZE = 32;
static const int TILESET_COLS = 8;

// Alpha-blended copy of a src region into dst (used to stack the map's tile
// layers, where upper-layer tiles are partly transparent).
static void blit_blend(Bitmap& dst,
                       int dx,
                       int dy,
                       const Bitmap& src,
                       int sx,
                       int sy,
                       int sw,
                       int sh) {
  for (int j = 0; j < sh; ++j) {
    const int ry = dy + j, syy = sy + j;
    if (ry < 0 || ry >= dst.height || syy < 0 || syy >= src.height)
      continue;
    for (int i = 0; i < sw; ++i) {
      const int rx = dx + i, sxx = sx + i;
      if (rx < 0 || rx >= dst.width || sxx < 0 || sxx >= src.width)
        continue;
      int r, g, b, a;
      bmp_read(src, sxx, syy, r, g, b, a);
      if (a <= 0)
        continue;
      if (a >= 255) {
        bmp_put(dst, rx, ry, r, g, b, 255);
        continue;
      }
      int dr, dg, db, da;
      bmp_read(dst, rx, ry, dr, dg, db, da);
      const int inv = 255 - a;
      bmp_put(dst, rx, ry, (r * a + dr * inv) / 255, (g * a + dg * inv) / 255,
              (b * a + db * inv) / 255, std::max(da, a));
    }
  }
}

// RMXP autotile quad table: 48 shapes x 4 quads (TL, TR, BL, BR), each the
// source (x,y) of a 16x16 piece in the 96x128 autotile bitmap. Derived from
// mkxp (Ancurio/mkxp, src/autotiles.cpp); the .5 texel-centre offsets there are
// floored for CPU sampling.
static const int AUTOTILE_QUADS[48][4][2] = {
    {{32, 64}, {48, 64}, {32, 80}, {48, 80}},
    {{64, 0}, {48, 64}, {32, 80}, {48, 80}},
    {{32, 64}, {80, 0}, {32, 80}, {48, 80}},
    {{64, 0}, {80, 0}, {32, 80}, {48, 80}},
    {{32, 64}, {48, 64}, {32, 80}, {80, 16}},
    {{64, 0}, {48, 64}, {32, 80}, {80, 16}},
    {{32, 64}, {80, 0}, {32, 80}, {80, 16}},
    {{64, 0}, {80, 0}, {32, 80}, {80, 16}},
    {{32, 64}, {48, 64}, {64, 16}, {48, 80}},
    {{64, 0}, {48, 64}, {64, 16}, {48, 80}},
    {{32, 64}, {80, 0}, {64, 16}, {48, 80}},
    {{64, 0}, {80, 0}, {64, 16}, {48, 80}},
    {{32, 64}, {48, 64}, {64, 16}, {80, 16}},
    {{64, 0}, {48, 64}, {64, 16}, {80, 16}},
    {{32, 64}, {80, 0}, {64, 16}, {80, 16}},
    {{64, 0}, {80, 0}, {64, 16}, {80, 16}},
    {{0, 64}, {16, 64}, {0, 80}, {16, 80}},
    {{0, 64}, {80, 0}, {0, 80}, {16, 80}},
    {{0, 64}, {16, 64}, {0, 80}, {80, 16}},
    {{0, 64}, {80, 0}, {0, 80}, {80, 16}},
    {{32, 32}, {48, 32}, {32, 48}, {48, 48}},
    {{32, 32}, {48, 32}, {32, 48}, {80, 16}},
    {{32, 32}, {48, 32}, {64, 16}, {48, 48}},
    {{32, 32}, {48, 32}, {64, 16}, {80, 16}},
    {{64, 64}, {80, 64}, {64, 80}, {80, 80}},
    {{64, 64}, {80, 64}, {64, 16}, {80, 80}},
    {{64, 0}, {80, 64}, {64, 80}, {80, 80}},
    {{64, 0}, {80, 64}, {64, 16}, {80, 80}},
    {{32, 96}, {48, 96}, {32, 112}, {48, 112}},
    {{64, 0}, {48, 96}, {32, 112}, {48, 112}},
    {{32, 96}, {80, 0}, {32, 112}, {48, 112}},
    {{64, 0}, {80, 0}, {32, 112}, {48, 112}},
    {{0, 64}, {80, 64}, {0, 80}, {80, 80}},
    {{32, 32}, {48, 32}, {32, 112}, {48, 112}},
    {{0, 32}, {16, 32}, {0, 48}, {16, 48}},
    {{0, 32}, {16, 32}, {0, 48}, {80, 16}},
    {{64, 32}, {80, 32}, {64, 48}, {80, 48}},
    {{64, 32}, {80, 32}, {64, 16}, {80, 48}},
    {{64, 96}, {80, 96}, {64, 112}, {80, 112}},
    {{64, 0}, {80, 96}, {64, 112}, {80, 112}},
    {{0, 96}, {16, 96}, {0, 112}, {16, 112}},
    {{0, 96}, {80, 0}, {0, 112}, {16, 112}},
    {{0, 32}, {80, 32}, {0, 48}, {80, 48}},
    {{0, 32}, {16, 32}, {0, 112}, {16, 112}},
    {{0, 96}, {80, 96}, {0, 112}, {80, 112}},
    {{64, 32}, {80, 32}, {64, 112}, {80, 112}},
    {{0, 32}, {80, 32}, {0, 112}, {80, 112}},
    {{0, 0}, {16, 0}, {0, 16}, {16, 16}},
};

// Destination offsets of the four autotile quads within a 32x32 tile, in the
// table's TL, TR, BL, BR order.
static const int AUTOTILE_QUAD_OFF[4][2] = {{0, 0}, {16, 0}, {0, 16}, {16, 16}};

// One autotile animation frame is 96px wide (3 tiles); animated autotiles pack
// several such frames left to right.
static const int AUTOTILE_FRAME_W = 96;

// ---- RPG Maker VX / VX Ace tile geometry ----------------------------------
//
// VX replaced XP's single tileset + seven autotiles with nine sheets (A1-A5,
// B-E) and packed everything into one tile id space, which `RPG::Map#data`
// stores and `RPG::Tileset#flags` describes:
//
//   0..255 B, 256..511 C, 512..767 D, 768..1023 E   plain tiles
//   1536.. A5                                        plain tiles
//   2048.. A1 (water/waterfall), 2816.. A2 (ground),
//   4352.. A3 (buildings), 5888.. A4 (walls)         autotiles, 48 shapes each
//
// An autotile id encodes both *which* autotile (kind) and *which of the 48
// edge shapes* it is drawn as; each shape is four 16x16 quarter-tiles taken
// from the sheet at an offset that depends on the family. The three quad tables
// and the family offsets below are ported from the MIT-licensed RPG Maker MV
// corescript (rpgtkoolmv/corescript, js/rpg_core/Tilemap.js), which inherited
// VX Ace's tile system unchanged -- the same provenance as the RMXP quads
// above, which came from mkxp.
//
// The geometry is pure arithmetic, so it is also exposed to Ruby as
// Tilemap.vx_tile_quads and pinned by mruby-rgss/test (the drawing itself needs
// a display the test binary has not got).

// Tile id boundaries (Tilemap.TILE_ID_* in the corescript).
static const int VX_TILE_ID_A5 = 1536;
static const int VX_TILE_ID_A1 = 2048;
static const int VX_TILE_ID_A2 = 2816;
static const int VX_TILE_ID_A3 = 4352;
static const int VX_TILE_ID_A4 = 5888;
static const int VX_TILE_ID_MAX = 8192;

// Quarter-tile (column, row) of each of the four quads (TL, TR, BL, BR) making
// up one of the 48 floor shapes, in half-tile units from the autotile's origin.
static const int VX_FLOOR_QUADS[48][4][2] = {
    {{2, 4}, {1, 4}, {2, 3}, {1, 3}}, {{2, 0}, {1, 4}, {2, 3}, {1, 3}},
    {{2, 4}, {3, 0}, {2, 3}, {1, 3}}, {{2, 0}, {3, 0}, {2, 3}, {1, 3}},
    {{2, 4}, {1, 4}, {2, 3}, {3, 1}}, {{2, 0}, {1, 4}, {2, 3}, {3, 1}},
    {{2, 4}, {3, 0}, {2, 3}, {3, 1}}, {{2, 0}, {3, 0}, {2, 3}, {3, 1}},
    {{2, 4}, {1, 4}, {2, 1}, {1, 3}}, {{2, 0}, {1, 4}, {2, 1}, {1, 3}},
    {{2, 4}, {3, 0}, {2, 1}, {1, 3}}, {{2, 0}, {3, 0}, {2, 1}, {1, 3}},
    {{2, 4}, {1, 4}, {2, 1}, {3, 1}}, {{2, 0}, {1, 4}, {2, 1}, {3, 1}},
    {{2, 4}, {3, 0}, {2, 1}, {3, 1}}, {{2, 0}, {3, 0}, {2, 1}, {3, 1}},
    {{0, 4}, {1, 4}, {0, 3}, {1, 3}}, {{0, 4}, {3, 0}, {0, 3}, {1, 3}},
    {{0, 4}, {1, 4}, {0, 3}, {3, 1}}, {{0, 4}, {3, 0}, {0, 3}, {3, 1}},
    {{2, 2}, {1, 2}, {2, 3}, {1, 3}}, {{2, 2}, {1, 2}, {2, 3}, {3, 1}},
    {{2, 2}, {1, 2}, {2, 1}, {1, 3}}, {{2, 2}, {1, 2}, {2, 1}, {3, 1}},
    {{2, 4}, {3, 4}, {2, 3}, {3, 3}}, {{2, 4}, {3, 4}, {2, 1}, {3, 3}},
    {{2, 0}, {3, 4}, {2, 3}, {3, 3}}, {{2, 0}, {3, 4}, {2, 1}, {3, 3}},
    {{2, 4}, {1, 4}, {2, 5}, {1, 5}}, {{2, 0}, {1, 4}, {2, 5}, {1, 5}},
    {{2, 4}, {3, 0}, {2, 5}, {1, 5}}, {{2, 0}, {3, 0}, {2, 5}, {1, 5}},
    {{0, 4}, {3, 4}, {0, 3}, {3, 3}}, {{2, 2}, {1, 2}, {2, 5}, {1, 5}},
    {{0, 2}, {1, 2}, {0, 3}, {1, 3}}, {{0, 2}, {1, 2}, {0, 3}, {3, 1}},
    {{2, 2}, {3, 2}, {2, 3}, {3, 3}}, {{2, 2}, {3, 2}, {2, 1}, {3, 3}},
    {{2, 4}, {3, 4}, {2, 5}, {3, 5}}, {{2, 0}, {3, 4}, {2, 5}, {3, 5}},
    {{0, 4}, {1, 4}, {0, 5}, {1, 5}}, {{0, 4}, {3, 0}, {0, 5}, {1, 5}},
    {{0, 2}, {3, 2}, {0, 3}, {3, 3}}, {{0, 2}, {1, 2}, {0, 5}, {1, 5}},
    {{0, 4}, {3, 4}, {0, 5}, {3, 5}}, {{2, 2}, {3, 2}, {2, 5}, {3, 5}},
    {{0, 2}, {3, 2}, {0, 5}, {3, 5}}, {{0, 0}, {1, 0}, {0, 1}, {1, 1}},
};

// Walls (A3, and the odd rows of A4) have 16 shapes instead of 48.
static const int VX_WALL_QUADS[16][4][2] = {
    {{2, 2}, {1, 2}, {2, 1}, {1, 1}}, {{0, 2}, {1, 2}, {0, 1}, {1, 1}},
    {{2, 0}, {1, 0}, {2, 1}, {1, 1}}, {{0, 0}, {1, 0}, {0, 1}, {1, 1}},
    {{2, 2}, {3, 2}, {2, 1}, {3, 1}}, {{0, 2}, {3, 2}, {0, 1}, {3, 1}},
    {{2, 0}, {3, 0}, {2, 1}, {3, 1}}, {{0, 0}, {3, 0}, {0, 1}, {3, 1}},
    {{2, 2}, {1, 2}, {2, 3}, {1, 3}}, {{0, 2}, {1, 2}, {0, 3}, {1, 3}},
    {{2, 0}, {1, 0}, {2, 3}, {1, 3}}, {{0, 0}, {1, 0}, {0, 3}, {1, 3}},
    {{2, 2}, {3, 2}, {2, 3}, {3, 3}}, {{0, 2}, {3, 2}, {0, 3}, {3, 3}},
    {{2, 0}, {3, 0}, {2, 3}, {3, 3}}, {{0, 0}, {3, 0}, {0, 3}, {3, 3}},
};

// A waterfall (the odd A1 kinds) has 4.
static const int VX_WATERFALL_QUADS[4][4][2] = {
    {{2, 0}, {1, 0}, {2, 1}, {1, 1}},
    {{0, 0}, {1, 0}, {0, 1}, {1, 1}},
    {{2, 0}, {3, 0}, {2, 1}, {3, 1}},
    {{0, 0}, {3, 0}, {0, 1}, {3, 1}},
};

// One 16x16 piece (or, for a table tile's split quad, 16x8) of a VX tile: which
// sheet it comes from, where in that sheet, and where in the 32x32 destination
// tile it goes.
struct VXQuad {
  int sheet, sx, sy, dx, dy, w, h;
};

// Decode a VX / VX Ace tile id into the pieces that draw it, writing them to
// `out` (at most 8, for a table tile whose quads are split) and returning how
// many. `frame` animates A1 (water surface / waterfall); `table` is the A2
// "table" flag (RPG::Tileset#flags bit 0x80), which redraws the tile's middle
// rows from the counter row so a table/counter edge shows its side.
//
// Mirrors Tilemap#_drawNormalTile / #_drawAutotile in the MV corescript,
// including its "a shape outside the family's table draws nothing" behaviour
// (walls have 16 shapes and waterfalls 4, against the floor's 48).
int vx_tile_quads(int tile_id, int frame, bool table, VXQuad out[8]) {
  if (tile_id <= 0 || tile_id >= VX_TILE_ID_MAX)
    return 0;
  const int half = TILE_SIZE / 2;

  // Plain tiles: A5 is sheet 4, the B/C/D/E pages are sheets 5..8.
  if (tile_id < VX_TILE_ID_A1) {
    const int sheet = tile_id >= VX_TILE_ID_A5 ? 4 : 5 + tile_id / 256;
    // 1024..1535 fall past the E page and short of A5: no sheet holds them, and
    // the corescript draws nothing for such an id (its bitmaps[9] is
    // undefined).
    if (sheet > 8)
      return 0;
    const int sx = (tile_id / 128 % 2 * 8 + tile_id % 8) * TILE_SIZE;
    const int sy = (tile_id % 256 / 8 % 16) * TILE_SIZE;
    out[0] = VXQuad{sheet, sx, sy, 0, 0, TILE_SIZE, TILE_SIZE};
    return 1;
  }

  // Autotiles: the id carries both the autotile (kind) and one of the shapes.
  const int kind = (tile_id - VX_TILE_ID_A1) / 48;
  const int shape = (tile_id - VX_TILE_ID_A1) % 48;
  const int tx = kind % 8;
  const int ty = kind / 8;
  int sheet = 0, bx = 0, by = 0;
  const int (*quad_table)[4][2] = VX_FLOOR_QUADS;
  int shape_count = 48;
  bool is_table = false;

  if (tile_id < VX_TILE_ID_A2) {
    // A1: water surfaces animate over three frames in a 0,1,2,1 cycle, and the
    // odd kinds are waterfalls with their own three-frame cycle and table.
    static const int kWaterSurface[4] = {0, 1, 2, 1};
    const int surface = kWaterSurface[((frame % 4) + 4) % 4];
    sheet = 0;
    if (kind == 0) {
      bx = surface * 2;
      by = 0;
    } else if (kind == 1) {
      bx = surface * 2;
      by = 3;
    } else if (kind == 2) {
      bx = 6;
      by = 0;
    } else if (kind == 3) {
      bx = 6;
      by = 3;
    } else {
      bx = tx / 4 * 8;
      by = ty * 6 + tx / 2 % 2 * 3;
      if (kind % 2 == 0) {
        bx += surface * 2;
      } else {
        bx += 6;
        quad_table = VX_WATERFALL_QUADS;
        shape_count = 4;
        by += ((frame % 3) + 3) % 3;
      }
    }
  } else if (tile_id < VX_TILE_ID_A3) {
    sheet = 1;
    bx = tx * 2;
    by = (ty - 2) * 3;
    is_table = table;
  } else if (tile_id < VX_TILE_ID_A4) {
    sheet = 2;
    bx = tx * 2;
    by = (ty - 6) * 2;
    quad_table = VX_WALL_QUADS;
    shape_count = 16;
  } else {
    sheet = 3;
    bx = tx * 2;
    // A4 alternates ground rows (three half-tiles tall) and wall rows (two), so
    // the row offset advances by 2.5 with a half-row shift on the wall rows:
    // floor((ty - 10) * 2.5 + (ty odd ? 0.5 : 0)).
    by = ((ty - 10) * 5 + (ty % 2 == 1 ? 1 : 0)) / 2;
    if (ty % 2 == 1) {
      quad_table = VX_WALL_QUADS;
      shape_count = 16;
    }
  }

  if (shape >= shape_count)
    return 0;

  int n = 0;
  for (int i = 0; i < 4; ++i) {
    const int qsx = quad_table[shape][i][0];
    const int qsy = quad_table[shape][i][1];
    const int sx = (bx * 2 + qsx) * half;
    const int sy = (by * 2 + qsy) * half;
    const int dx = (i % 2) * half;
    const int dy = (i / 2) * half;
    if (is_table && (qsy == 1 || qsy == 5)) {
      // A table tile's middle rows come from the counter row, with the original
      // strip drawn over the bottom half so the edge reads as a side.
      static const int kTableX[4] = {0, 3, 2, 1};
      const int qsx2 = qsy == 1 ? kTableX[qsx % 4] : qsx;
      out[n++] = VXQuad{
          sheet, (bx * 2 + qsx2) * half, (by * 2 + 3) * half, dx, dy, half,
          half};
      out[n++] = VXQuad{sheet, sx, sy, dx, dy + half / 2, half, half / 2};
    } else {
      out[n++] = VXQuad{sheet, sx, sy, dx, dy, half, half};
    }
  }
  return n;
}

// z of the priority "above" layer (see the split in tilemap_refresh). INTERIM:
// a single flat layer above the characters is only an approximation of RMXP's
// per-row priority interleaving — it puts *every* priority tile above *every*
// character, rather than only the ones on lower rows. The full per-row scheme
// is designed in docs/adr/0022-rpgxp-tilemap-priority-layering.md. This
// constant is picked to sit above stock character sprites (z ~ screen_y, up to
// ~512) but below the fog/weather planes (z ~ 1000/3000); confirm it in-game
// against the testbed Spriteset_Map before treating it as final.
static const mrb_int TILEMAP_ABOVE_Z = 900;

// Redraw the visible part of the map. For each of the three map-data layers,
// the tiles overlapping the viewport (given ox/oy) are blitted from the tileset
// (regular tiles, id >= 384) or assembled from the four autotile quads (id
// 48..383), with autotile animation. Priority-0 tiles draw into the ground
// canvas; priority >= 1 tiles (from the `priorities` table) draw into the
// separate "above" canvas that sorts over the characters (see TILEMAP_ABOVE_Z).
// Both canvases are invalidated directly (their buffers are not sprite @bitmaps
// that Graphics.update's dirty sweep watches).
// Whether a tilemap has been handed any of the nine VX / VX Ace sheets, which
// is what tells the two tile models apart at draw time.
bool vx_has_sheets(mrb_state* M, mrb_value bitmaps) {
  if (!mrb_array_p(bitmaps))
    return false;
  for (mrb_int i = 0; i < RARRAY_LEN(bitmaps); ++i) {
    const mrb_value b = mrb_ary_ref(M, bitmaps, i);
    if (mrb_test(b) && DATA_PTR(b))
      return true;
  }
  return false;
}

// Draw a VX / VX Ace map into the ground (and priority "above") canvases.
// Returns whether the visible area holds an animated tile, so tilemap_update
// can skip the periodic re-tile on a static map.
//
// The three tile layers of `map_data` are drawn bottom-up. `RPG::Tileset#flags`
// carries the per-tile bits: 0x10 routes a tile to the above layer (MV's
// `_isHigherTile`) and 0x80 marks an A2 "table" tile, whose middle rows are
// redrawn from the counter row.
bool tilemap_refresh_vx(mrb_state* M,
                        mrb_value self,
                        Bitmap& dst,
                        Bitmap* above,
                        mrb_value bitmaps,
                        mrb_value md_v,
                        mrb_int ox,
                        mrb_int oy,
                        int anim) {
  Table& md = DataType<Table>::get(M, md_v);
  const mrb_value flags_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@flags"));
  Table* flags = (mrb_test(flags_v) && DATA_PTR(flags_v))
                     ? &DataType<Table>::get(M, flags_v)
                     : nullptr;

  const int mapw = md.xsize, maph = md.ysize;
  // Layer 3 of a VX Ace map holds region ids, which are not drawn.
  const int layers = md.zsize < 3 ? md.zsize : 3;
  // MV advances the tile animation every 30 ticks; ours counts frames the same
  // way the XP path does.
  const int frame = anim / 30;
  bool animated = false;

  int tx0 = static_cast<int>(ox) / TILE_SIZE;
  int ty0 = static_cast<int>(oy) / TILE_SIZE;
  if (tx0 < 0)
    tx0 = 0;
  if (ty0 < 0)
    ty0 = 0;
  int tx1 = static_cast<int>(ox + dst.width) / TILE_SIZE + 1;
  int ty1 = static_cast<int>(oy + dst.height) / TILE_SIZE + 1;
  if (tx1 > mapw)
    tx1 = mapw;
  if (ty1 > maph)
    ty1 = maph;

  VXQuad quads[8];
  for (int layer = 0; layer < layers; ++layer) {
    for (int ty = ty0; ty < ty1; ++ty) {
      for (int tx = tx0; tx < tx1; ++tx) {
        const int idx = tx + ty * mapw + layer * mapw * maph;
        if (idx < 0 || idx >= static_cast<int>(md.data.size()))
          continue;
        const int id = md.data[idx];
        if (id <= 0)
          continue;
        const int flag =
            (flags && id >= 0 && id < static_cast<int>(flags->data.size()))
                ? flags->data[id]
                : 0;
        const bool is_table =
            id >= VX_TILE_ID_A2 && id < VX_TILE_ID_A3 && (flag & 0x80) != 0;
        const int n = vx_tile_quads(id, frame, is_table, quads);
        if (n == 0)
          continue;
        // The A1 page (water and waterfalls) is the animated one.
        if (id >= VX_TILE_ID_A1 && id < VX_TILE_ID_A2)
          animated = true;

        Bitmap& target = ((flag & 0x10) != 0 && above) ? *above : dst;
        const int dx0 = tx * TILE_SIZE - static_cast<int>(ox);
        const int dy0 = ty * TILE_SIZE - static_cast<int>(oy);
        for (int q = 0; q < n; ++q) {
          const VXQuad& v = quads[q];
          const mrb_value sheet_v = mrb_ary_ref(M, bitmaps, v.sheet);
          if (!mrb_test(sheet_v) || !DATA_PTR(sheet_v))
            continue;
          Bitmap& sheet = DataType<Bitmap>::get(M, sheet_v);
          blit_blend(target, dx0 + v.dx, dy0 + v.dy, sheet, v.sx, v.sy, v.w,
                     v.h);
        }
      }
    }
  }
  return animated;
}

// Tint the tilemap's composed canvases with its viewport's tone. The map has no
// tone of its own, so this is purely the viewport's -- and it has to happen
// here rather than per source tile, because a tone rescales the *drawn* result.
// Both the ground canvas and the priority "above" canvas are covered, so a
// tinted map tints its roofs too.
void tilemap_apply_viewport_tone(mrb_state* M,
                                 mrb_value self,
                                 Bitmap& dst,
                                 Bitmap* above) {
  const Tone tn =
      viewport_tone(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@viewport")));
  if (!tone_is_set(tn))
    return;
  Bitmap* targets[2] = {&dst, above};
  for (Bitmap* t : targets) {
    if (!t)
      continue;
    for (int y = 0; y < t->height; ++y) {
      for (int x = 0; x < t->width; ++x) {
        int r, g, b, a;
        bmp_read(*t, x, y, r, g, b, a);
        if (a == 0)
          continue;
        apply_tone_px(r, g, b, tn);
        bmp_put(*t, x, y, r, g, b, a);
      }
    }
    t->dirty = true;
  }
}

void tilemap_refresh(mrb_state* M, mrb_value self) {
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  if (!obj)
    return;
  const mrb_value canvas_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_canvas"));
  if (mrb_nil_p(canvas_v))
    return;
  Bitmap& dst = DataType<Bitmap>::get(M, canvas_v);
  std::fill(dst.buffer.begin(), dst.buffer.end(), static_cast<uint8_t>(0));

  // The priority "above" canvas (companion object created in tilemap_init) and
  // its LVGL object, so priority tiles can be routed to it and it can be
  // invalidated alongside the ground canvas.
  const mrb_value above_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_above_canvas"));
  Bitmap* above = (mrb_test(above_v) && DATA_PTR(above_v))
                      ? &DataType<Bitmap>::get(M, above_v)
                      : nullptr;
  if (above)
    std::fill(above->buffer.begin(), above->buffer.end(),
              static_cast<uint8_t>(0));
  const mrb_value above_obj_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_above_obj"));
  lv_obj_t* above_lv = (mrb_test(above_obj_v) && DATA_PTR(above_obj_v))
                           ? reinterpret_cast<lv_obj_t*>(DATA_PTR(above_obj_v))
                           : nullptr;

  // Per-tile priority table (0..5 per tile id); tiles with priority >= 1 draw
  // into the above layer. A nil or short table leaves everything at priority 0.
  const mrb_value pr_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@priorities"));
  Table* pr = (mrb_test(pr_v) && DATA_PTR(pr_v))
                  ? &DataType<Table>::get(M, pr_v)
                  : nullptr;

  const mrb_value ts_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@tileset"));
  const mrb_value md_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@map_data"));

  // RPG Maker VX / VX Ace address their nine sheets through `bitmaps` instead
  // of XP's single `tileset` + `autotiles`, and describe each tile with the
  // `flags` table rather than `priorities`. A tilemap that has been given any
  // sheet is drawn the VX way; everything below stays the XP path.
  const mrb_value bmps_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@bitmaps"));
  if (vx_has_sheets(M, bmps_v) && mrb_test(md_v) && DATA_PTR(md_v)) {
    const mrb_value anim_v =
        mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_anim"));
    const bool animated = tilemap_refresh_vx(
        M, self, dst, above, bmps_v, md_v,
        mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@ox"))),
        mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@oy"))),
        mrb_test(anim_v) ? mrb_as_int(M, anim_v) : 0);
    mrb_iv_set(M, self, mrb_intern_lit(M, "@_tm_animated"),
               mrb_bool_value(animated));
    tilemap_apply_viewport_tone(M, self, dst, above);
    dst.dirty = true;
    if (above)
      above->dirty = true;
    lv_obj_invalidate(obj);
    if (above_lv)
      lv_obj_invalidate(above_lv);
    return;
  }

  if (!mrb_test(ts_v) || !DATA_PTR(ts_v) || !mrb_test(md_v) ||
      !DATA_PTR(md_v)) {
    lv_obj_invalidate(obj);
    if (above_lv)
      lv_obj_invalidate(above_lv);
    return;
  }
  Bitmap& ts = DataType<Bitmap>::get(M, ts_v);
  Table& md = DataType<Table>::get(M, md_v);
  const int cols = ts.width >= TILE_SIZE ? ts.width / TILE_SIZE : TILESET_COLS;
  const int mapw = md.xsize, maph = md.ysize;
  const int layers = md.zsize < 3 ? md.zsize : 3;
  const mrb_int ox =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@ox")));
  const mrb_int oy =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@oy")));
  const mrb_value autotiles_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@autotiles"));
  const bool have_autotiles = mrb_array_p(autotiles_v);

  // Autotile animation: an autotile bitmap wider than one 96px frame holds
  // several animation frames side by side. RMXP shows each of the four frames
  // for 16 ticks (mkxp's atAnimation table), so the current frame is the tick
  // counter / 16, mod 4. `any_anim` records whether this map actually has an
  // animated autotile, so tilemap_update can skip the periodic re-tile when the
  // map is static.
  const mrb_value anim_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_anim"));
  const int anim = mrb_test(anim_v) ? mrb_as_int(M, anim_v) : 0;
  const int frame_idx = (anim / 16) % 4;
  bool any_anim = false;

  int tx0 = static_cast<int>(ox) / TILE_SIZE;
  int ty0 = static_cast<int>(oy) / TILE_SIZE;
  if (tx0 < 0)
    tx0 = 0;
  if (ty0 < 0)
    ty0 = 0;
  int tx1 = static_cast<int>(ox + dst.width) / TILE_SIZE + 1;
  int ty1 = static_cast<int>(oy + dst.height) / TILE_SIZE + 1;
  if (tx1 > mapw)
    tx1 = mapw;
  if (ty1 > maph)
    ty1 = maph;

  for (int layer = 0; layer < layers; ++layer) {
    for (int ty = ty0; ty < ty1; ++ty) {
      for (int tx = tx0; tx < tx1; ++tx) {
        const int idx = tx + ty * mapw + layer * mapw * maph;
        if (idx < 0 || idx >= static_cast<int>(md.data.size()))
          continue;
        const int id = md.data[idx];
        if (id < 48)  // 0 = empty; 1..47 are the unused blank autotile
          continue;
        const int dx0 = tx * TILE_SIZE - static_cast<int>(ox);
        const int dy0 = ty * TILE_SIZE - static_cast<int>(oy);
        // Priority 0 -> ground canvas; priority >= 1 -> above canvas (when one
        // exists). An out-of-range id or nil table means priority 0.
        const int prio =
            (pr && id >= 0 && id < static_cast<int>(pr->data.size()))
                ? pr->data[id]
                : 0;
        Bitmap& target = (prio > 0 && above) ? *above : dst;
        if (id < 384) {
          // Autotile: id/48 selects autotiles[0..6], id%48 the 48-shape quad
          // assembly. Uses the first animation frame (x offset 0).
          if (!have_autotiles)
            continue;
          const mrb_value at = mrb_ary_ref(M, autotiles_v, id / 48 - 1);
          if (!mrb_test(at) || !DATA_PTR(at))
            continue;
          Bitmap& ab = DataType<Bitmap>::get(M, at);
          const int shape = id % 48;
          // Animated autotile: shift the source into the current frame's 96px
          // column. A single-frame (96px-wide) autotile stays at offset 0.
          int sx_off = 0;
          if (ab.width > AUTOTILE_FRAME_W) {
            any_anim = true;
            sx_off =
                (frame_idx % (ab.width / AUTOTILE_FRAME_W)) * AUTOTILE_FRAME_W;
          }
          for (int q = 0; q < 4; ++q)
            blit_blend(target, dx0 + AUTOTILE_QUAD_OFF[q][0],
                       dy0 + AUTOTILE_QUAD_OFF[q][1], ab,
                       AUTOTILE_QUADS[shape][q][0] + sx_off,
                       AUTOTILE_QUADS[shape][q][1], 16, 16);
        } else {
          // Regular tile from the tileset.
          const int ti = id - 384;
          blit_blend(target, dx0, dy0, ts, (ti % cols) * TILE_SIZE,
                     (ti / cols) * TILE_SIZE, TILE_SIZE, TILE_SIZE);
        }
      }
    }
  }
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tm_animated"),
             mrb_bool_value(any_anim));
  tilemap_apply_viewport_tone(M, self, dst, above);
  if (above)
    above->dirty = true;
  lv_obj_invalidate(obj);
  if (above_lv)
    lv_obj_invalidate(above_lv);
}

mrb_value tilemap_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);

  mrb_int w = 0, h = 0;
  if (mrb_nil_p(vp)) {
    lv_display_t* d = get_display(M);
    w = lv_display_get_horizontal_resolution(d);
    h = lv_display_get_vertical_resolution(d);
  } else {
    Rect& r =
        DataType<Rect>::get(M, mrb_iv_get(M, vp, mrb_intern_lit(M, "@rect")));
    w = r.width;
    h = r.height;
  }
  if (w <= 0)
    w = 1;
  if (h <= 0)
    h = 1;

  lv_obj_t* c = lv_canvas_create(parent_object(M, vp));
  wrap_lv_obj(M, self, c);
  register_zobj(M, self);
  lv_obj_set_pos(c, 0, 0);

  RClass* bmp_class =
      mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap");
  const mrb_value canvas_v =
      DataType<Bitmap>::make(M, bmp_class, w, h, LV_COLOR_FORMAT_ARGB8888);
  Bitmap& canvas = DataType<Bitmap>::get(M, canvas_v);
  std::fill(canvas.buffer.begin(), canvas.buffer.end(),
            static_cast<uint8_t>(0));
  lv_canvas_set_buffer(c, canvas.buffer.data(), w, h, LV_COLOR_FORMAT_ARGB8888);

  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tm_canvas"), canvas_v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@viewport"), vp);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@tileset"), mrb_nil_value());
  mrb_iv_set(M, self, mrb_intern_lit(M, "@map_data"), mrb_nil_value());
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tm_anim"), mrb_fixnum_value(0));

  // Priority "above" layer: a second canvas in the same parent, wrapped as an
  // internal companion display object so the shared z-order (gfx_update) sorts
  // it against the character sprites. It is held on the tilemap so the GC keeps
  // it alive, and torn down in tilemap_dispose. Follows the same
  // wrap_lv_obj/on_lv_delete/register_zobj pattern as a Sprite.
  lv_obj_t* ac = lv_canvas_create(parent_object(M, vp));
  lv_obj_set_pos(ac, 0, 0);
  const mrb_value above_obj = mrb_obj_value(
      mrb_data_object_alloc(M, mrb_obj_class(M, self), ac, &obj_type));
  lv_obj_set_user_data(ac, mrb_ptr(above_obj));
  lv_obj_add_event_cb(ac, on_lv_delete, LV_EVENT_DELETE, nullptr);
  register_zobj(M, above_obj);
  mrb_iv_set(M, above_obj, mrb_intern_lit(M, "@z"),
             mrb_fixnum_value(TILEMAP_ABOVE_Z));
  update_z(M);
  const mrb_value above_canvas_v =
      DataType<Bitmap>::make(M, bmp_class, w, h, LV_COLOR_FORMAT_ARGB8888);
  Bitmap& above_canvas = DataType<Bitmap>::get(M, above_canvas_v);
  std::fill(above_canvas.buffer.begin(), above_canvas.buffer.end(),
            static_cast<uint8_t>(0));
  lv_canvas_set_buffer(ac, above_canvas.buffer.data(), w, h,
                       LV_COLOR_FORMAT_ARGB8888);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tm_above_obj"), above_obj);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tm_above_canvas"), above_canvas_v);
  return self;
}

// Tearing down the tilemap also tears down its companion "above" canvas (a
// separate LVGL object that obj_dispose on the tilemap would otherwise leave
// on screen and in the z-order set).
mrb_value tilemap_dispose(mrb_state* M, mrb_value self) {
  const mrb_value above =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_above_obj"));
  if (mrb_test(above) && DATA_PTR(above))
    obj_dispose(M, above);
  return obj_dispose(M, self);
}

// Per-frame tick: advance the autotile animation. The counter cycles 0..63 and
// the frame it selects is counter / 16, so only every 16th update crosses a
// frame boundary and needs a re-tile — and only when the map has an animated
// autotile at all (recorded by tilemap_refresh). A static map does no work.
mrb_value tilemap_update(mrb_state* M, mrb_value self) {
  if (!mrb_test(mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_animated"))))
    return self;
  const mrb_value anim_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_anim"));
  const int anim = mrb_test(anim_v) ? mrb_as_int(M, anim_v) : 0;
  const int next = (anim + 1) % 64;
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tm_anim"), mrb_fixnum_value(next));
  if (anim / 16 != next / 16)
    tilemap_refresh(M, self);
  return self;
}

mrb_value tilemap_set_tileset(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@tileset"), v);
  tilemap_refresh(M, self);
  return v;
}

mrb_value tilemap_set_map_data(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@map_data"), v);
  tilemap_refresh(M, self);
  return v;
}

// Native so assigning the priority table (usually right after map_data=)
// re-renders the ground/above split. A plain attr_writer would not.
mrb_value tilemap_set_priorities(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@priorities"), v);
  tilemap_refresh(M, self);
  return v;
}

// RGSS2/RGSS3 `Tilemap#bitmaps`: the nine sheets (A1-A5, then B, C, D, E),
// addressed by index. The scripts assign into it — `@tilemap.bitmaps[i] =
// Cache.tileset(name)` — so hand back the same Array every time and let the
// next refresh pick the change up (Spriteset_Map calls #update every frame).
mrb_value tilemap_bitmaps(mrb_state* M, mrb_value self) {
  mrb_value a = mrb_iv_get(M, self, mrb_intern_lit(M, "@bitmaps"));
  if (!mrb_array_p(a)) {
    a = mrb_ary_new_capa(M, 9);
    for (int i = 0; i < 9; ++i)
      mrb_ary_push(M, a, mrb_nil_value());
    mrb_iv_set(M, self, mrb_intern_lit(M, "@bitmaps"), a);
  }
  return a;
}

// RGSS2/RGSS3 `Tilemap#flags=`: RPG::Tileset#flags, one word per tile id
// (0x10 = draw above the characters, 0x80 = an A2 table tile, plus the
// passage/terrain bits the game logic reads).
mrb_value tilemap_set_flags(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@flags"), v);
  tilemap_refresh(M, self);
  return v;
}

// Tilemap.vx_tile_quads(tile_id, frame = 0, table = false) -> [[sheet, sx, sy,
// dx, dy, w, h], ...]
//
// The VX / VX Ace tile geometry, exposed so it can be pinned by unit tests: the
// drawing needs a display the headless test binary has not got, but the decode
// is pure arithmetic. Answers an empty Array for an id that draws nothing.
mrb_value tilemap_vx_tile_quads(mrb_state* M, mrb_value self) {
  mrb_int tile_id = 0, frame = 0;
  mrb_bool table = FALSE;
  mrb_get_args(M, "i|ib", &tile_id, &frame, &table);
  VXQuad quads[8];
  const int n = vx_tile_quads(static_cast<int>(tile_id),
                              static_cast<int>(frame), table != 0, quads);
  mrb_value out = mrb_ary_new_capa(M, n);
  for (int i = 0; i < n; ++i) {
    const VXQuad& q = quads[i];
    mrb_value row = mrb_ary_new_capa(M, 7);
    mrb_ary_push(M, row, mrb_fixnum_value(q.sheet));
    mrb_ary_push(M, row, mrb_fixnum_value(q.sx));
    mrb_ary_push(M, row, mrb_fixnum_value(q.sy));
    mrb_ary_push(M, row, mrb_fixnum_value(q.dx));
    mrb_ary_push(M, row, mrb_fixnum_value(q.dy));
    mrb_ary_push(M, row, mrb_fixnum_value(q.w));
    mrb_ary_push(M, row, mrb_fixnum_value(q.h));
    mrb_ary_push(M, out, row);
  }
  return out;
}

// Show/hide the tilemap, propagating to the priority "above" layer so a hidden
// tilemap hides its roofs too (the above canvas is a separate LVGL object that
// obj_set_visible on the tilemap alone would leave showing).
mrb_value tilemap_set_visible(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  const mrb_value above =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_tm_above_obj"));
  lv_obj_t* al = (mrb_test(above) && DATA_PTR(above))
                     ? reinterpret_cast<lv_obj_t*>(DATA_PTR(above))
                     : nullptr;
  if (v) {
    lv_obj_remove_flag(obj, LV_OBJ_FLAG_HIDDEN);
    if (al)
      lv_obj_remove_flag(al, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(obj, LV_OBJ_FLAG_HIDDEN);
    if (al)
      lv_obj_add_flag(al, LV_OBJ_FLAG_HIDDEN);
  }
  mrb_iv_set(M, self, mrb_intern_lit(M, "@visible"), mrb_bool_value(v));
  return self;
}

mrb_value tilemap_set_ox(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(v));
  tilemap_refresh(M, self);
  return self;
}

mrb_value tilemap_set_oy(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(v));
  tilemap_refresh(M, self);
  return self;
}

// ---- Window ---------------------------------------------------------------

mrb_value make_rect(mrb_state* M, mrb_int x, mrb_int y, mrb_int w, mrb_int h);

// RGSS insets a window's contents 16px from its frame on every side, so the
// drawable content area is (width - 32) x (height - 32).
static const int WINDOW_PADDING = 16;

// (Re)allocate the window's canvas Bitmap to w x h when the size changes and
// point the lv_canvas at it. Held in @_win_canvas so the GC keeps it alive.
Bitmap& window_ensure_canvas(mrb_state* M,
                             mrb_value self,
                             mrb_int w,
                             mrb_int h) {
  if (w < 1)
    w = 1;
  if (h < 1)
    h = 1;
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  const mrb_value cur = mrb_iv_get(M, self, mrb_intern_lit(M, "@_win_canvas"));
  if (!mrb_nil_p(cur)) {
    Bitmap& c = DataType<Bitmap>::get(M, cur);
    if (c.width == w && c.height == h)
      return c;
  }
  RClass* bmp_class =
      mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap");
  const mrb_value cv =
      DataType<Bitmap>::make(M, bmp_class, w, h, LV_COLOR_FORMAT_ARGB8888);
  Bitmap& c = DataType<Bitmap>::get(M, cv);
  lv_canvas_set_buffer(obj, c.buffer.data(), w, h, LV_COLOR_FORMAT_ARGB8888);
  lv_obj_set_size(obj, w, h);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_win_canvas"), cv);
  return c;
}

// An integer ivar, or `dflt` when it was never assigned. The RGSS2/RGSS3-only
// window attributes are plain state the scripts drive, so a window that
// predates them -- an RGSS1 one, or a VX one before its first `openness=` --
// has no such ivar at all.
static mrb_int iv_int_or(mrb_state* M,
                         mrb_value self,
                         const char* iv,
                         mrb_int dflt) {
  const mrb_value v = mrb_iv_get(M, self, mrb_intern_cstr(M, iv));
  return mrb_nil_p(v) ? dflt : mrb_as_int(M, v);
}

// RGSS2/RGSS3 Window#tone: a colour tone over the window's *background*, not
// its frame and not its contents. Applied to the whole canvas right after the
// background is laid down and before anything is drawn on top, which is what
// confines it to the background without a second buffer.
//
// Unlike Viewport#tone this is not folded in by each child: a window composites
// itself, so it tones its own pixels. The per-pixel maths is the shared
// apply_tone_px, so the three tone paths cannot drift apart.
static void window_apply_tone(mrb_state* M, mrb_value self, Bitmap& canvas) {
  const mrb_value tv = mrb_iv_get(M, self, mrb_intern_lit(M, "@tone"));
  if (!mrb_test(tv) || !DATA_PTR(tv))
    return;
  const Tone& tn = DataType<Tone>::get(M, tv);
  if (!tone_is_set(tn))
    return;
  for (int y = 0; y < canvas.height; ++y) {
    for (int x = 0; x < canvas.width; ++x) {
      int r, g, b, a;
      bmp_read(canvas, x, y, r, g, b, a);
      if (a == 0)
        continue;
      apply_tone_px(r, g, b, tn);
      bmp_put(canvas, x, y, r, g, b, a);
    }
  }
  canvas.dirty = true;
}

// An opacity ivar clamped to 0..255, defaulting to RGSS's 255 when the script
// never assigned one. It used to read the ivar unconditionally, so setting a
// windowskin on a window whose opacity had not been set was a TypeError on nil
// -- window_init sets @contents_opacity but not @opacity or @back_opacity.
// Nothing hit it while RGSS::Window was unreachable (see the note on
// RPG2k::Window); it raises on the first real use once it is not.
static mrb_int clamp_opacity(mrb_state* M, mrb_value self, const char* iv) {
  const mrb_value raw = mrb_iv_get(M, self, mrb_intern_cstr(M, iv));
  if (mrb_nil_p(raw))
    return 255;
  const mrb_int v = mrb_as_int(M, raw);
  if (v < 0)
    return 0;
  if (v > 255)
    return 255;
  return v;
}

// Repaint the window canvas: clear it, draw the windowskin background + 9-slice
// frame (if a windowskin is set), then blit the contents bitmap into the
// content area (inset by WINDOW_PADDING, scrolled by ox/oy). The compositing
// reuses the tested Bitmap#clear/#stretch_blt/#blt methods via mrb_funcall;
// only the RMXP windowskin source rects are new here (the 128x128 background at
// (0,0) and the 64x64 frame at (128,0) with 16px corners). The blinking cursor
// rect and the pause arrow are not drawn yet (tracked in
// docs/rpgxp-rgss-api-gap.md).
void window_refresh(mrb_state* M, mrb_value self) {
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  if (!obj)
    return;
  const mrb_int w =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@width")));
  const mrb_int full_h =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@height")));
  // RGSS2/RGSS3 openness: the window unrolls from its horizontal centre line,
  // so it is drawn at a fraction of its height and shifted down by half of what
  // it lost. Every VX window opens and closes this way (`Window_Base#open`
  // steps openness by 48 a frame), and RGSS hides the contents until it is
  // fully open. 255 -- the default, and every RGSS1 window -- is the ordinary
  // full draw.
  const mrb_int openness = std::min<mrb_int>(
      255, std::max<mrb_int>(0, iv_int_or(M, self, "@openness", 255)));
  const mrb_int h = full_h * openness / 255;
  lv_obj_set_y(obj, (int32_t)(iv_int_or(M, self, "@y", 0) + (full_h - h) / 2));
  if (h <= 0) {
    // Fully closed: nothing to draw, and a zero-height canvas is not a valid
    // LVGL buffer, so size the object away instead.
    lv_obj_set_size(obj, (int32_t)w, 0);
    lv_obj_invalidate(obj);
    return;
  }
  window_ensure_canvas(M, self, w, h);
  const mrb_value canvas =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_win_canvas"));
  const mrb_sym blt = mrb_intern_lit(M, "blt");
  const mrb_sym sblt = mrb_intern_lit(M, "stretch_blt");
  // The compositing allocates transient Rect values; drop them off the GC arena
  // when done (canvas/skin/contents stay alive via their ivars on self).
  const int arena = mrb_gc_arena_save(M);
  mrb_funcall_argv(M, canvas, mrb_intern_lit(M, "clear"), 0, nullptr);

  const mrb_value skin = mrb_iv_get(M, self, mrb_intern_lit(M, "@windowskin"));
  const mrb_int b = WINDOW_PADDING;
  if (mrb_test(skin) && DATA_PTR(skin)) {
    const mrb_int op = clamp_opacity(M, self, "@opacity");
    const mrb_int back = op * clamp_opacity(M, self, "@back_opacity") / 255;
    // Background from the 128x128 tile at (0,0). RMXP's `stretch` (default
    // true) scales that tile over the whole window; when false it is tiled at
    // 1:1, repeating across the window (edge tiles clip against the canvas).
    const mrb_value st = mrb_iv_get(M, self, mrb_intern_lit(M, "@stretch"));
    const bool stretch = mrb_nil_p(st) ? true : mrb_test(st);
    if (stretch) {
      const mrb_value bg[] = {make_rect(M, 0, 0, w, h), skin,
                              make_rect(M, 0, 0, 128, 128),
                              mrb_fixnum_value(back)};
      mrb_funcall_argv(M, canvas, sblt, 4, bg);
    } else {
      for (mrb_int ty = 0; ty < h; ty += 128) {
        for (mrb_int tx = 0; tx < w; tx += 128) {
          const mrb_value bg[] = {mrb_fixnum_value(tx), mrb_fixnum_value(ty),
                                  skin, make_rect(M, 0, 0, 128, 128),
                                  mrb_fixnum_value(back)};
          mrb_funcall_argv(M, canvas, blt, 5, bg);
        }
      }
    }
    // The tone tints the background only, so it goes on before the frame and
    // the contents are drawn over it.
    window_apply_tone(M, self, DataType<Bitmap>::get(M, canvas));
    // Frame: the 64x64 border at (128,0), a 9-slice with 16px corners/margins.
    // The corner shrinks vertically with a part-open window, so a half-unrolled
    // one keeps a frame instead of drawing its top and bottom borders over each
    // other (h is the *drawn* height -- see openness above).
    const mrb_int bv = std::min<mrb_int>(b, h / 2);
    if (bv > 0) {
      const mrb_value tl[] = {mrb_fixnum_value(0), mrb_fixnum_value(0), skin,
                              make_rect(M, 128, 0, b, bv),
                              mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, blt, 5, tl);
      const mrb_value tr[] = {mrb_fixnum_value(w - b), mrb_fixnum_value(0),
                              skin, make_rect(M, 176, 0, b, bv),
                              mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, blt, 5, tr);
      const mrb_value bl[] = {mrb_fixnum_value(0), mrb_fixnum_value(h - bv),
                              skin, make_rect(M, 128, 64 - bv, b, bv),
                              mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, blt, 5, bl);
      const mrb_value br[] = {mrb_fixnum_value(w - b), mrb_fixnum_value(h - bv),
                              skin, make_rect(M, 176, 64 - bv, b, bv),
                              mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, blt, 5, br);
      const mrb_value top[] = {make_rect(M, b, 0, w - 2 * b, bv), skin,
                               make_rect(M, 144, 0, 32, bv),
                               mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, sblt, 4, top);
      const mrb_value bottom[] = {make_rect(M, b, h - bv, w - 2 * b, bv), skin,
                                  make_rect(M, 144, 64 - bv, 32, bv),
                                  mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, sblt, 4, bottom);
    }
    if (h > 2 * bv) {
      const mrb_value left[] = {make_rect(M, 0, bv, b, h - 2 * bv), skin,
                                make_rect(M, 128, 16, b, 32),
                                mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, sblt, 4, left);
      const mrb_value right[] = {make_rect(M, w - b, bv, b, h - 2 * bv), skin,
                                 make_rect(M, 176, 16, b, 32),
                                 mrb_fixnum_value(op)};
      mrb_funcall_argv(M, canvas, sblt, 4, right);
    }
  } else {
    // No windowskin: the tone still applies to whatever background there is.
    window_apply_tone(M, self, DataType<Bitmap>::get(M, canvas));
  }

  // Everything below is window *furniture* -- contents, cursor, pause arrow --
  // which RGSS hides entirely while a window is opening or closing. Only the
  // frame animates.
  if (openness < 255) {
    mrb_gc_arena_restore(M, arena);
    lv_obj_invalidate(obj);
    return;
  }

  const mrb_value cont = mrb_iv_get(M, self, mrb_intern_lit(M, "@contents"));
  if (mrb_test(cont) && DATA_PTR(cont)) {
    const mrb_int cop = clamp_opacity(M, self, "@contents_opacity");
    const mrb_int ox =
        mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@ox")));
    const mrb_int oy =
        mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@oy")));
    // Blit the scrolled contents into the content area, inset by
    // WINDOW_PADDING.
    const mrb_value c[] = {mrb_fixnum_value(b), mrb_fixnum_value(b), cont,
                           make_rect(M, ox, oy, w - 2 * b, h - 2 * b),
                           mrb_fixnum_value(cop)};
    mrb_funcall_argv(M, canvas, blt, 5, c);
  }

  const mrb_int anim =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@_anim")));
  // Cursor: a blinking highlight from the windowskin cursor region (128,64,
  // 32,32) drawn at cursor_rect (content coords, offset by the padding), when
  // the window is active. It is a 9-slice with 2px corners (matching
  // RMXP/mkxp's buildFrame): the four 2x2 corners are copied 1:1, the four
  // edges are stretched along one axis and the centre fills the rest. The blink
  // alpha oscillates with @_anim. Redrawn each frame by Window#update because
  // scripts mutate cursor_rect in place.
  const mrb_value cr_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@cursor_rect"));
  const mrb_value active_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@active"));
  const bool active = mrb_nil_p(active_v) ? true : mrb_test(active_v);
  if (mrb_test(skin) && DATA_PTR(skin) && active && mrb_test(cr_v) &&
      DATA_PTR(cr_v)) {
    Rect& cr = DataType<Rect>::get(M, cr_v);
    if (cr.width > 0 && cr.height > 0) {
      const mrb_int phase = ((anim % 32) + 32) % 32;
      const mrb_int level = phase < 16 ? phase : 32 - phase;  // 0..16
      const mrb_int calpha = 255 - level * 8;                 // 255..127
      const mrb_value op = mrb_fixnum_value(calpha);
      const mrb_int dx = b + cr.x, dy = b + cr.y, dw = cr.width, dh = cr.height;
      // The cursor skin region and its 2px 9-slice corner size.
      const int sx = 128, sy = 64, ss = 32, k = 2;
      if (dw >= 2 * k && dh >= 2 * k) {
        // Corners (blt, 1:1). {tl, tr, bl, br} as {dstx, dsty, srcx, srcy}.
        const mrb_int corners[4][4] = {
            {dx, dy, sx, sy},
            {dx + dw - k, dy, sx + ss - k, sy},
            {dx, dy + dh - k, sx, sy + ss - k},
            {dx + dw - k, dy + dh - k, sx + ss - k, sy + ss - k}};
        for (const auto& c : corners) {
          const mrb_value a[] = {mrb_fixnum_value(c[0]), mrb_fixnum_value(c[1]),
                                 skin, make_rect(M, c[2], c[3], k, k), op};
          mrb_funcall_argv(M, canvas, blt, 5, a);
        }
        // Edges (stretch_blt) as {dstRect..., srcRect...}: top, bottom, left,
        // right. Top/bottom stretch horizontally, left/right vertically.
        const mrb_int edges[4][8] = {
            {dx + k, dy, dw - 2 * k, k, sx + k, sy, ss - 2 * k, k},
            {dx + k, dy + dh - k, dw - 2 * k, k, sx + k, sy + ss - k,
             ss - 2 * k, k},
            {dx, dy + k, k, dh - 2 * k, sx, sy + k, k, ss - 2 * k},
            {dx + dw - k, dy + k, k, dh - 2 * k, sx + ss - k, sy + k, k,
             ss - 2 * k}};
        for (const auto& e : edges) {
          const mrb_value a[] = {make_rect(M, e[0], e[1], e[2], e[3]), skin,
                                 make_rect(M, e[4], e[5], e[6], e[7]), op};
          mrb_funcall_argv(M, canvas, sblt, 4, a);
        }
        // Centre (stretch_blt).
        const mrb_value ctr[] = {
            make_rect(M, dx + k, dy + k, dw - 2 * k, dh - 2 * k), skin,
            make_rect(M, sx + k, sy + k, ss - 2 * k, ss - 2 * k), op};
        mrb_funcall_argv(M, canvas, sblt, 4, ctr);
      } else {
        // Rect too small for the 9-slice: fall back to a plain stretch.
        const mrb_value cur[] = {make_rect(M, dx, dy, dw, dh), skin,
                                 make_rect(M, sx, sy, ss, ss), op};
        mrb_funcall_argv(M, canvas, sblt, 4, cur);
      }
    }
  }
  // Pause arrow: one of four 16x16 frames at (160,64) cycled by @_anim, drawn
  // centred on the bottom edge when the window is paused.
  if (mrb_test(skin) && DATA_PTR(skin) &&
      mrb_test(mrb_iv_get(M, self, mrb_intern_lit(M, "@pause")))) {
    const mrb_int f = (anim / 8) % 4;
    const mrb_value pa[] = {
        mrb_fixnum_value(w / 2 - 8), mrb_fixnum_value(h - 16), skin,
        make_rect(M, 160 + (f % 2) * 16, 64 + (f / 2) * 16, 16, 16),
        mrb_fixnum_value(255)};
    mrb_funcall_argv(M, canvas, blt, 5, pa);
  }
  mrb_gc_arena_restore(M, arena);
  lv_obj_invalidate(obj);
}

mrb_value window_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);
  lv_obj_t* c = lv_canvas_create(parent_object(M, vp));
  wrap_lv_obj(M, self, c);
  register_zobj(M, self);
  lv_obj_set_pos(c, 0, 0);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@viewport"), vp);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@contents"), mrb_nil_value());
  mrb_iv_set(M, self, mrb_intern_lit(M, "@width"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@height"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@contents_opacity"),
             mrb_fixnum_value(255));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_anim"), mrb_fixnum_value(0));
  window_ensure_canvas(M, self, 1, 1);
  return self;
}

mrb_value window_set_contents(mrb_state* M, mrb_value self) {
  mrb_value bmp;
  mrb_get_args(M, "o", &bmp);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@contents"), bmp);
  window_refresh(M, self);
  return bmp;
}

mrb_value window_set_width(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@width"), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_height(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@height"), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_ox(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_oy(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_contents_opacity(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@contents_opacity"),
             mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_skin(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@windowskin"), v);
  window_refresh(M, self);
  return v;
}

mrb_value window_set_opacity(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@opacity"), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_back_opacity(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@back_opacity"), mrb_fixnum_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_cursor_rect(mrb_state* M, mrb_value self) {
  mrb_value v;
  mrb_get_args(M, "o", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@cursor_rect"), v);
  window_refresh(M, self);
  return v;
}

mrb_value window_set_active(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@active"), mrb_bool_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_pause(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@pause"), mrb_bool_value(v));
  window_refresh(M, self);
  return self;
}

mrb_value window_set_stretch(mrb_state* M, mrb_value self) {
  mrb_bool v;
  mrb_get_args(M, "b", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@stretch"), mrb_bool_value(v));
  window_refresh(M, self);
  return self;
}

// A single number standing for a Tone's four channels, so a change can be
// spotted with one comparison. Shared with the viewport's tone tracking.
double vp_tone_key(const Tone& t);

// RGSS2/RGSS3 Window#openness: 0 (closed) .. 255 (open). Native rather than
// plain state because assigning it has to redraw -- the frame is drawn at a
// fraction of its height (see window_refresh), which *is* the open/close
// animation. `Window_Base#open` steps this by 48 a frame.
mrb_value window_set_openness(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  v = std::min<mrb_int>(255, std::max<mrb_int>(0, v));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@openness"), mrb_fixnum_value(v));
  window_refresh(M, self);
  return mrb_fixnum_value(v);
}

// RGSS2/RGSS3 Window#tone, created on first read like the viewport's so
// `window.tone.set(...)` has something to mutate.
mrb_value window_tone(mrb_state* M, mrb_value self) {
  mrb_value t = mrb_iv_get(M, self, mrb_intern_lit(M, "@tone"));
  if (mrb_nil_p(t)) {
    const mrb_value args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                              mrb_fixnum_value(0), mrb_fixnum_value(0)};
    t = mrb_obj_new(
        M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Tone"), 4, args);
    mrb_iv_set(M, self, mrb_intern_lit(M, "@tone"), t);
  }
  return t;
}

mrb_value window_set_tone(mrb_state* M, mrb_value self) {
  mrb_value t;
  mrb_get_args(M, "o", &t);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@tone"), t);
  window_refresh(M, self);
  return t;
}

// Whether the tone changed since the last check. The scripts mutate the Tone
// *in place* (`window.tone.set(...)`) and call update every frame, so
// assignment alone is not enough to notice -- the same reason Viewport#tone is
// re-checked from its own update. One comparison when it did not move.
bool window_sync_tone(mrb_state* M, mrb_value self) {
  const mrb_value tv = mrb_iv_get(M, self, mrb_intern_lit(M, "@tone"));
  const double key = (mrb_test(tv) && DATA_PTR(tv))
                         ? vp_tone_key(DataType<Tone>::get(M, tv))
                         : 0.0;
  const mrb_value prev = mrb_iv_get(M, self, mrb_intern_lit(M, "@_tone_key"));
  if (mrb_float_p(prev) && mrb_float(prev) == key)
    return false;
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tone_key"), mrb_float_value(M, key));
  return true;
}

// Per-frame tick: advance the blink/pause animation and, when the window has a
// visible cursor or is paused, redraw so the animation and any in-place
// cursor_rect mutation show. Windows without a cursor or pause need no
// per-frame work beyond the tone check, which is one comparison.
mrb_value window_update(mrb_state* M, mrb_value self) {
  const mrb_int anim =
      mrb_as_int(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@_anim")));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_anim"), mrb_fixnum_value(anim + 1));
  const mrb_value cr = mrb_iv_get(M, self, mrb_intern_lit(M, "@cursor_rect"));
  const mrb_value active_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@active"));
  const bool active = mrb_nil_p(active_v) ? true : mrb_test(active_v);
  const bool has_cursor = active && mrb_test(cr) && DATA_PTR(cr) &&
                          DataType<Rect>::get(M, cr).width > 0;
  const bool paused =
      mrb_test(mrb_iv_get(M, self, mrb_intern_lit(M, "@pause")));
  const bool tone_moved = window_sync_tone(M, self);
  if (has_cursor || paused || tone_moved)
    window_refresh(M, self);
  return self;
}

// ---- Viewport -------------------------------------------------------------

// Build an RGSS::Rect value.
mrb_value make_rect(mrb_state* M, mrb_int x, mrb_int y, mrb_int w, mrb_int h) {
  const mrb_value args[] = {mrb_fixnum_value(x), mrb_fixnum_value(y),
                            mrb_fixnum_value(w), mrb_fixnum_value(h)};
  return mrb_obj_new(
      M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Rect"), 4, args);
}

// Repaint the viewport's colour/flash overlay (defined with the rest of the
// overlay below; declared here because a rect change has to resize it).
void vp_refresh_overlay(mrb_state* M, mrb_value self);

// Push the stored @rect / @ox / @oy onto the underlying LVGL objects: the outer
// frame takes the rect's position and size (and clips to it), while the inner
// content layer is shifted by (-ox, -oy) to scroll its sprites.
void vp_apply(mrb_state* M, mrb_value self) {
  lv_obj_t* outer = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  if (!outer)
    return;
  Rect& r =
      DataType<Rect>::get(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@rect")));
  const mrb_int w = std::max<mrb_int>(r.width, 0);
  const mrb_int h = std::max<mrb_int>(r.height, 0);
  lv_obj_set_pos(outer, r.x, r.y);
  lv_obj_set_size(outer, w, h);

  lv_obj_t* inner = viewport_content(outer);
  const mrb_value ox = mrb_iv_get(M, self, mrb_intern_lit(M, "@ox"));
  const mrb_value oy = mrb_iv_get(M, self, mrb_intern_lit(M, "@oy"));
  lv_obj_set_pos(inner, -(mrb_fixnum_p(ox) ? mrb_fixnum(ox) : 0),
                 -(mrb_fixnum_p(oy) ? mrb_fixnum(oy) : 0));
  lv_obj_set_size(inner, w, h);

  // The colour overlay covers the frame, so a resized viewport resizes it.
  vp_refresh_overlay(M, self);
}

mrb_value vp_init(mrb_state* M, mrb_value self) {
  // Viewport.new(x, y, width, height) | Viewport.new(rect) | Viewport.new
  // (the last covering the whole screen, matching RGSS).
  mrb_int x = 0, y = 0, w = 0, h = 0;
  const mrb_int argc = mrb_get_argc(M);
  if (argc == 1) {
    mrb_value rv;
    mrb_get_args(M, "o", &rv);
    Rect& r = DataType<Rect>::get(M, rv);
    x = r.x;
    y = r.y;
    w = r.width;
    h = r.height;
  } else if (argc >= 4) {
    mrb_get_args(M, "iiii", &x, &y, &w, &h);
  } else {
    lv_display_t* d = get_display(M);
    w = lv_display_get_horizontal_resolution(d);
    h = lv_display_get_vertical_resolution(d);
  }

  lv_obj_t* screen = lv_display_get_screen_active(get_display(M));
  lv_obj_t* outer = lv_obj_create(screen);
  lv_obj_remove_style_all(outer);
  lv_obj_remove_flag(outer, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_scrollbar_mode(outer, LV_SCROLLBAR_MODE_OFF);

  // Inner content layer: children beyond the viewport bounds must survive here
  // (only the outer frame clips), so let it overflow.
  lv_obj_t* inner = lv_obj_create(outer);
  lv_obj_remove_style_all(inner);
  lv_obj_remove_flag(inner, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(inner, LV_OBJ_FLAG_OVERFLOW_VISIBLE);

  wrap_lv_obj(M, self, outer);
  register_zobj(M, self);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@rect"), make_rect(M, x, y, w, h));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(0));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@visible"), mrb_true_value());
  vp_apply(M, self);
  return self;
}

mrb_value vp_rect(mrb_state* M, mrb_value self) {
  return mrb_iv_get(M, self, mrb_intern_lit(M, "@rect"));
}

mrb_value vp_set_rect(mrb_state* M, mrb_value self) {
  mrb_value rv;
  mrb_get_args(M, "o", &rv);
  Rect& r = DataType<Rect>::get(M, rv);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@rect"),
             make_rect(M, r.x, r.y, r.width, r.height));
  vp_apply(M, self);
  return rv;
}

mrb_value vp_ox(mrb_state* M, mrb_value self) {
  return mrb_iv_get(M, self, mrb_intern_lit(M, "@ox"));
}

mrb_value vp_oy(mrb_state* M, mrb_value self) {
  return mrb_iv_get(M, self, mrb_intern_lit(M, "@oy"));
}

mrb_value vp_set_ox(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@ox"), mrb_fixnum_value(v));
  vp_apply(M, self);
  return mrb_fixnum_value(v);
}

mrb_value vp_set_oy(mrb_state* M, mrb_value self) {
  mrb_int v;
  mrb_get_args(M, "i", &v);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@oy"), mrb_fixnum_value(v));
  vp_apply(M, self);
  return mrb_fixnum_value(v);
}

// ---- Viewport colour overlay ----------------------------------------------
//
// RGSS's `Viewport#color` is a flat colour laid over everything the viewport
// draws, and `#flash` is the same thing on a countdown. VX / VX Ace do every
// screen effect this way — `Spriteset_Map` fades with
// `@viewport3.color.set(0, 0, 0, 255 - brightness)` and flashes with
// `@viewport2.color.set(...)` — and the RPG2000 runtime wants the same
// mechanism for its screen fade/flash.
//
// LVGL cannot tint a container, but it can draw one more child on top of one:
// the overlay is a canvas the size of the viewport, filled with the effective
// colour, held as the outer frame's last child so it composites above the
// content layer. The z sweep in gfx_update only reorders *registered* objects,
// which all live inside that content layer, so the overlay stays on top without
// taking part in z ordering. This is the same "screen-sized colour at an
// opacity" ADR 0021 measured working for the RPG2000 fade, moved into the
// viewport so it clips, scrolls and hides with it.
//
// Note the overlay is refreshed from `#update`, not only on assignment: the
// stock scripts mutate the colour *in place* (`viewport.color.set(...)`) and
// call `viewport.update` every frame, so re-reading it per frame is what makes
// an in-place change visible. The fill is skipped unless the effective colour
// actually changed, so a static viewport costs one comparison a frame.

// The overlay canvas, created on demand. The outer frame's only other child is
// the content layer built by vp_init (index 0), and lv_obj_move_foreground
// keeps the overlay last, so index 1 identifies it without keeping a pointer
// alive across a GC.
lv_obj_t* vp_overlay(mrb_state* M, mrb_value self, bool create) {
  lv_obj_t* outer = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  if (!outer)
    return nullptr;
  if (lv_obj_t* existing = lv_obj_get_child(outer, 1))
    return existing;
  if (!create)
    return nullptr;

  lv_obj_t* ov = lv_canvas_create(outer);
  lv_obj_remove_style_all(ov);
  lv_obj_set_pos(ov, 0, 0);
  // Never take pointer events, and always draw last among the outer frame's
  // children (the content layer is the only other one).
  lv_obj_remove_flag(ov, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_move_foreground(ov);
  return ov;
}

// The colour the overlay should show: the viewport's `color`, with the flash
// colour composited over it (src-over) while a flash is running. RGSS fades a
// flash out linearly over its duration.
Color vp_effective_color(mrb_state* M, mrb_value self) {
  Color out{0, 0, 0, 0};
  const mrb_value color_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@color"));
  if (mrb_test(color_v) && DATA_PTR(color_v))
    out = DataType<Color>::get(M, color_v);

  const mrb_value count_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_count"));
  const mrb_value flash_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_color"));
  const mrb_int count = mrb_fixnum_p(count_v) ? mrb_fixnum(count_v) : 0;
  if (count > 0 && mrb_test(flash_v) && DATA_PTR(flash_v)) {
    const mrb_value dur_v =
        mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_duration"));
    const mrb_int duration = mrb_fixnum_p(dur_v) ? mrb_fixnum(dur_v) : count;
    const Color f = DataType<Color>::get(M, flash_v);
    const double fade = duration > 0 ? (double)count / (double)duration : 1.0;
    const double a = (f.alpha / 255.0) * fade;
    out.red = f.red * a + out.red * (1.0 - a);
    out.green = f.green * a + out.green * (1.0 - a);
    out.blue = f.blue * a + out.blue * (1.0 - a);
    out.alpha = 255.0 * a + out.alpha * (1.0 - a);
  }
  return out;
}

// Repaint the overlay from the current colour/flash state. Allocates (or
// resizes) its buffer to the viewport rect, and hides it entirely when the
// effective colour is transparent so a viewport with no effect draws nothing
// extra.
void vp_refresh_overlay(mrb_state* M, mrb_value self) {
  lv_obj_t* outer = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  if (!outer)
    return;
  const Color c = vp_effective_color(M, self);
  const bool visible = c.alpha > 0.0;
  lv_obj_t* ov = vp_overlay(M, self, visible);
  if (!ov)
    return;
  if (!visible) {
    lv_obj_add_flag(ov, LV_OBJ_FLAG_HIDDEN);
    mrb_iv_set(M, self, mrb_intern_lit(M, "@_overlay_key"), mrb_nil_value());
    return;
  }

  Rect& r =
      DataType<Rect>::get(M, mrb_iv_get(M, self, mrb_intern_lit(M, "@rect")));
  const mrb_int w = std::max<mrb_int>(r.width, 1);
  const mrb_int h = std::max<mrb_int>(r.height, 1);

  // Skip the fill when neither the colour nor the size changed since the last
  // one: #update runs this every frame. The channels are 0..255, so packing
  // them with the size into two doubles stays exact and allocates nothing.
  const double color_key =
      ((std::floor(c.red) * 256.0 + std::floor(c.green)) * 256.0 +
       std::floor(c.blue)) *
          256.0 +
      std::floor(c.alpha);
  const double size_key = (double)w * 65536.0 + (double)h;
  const mrb_value prev_color =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_overlay_key"));
  const mrb_value prev_size =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@_overlay_size"));
  if (mrb_float_p(prev_color) && mrb_float(prev_color) == color_key &&
      mrb_float_p(prev_size) && mrb_float(prev_size) == size_key) {
    lv_obj_remove_flag(ov, LV_OBJ_FLAG_HIDDEN);
    return;
  }

  const mrb_value cur = mrb_iv_get(M, self, mrb_intern_lit(M, "@_overlay_bmp"));
  mrb_value bmp_v = cur;
  if (mrb_nil_p(cur) || DataType<Bitmap>::get(M, cur).width != w ||
      DataType<Bitmap>::get(M, cur).height != h) {
    RClass* bmp_class =
        mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap");
    bmp_v =
        DataType<Bitmap>::make(M, bmp_class, w, h, LV_COLOR_FORMAT_ARGB8888);
    mrb_iv_set(M, self, mrb_intern_lit(M, "@_overlay_bmp"), bmp_v);
    Bitmap& nb = DataType<Bitmap>::get(M, bmp_v);
    lv_canvas_set_buffer(ov, nb.buffer.data(), w, h, LV_COLOR_FORMAT_ARGB8888);
    lv_obj_set_size(ov, w, h);
  }

  Bitmap& b = DataType<Bitmap>::get(M, bmp_v);
  for (mrb_int y = 0; y < h; ++y)
    for (mrb_int x = 0; x < w; ++x)
      bmp_put(b, x, y, c.red, c.green, c.blue, c.alpha);
  b.dirty = true;
  lv_obj_remove_flag(ov, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(ov);
  lv_obj_invalidate(ov);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_overlay_key"),
             mrb_float_value(M, color_key));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_overlay_size"),
             mrb_float_value(M, size_key));
}

// Re-composite every display object that lives in this viewport, so a tone
// change reaches what is already on screen. Each object bakes the viewport's
// tone into its own buffer when it composites (see viewport_tone), and only
// re-composites when something it owns changes -- so the viewport has to poke
// them. The z-order registry is the list of live display objects, and each one
// records the viewport it was created in.
void vp_refresh_children(mrb_state* M, mrb_value self) {
  RClass* rgss = mrb_module_get(M, "RGSS");
  RClass* spr_class = mrb_class_get_under(M, rgss, "Sprite");
  RClass* plane_class = mrb_class_get_under(M, rgss, "Plane");
  RClass* tilemap_class = mrb_class_get_under(M, rgss, "Tilemap");
  const mrb_value objs = zorder_objs(M);
  for (mrb_int i = 0; i < RARRAY_LEN(objs); ++i) {
    const mrb_value v = RARRAY_PTR(objs)[i];
    if (!DATA_PTR(v))
      continue;
    const mrb_value vp = mrb_iv_get(M, v, mrb_intern_lit(M, "@viewport"));
    if (!mrb_obj_equal(M, vp, self))
      continue;
    if (mrb_obj_is_kind_of(M, v, spr_class))
      spr_bind_display(M, v, reinterpret_cast<lv_obj_t*>(DATA_PTR(v)));
    else if (mrb_obj_is_kind_of(M, v, plane_class))
      plane_retile(M, v);
    else if (mrb_obj_is_kind_of(M, v, tilemap_class))
      tilemap_refresh(M, v);
  }
}

// The tone key the child refresh is gated on: the scripts mutate the Tone in
// place (`viewport.tone.set(...)`) and call #update every frame, so the value
// is re-read per frame and the (expensive) re-composite only runs when it
// actually moved. Channels are -255..255 and gray 0..255, so this packs
// exactly.
double vp_tone_key(const Tone& t) {
  return ((std::floor(t.red) + 255.0) * 512.0 + (std::floor(t.green) + 255.0)) *
             512.0 * 512.0 +
         (std::floor(t.blue) + 255.0) * 512.0 + std::floor(t.gray);
}

// Re-composite this viewport's contents when its tone changed since the last
// check. Returns whether anything was refreshed.
bool vp_sync_tone(mrb_state* M, mrb_value self) {
  const Tone tn = viewport_tone(M, self);
  const double key = vp_tone_key(tn);
  const mrb_value prev = mrb_iv_get(M, self, mrb_intern_lit(M, "@_tone_key"));
  if (mrb_float_p(prev) && mrb_float(prev) == key)
    return false;
  mrb_iv_set(M, self, mrb_intern_lit(M, "@_tone_key"), mrb_float_value(M, key));
  vp_refresh_children(M, self);
  return true;
}

// RGSS Viewport#tone: unlike #color (a layer over the viewport's contents), a
// tone *rescales what is drawn* -- desaturate toward luminance, then offset
// each channel -- so it cannot be an overlay. Each display object in the
// viewport folds it into its own composite instead (see viewport_tone), and
// this side makes sure they redo that when it changes.
mrb_value vp_tone(mrb_state* M, mrb_value self) {
  mrb_value t = mrb_iv_get(M, self, mrb_intern_lit(M, "@tone"));
  if (mrb_nil_p(t)) {
    const mrb_value args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                              mrb_fixnum_value(0), mrb_fixnum_value(0)};
    t = mrb_obj_new(
        M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Tone"), 4, args);
    mrb_iv_set(M, self, mrb_intern_lit(M, "@tone"), t);
  }
  return t;
}

mrb_value vp_set_tone(mrb_state* M, mrb_value self) {
  mrb_value t;
  mrb_get_args(M, "o", &t);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@tone"), t);
  vp_sync_tone(M, self);
  return t;
}

mrb_value vp_color(mrb_state* M, mrb_value self) {
  mrb_value c = mrb_iv_get(M, self, mrb_intern_lit(M, "@color"));
  if (mrb_nil_p(c)) {
    const mrb_value args[] = {mrb_fixnum_value(0), mrb_fixnum_value(0),
                              mrb_fixnum_value(0), mrb_fixnum_value(0)};
    c = mrb_obj_new(
        M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Color"), 4, args);
    mrb_iv_set(M, self, mrb_intern_lit(M, "@color"), c);
  }
  return c;
}

mrb_value vp_set_color(mrb_state* M, mrb_value self) {
  mrb_value c;
  mrb_get_args(M, "o", &c);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@color"), c);
  vp_refresh_overlay(M, self);
  return c;
}

// Viewport#flash(color, duration): show `color` over the viewport, fading out
// over `duration` frames of #update. A nil colour is RGSS's "empty" flash,
// which for a viewport means no overlay at all.
mrb_value vp_flash(mrb_state* M, mrb_value self) {
  mrb_value color;
  mrb_int duration;
  mrb_get_args(M, "oi", &color, &duration);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_color"), color);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_duration"),
             mrb_fixnum_value(duration));
  mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_count"),
             mrb_fixnum_value(mrb_nil_p(color) ? 0 : duration));
  vp_refresh_overlay(M, self);
  return mrb_nil_value();
}

// One frame: advance a running flash and repaint the overlay from the current
// colour (which the scripts mutate in place).
mrb_value vp_update(mrb_state* M, mrb_value self) {
  const mrb_value count_v =
      mrb_iv_get(M, self, mrb_intern_lit(M, "@flash_count"));
  if (mrb_fixnum_p(count_v) && mrb_fixnum(count_v) > 0)
    mrb_iv_set(M, self, mrb_intern_lit(M, "@flash_count"),
               mrb_fixnum_value(mrb_fixnum(count_v) - 1));
  vp_refresh_overlay(M, self);
  // The tone is mutated in place by the scripts, so re-read it per frame; the
  // re-composite it triggers is skipped unless the value actually moved.
  vp_sync_tone(M, self);
  return mrb_nil_value();
}

// Register x/y/width/height accessors for the Rect class.
void define_rect(mrb_state* M, RClass* m) {
  RClass* rect = mrb_define_class_under(M, m, "Rect", M->object_class);
  MRB_SET_INSTANCE_TT(rect, MRB_TT_DATA);
  mrb_define_method(
      M, rect, "initialize",
      [](mrb_state* M, V self) -> V {
        if (mrb_get_argc(M) == 0) {
          DataType<Rect>::alloc_obj(M, self);
        } else {
          mrb_int x, y, w, h;
          mrb_get_args(M, "iiii", &x, &y, &w, &h);
          DataType<Rect>::alloc_obj(M, self, x, y, w, h);
        }
        return self;
      },
      MRB_ARGS_OPT(4));
  mrb_define_method(
      M, rect, "set",
      [](mrb_state* M, V self) {
        if (mrb_get_argc(M) == 1) {
          V o;
          mrb_get_args(M, "o", &o);
          DataType<Rect>::get(M, self) = DataType<Rect>::get(M, o);
        } else {
          mrb_int x, y, w, h;
          mrb_get_args(M, "iiii", &x, &y, &w, &h);
          DataType<Rect>::get(M, self) = Rect{x, y, w, h};
        }
        return self;
      },
      MRB_ARGS_REQ(1) | MRB_ARGS_OPT(3));
  mrb_define_method(
      M, rect, "empty",
      [](mrb_state* M, V self) {
        DataType<Rect>::get(M, self) = Rect{0, 0, 0, 0};
        return self;
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, rect, "x",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Rect>::get(M, self).x);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, rect, "y",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Rect>::get(M, self).y);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, rect, "width",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Rect>::get(M, self).width);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, rect, "height",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Rect>::get(M, self).height);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, rect, "x=",
      [](mrb_state* M, V self) {
        mrb_int x;
        mrb_get_args(M, "i", &x);
        return mrb_fixnum_value(DataType<Rect>::get(M, self).x = x);
      },
      MRB_ARGS_REQ(1));
  mrb_define_method(
      M, rect, "y=",
      [](mrb_state* M, V self) {
        mrb_int x;
        mrb_get_args(M, "i", &x);
        return mrb_fixnum_value(DataType<Rect>::get(M, self).y = x);
      },
      MRB_ARGS_REQ(1));
  mrb_define_method(
      M, rect, "width=",
      [](mrb_state* M, V self) {
        mrb_int x;
        mrb_get_args(M, "i", &x);
        return mrb_fixnum_value(DataType<Rect>::get(M, self).width = x);
      },
      MRB_ARGS_REQ(1));
  mrb_define_method(
      M, rect, "height=",
      [](mrb_state* M, V self) {
        mrb_int x;
        mrb_get_args(M, "i", &x);
        return mrb_fixnum_value(DataType<Rect>::get(M, self).height = x);
      },
      MRB_ARGS_REQ(1));
  mrb_define_method(
      M, rect, "==",
      [](mrb_state* M, V self) {
        V o;
        mrb_get_args(M, "o", &o);
        if (!mrb_obj_is_kind_of(M, o, mrb_class(M, self)))
          return mrb_false_value();
        Rect& a = DataType<Rect>::get(M, self);
        Rect& b = DataType<Rect>::get(M, o);
        return mrb_bool_value(a.x == b.x && a.y == b.y && a.width == b.width &&
                              a.height == b.height);
      },
      MRB_ARGS_REQ(1));
  mrb_define_method(
      M, rect, "to_s",
      [](mrb_state* M, V self) {
        Rect& r = DataType<Rect>::get(M, self);
        char buf[128];
        std::snprintf(buf, sizeof(buf), "(%d, %d, %d, %d)", (int)r.x, (int)r.y,
                      (int)r.width, (int)r.height);
        return mrb_str_new_cstr(M, buf);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, rect, "_dump",
      [](mrb_state* M, V self) {
        Rect& r = DataType<Rect>::get(M, self);
        int32_t v[4] = {(int32_t)r.x, (int32_t)r.y, (int32_t)r.width,
                        (int32_t)r.height};
        return mrb_str_new(M, reinterpret_cast<const char*>(v), sizeof(v));
      },
      MRB_ARGS_REQ(1));
  mrb_define_class_method(
      M, rect, "_load",
      [](mrb_state* M, V self) {
        const char* p;
        mrb_int len;
        mrb_get_args(M, "s", &p, &len);
        int32_t v[4] = {0, 0, 0, 0};
        std::memcpy(v, p, std::min<mrb_int>(len, sizeof(v)));
        return DataType<Rect>::make(M, mrb_class_ptr(self), v[0], v[1], v[2],
                                    v[3]);
      },
      MRB_ARGS_REQ(1));
}

}  // namespace

// Exported Bitmap pixel access (see include/rgss_bitmap.hxx). Defined at file
// scope but still able to reach the anonymous-namespace Bitmap/DataType above,
// which stay visible here within this translation unit.
namespace rgss {

uint8_t* bitmap_pixels(mrb_state* M, mrb_value v, int* w, int* h) {
  if (!mrb_data_p(v))
    return nullptr;
  void* p = mrb_data_check_get_ptr(M, v, &DataType<Bitmap>::data_type);
  if (!p)
    return nullptr;
  Bitmap* b = reinterpret_cast<Bitmap*>(p);
  if (w)
    *w = b->width;
  if (h)
    *h = b->height;
  return b->buffer.data();
}

void bitmap_mark_dirty(mrb_state* M, mrb_value v) {
  if (!mrb_data_p(v))
    return;
  void* p = mrb_data_check_get_ptr(M, v, &DataType<Bitmap>::data_type);
  if (p)
    reinterpret_cast<Bitmap*>(p)->dirty = true;
}

}  // namespace rgss

extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display) {
  mrb_assert(!mrb_const_defined(M, mrb_obj_value(mrb_module_get(M, "RGSS")),
                                mrb_intern_lit(M, "_display")));
  mrb_const_set(M, mrb_obj_value(mrb_module_get(M, "RGSS")),
                mrb_intern_lit(M, "_display"), mrb_cptr_value(M, display));

  // The game screen is what shows wherever no sprite covers it, so it must be
  // the black RPG Maker draws outside the map -- LVGL's default theme paints it
  // light grey and hangs scrollbars off the edges, both of which showed up as
  // artefacts next to a genuine RPG_RT frame (ADR 0021). Nothing about a game
  // screen scrolls, either.
  if (lv_obj_t* scr = lv_display_get_screen_active(display)) {
    lv_obj_set_style_bg_color(scr, lv_color_black(), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_remove_flag(scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(scr, LV_SCROLLBAR_MODE_OFF);
  }
}

// RGSS.mouse_x / mouse_y / mouse_pressed? — the pointer state captured by the
// SDL backend (see input_bridge.cxx). Read by MV's TouchInput bridge.
static mrb_value mouse_x_m(mrb_state* M, mrb_value) {
  (void)M;
  return mrb_fixnum_value(rgss_mouse_x());
}
static mrb_value mouse_y_m(mrb_state* M, mrb_value) {
  (void)M;
  return mrb_fixnum_value(rgss_mouse_y());
}
static mrb_value mouse_pressed_m(mrb_state* M, mrb_value) {
  (void)M;
  return mrb_bool_value(rgss_mouse_pressed() != 0);
}

extern "C" void mrb_mruby_rgss_gem_init(mrb_state* M) {
  RClass* m = mrb_define_module(M, "RGSS");
  mrb_define_module_function(M, m, "to_nfd", to_nfd, MRB_ARGS_REQ(1));
  mrb_define_module_function(M, m, "default_font_path", default_font_path_m,
                             MRB_ARGS_NONE());
  mrb_define_module_function(M, m, "zlib_inflate", zlib_inflate,
                             MRB_ARGS_REQ(1));
  mrb_define_module_function(M, m, "mouse_x", mouse_x_m, MRB_ARGS_NONE());
  mrb_define_module_function(M, m, "mouse_y", mouse_y_m, MRB_ARGS_NONE());
  mrb_define_module_function(M, m, "mouse_pressed?", mouse_pressed_m,
                             MRB_ARGS_NONE());

  mrb_const_set(M, mrb_obj_value(m), mrb_intern_lit(M, "_game_start"),
                mrb_fixnum_value(lv_tick_get()));
  mrb_const_set(M, mrb_obj_value(m), mrb_intern_lit(M, "_zobjs"),
                mrb_ary_new(M));

  RClass* vp = mrb_define_class_under(M, m, "Viewport", M->object_class);
  MRB_SET_INSTANCE_TT(vp, MRB_TT_DATA);
  mrb_define_method(M, vp, "initialize", vp_init, MRB_ARGS_OPT(4));
  mrb_define_method(M, vp, "rect", vp_rect, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "rect=", vp_set_rect, MRB_ARGS_REQ(1));
  mrb_define_method(M, vp, "ox", vp_ox, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "oy", vp_oy, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "ox=", vp_set_ox, MRB_ARGS_REQ(1));
  mrb_define_method(M, vp, "oy=", vp_set_oy, MRB_ARGS_REQ(1));
  mrb_define_method(M, vp, "z=", obj_set_z, MRB_ARGS_REQ(1));
  mrb_define_method(M, vp, "visible", obj_visible, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "visible=", obj_set_visible, MRB_ARGS_REQ(1));
  mrb_define_method(M, vp, "update", vp_update, MRB_ARGS_NONE());
  // RGSS2/RGSS3 do every screen effect through the viewport: a flat colour over
  // everything it draws, and a timed flash. See vp_refresh_overlay.
  mrb_define_method(M, vp, "color", vp_color, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "color=", vp_set_color, MRB_ARGS_REQ(1));
  mrb_define_method(M, vp, "tone", vp_tone, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "tone=", vp_set_tone, MRB_ARGS_REQ(1));
  mrb_define_method(M, vp, "flash", vp_flash, MRB_ARGS_REQ(2));
  mrb_define_method(M, vp, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* spr = mrb_define_class_under(M, m, "Sprite", M->object_class);
  MRB_SET_INSTANCE_TT(spr, MRB_TT_DATA);
  mrb_define_method(M, spr, "initialize", spr_init, MRB_ARGS_OPT(1));
  mrb_define_method(M, spr, "bitmap=", spr_set_bmp, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, spr, "disposed?", obj_disposed, MRB_ARGS_NONE());
  mrb_define_method(M, spr, "x=", obj_set_x, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "y=", obj_set_y, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "z=", obj_set_z, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "visible", obj_visible, MRB_ARGS_NONE());
  mrb_define_method(M, spr, "visible=", obj_set_visible, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "opacity=", spr_set_opacity, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "zoom_x=", spr_set_zoom_x, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "zoom_y=", spr_set_zoom_y, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "angle=", spr_set_angle, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "mirror=", spr_set_mirror, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "tone=", spr_set_tone, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "color=", spr_set_color, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "src_rect=", spr_set_src_rect, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "update", spr_update, MRB_ARGS_NONE());
  mrb_define_method(M, spr, "blend_type=", spr_set_blend_type, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "bush_depth=", spr_set_bush_depth, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "flash", spr_flash, MRB_ARGS_REQ(2));

  RClass* plane = mrb_define_class_under(M, m, "Plane", M->object_class);
  MRB_SET_INSTANCE_TT(plane, MRB_TT_DATA);
  mrb_define_method(M, plane, "initialize", plane_init, MRB_ARGS_OPT(1));
  mrb_define_method(M, plane, "bitmap=", plane_set_bmp, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "ox=", plane_set_ox, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "oy=", plane_set_oy, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "opacity=", spr_set_opacity, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "tone=", plane_set_tone, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "color=", plane_set_color, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "zoom_x=", plane_set_zoom_x, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "zoom_y=", plane_set_zoom_y, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "blend_type=", spr_set_blend_type,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "z=", obj_set_z, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "visible", obj_visible, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "visible=", obj_set_visible, MRB_ARGS_REQ(1));
  mrb_define_method(M, plane, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, plane, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* tilemap = mrb_define_class_under(M, m, "Tilemap", M->object_class);
  MRB_SET_INSTANCE_TT(tilemap, MRB_TT_DATA);
  mrb_define_method(M, tilemap, "initialize", tilemap_init, MRB_ARGS_OPT(1));
  mrb_define_method(M, tilemap, "tileset=", tilemap_set_tileset,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, tilemap, "map_data=", tilemap_set_map_data,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, tilemap, "priorities=", tilemap_set_priorities,
                    MRB_ARGS_REQ(1));
  // RGSS2 / RGSS3 (VX, VX Ace): nine sheets addressed by index plus the tileset
  // flags table, in place of XP's single tileset + autotiles + priorities.
  mrb_define_method(M, tilemap, "bitmaps", tilemap_bitmaps, MRB_ARGS_NONE());
  mrb_define_method(M, tilemap, "flags=", tilemap_set_flags, MRB_ARGS_REQ(1));
  mrb_define_class_method(M, tilemap, "vx_tile_quads", tilemap_vx_tile_quads,
                          MRB_ARGS_ARG(1, 2));
  mrb_define_method(M, tilemap, "ox=", tilemap_set_ox, MRB_ARGS_REQ(1));
  mrb_define_method(M, tilemap, "oy=", tilemap_set_oy, MRB_ARGS_REQ(1));
  mrb_define_method(M, tilemap, "update", tilemap_update, MRB_ARGS_NONE());
  mrb_define_method(M, tilemap, "z=", obj_set_z, MRB_ARGS_REQ(1));
  mrb_define_method(M, tilemap, "visible", obj_visible, MRB_ARGS_NONE());
  mrb_define_method(M, tilemap, "visible=", tilemap_set_visible,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, tilemap, "dispose", tilemap_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, tilemap, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* window = mrb_define_class_under(M, m, "Window", M->object_class);
  MRB_SET_INSTANCE_TT(window, MRB_TT_DATA);
  mrb_define_method(M, window, "initialize", window_init, MRB_ARGS_OPT(1));
  mrb_define_method(M, window, "contents=", window_set_contents,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "x=", obj_set_x, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "y=", obj_set_y, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "width=", window_set_width, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "height=", window_set_height, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "ox=", window_set_ox, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "oy=", window_set_oy, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "contents_opacity=", window_set_contents_opacity,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "windowskin=", window_set_skin, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "opacity=", window_set_opacity, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "back_opacity=", window_set_back_opacity,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "cursor_rect=", window_set_cursor_rect,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "active=", window_set_active, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "pause=", window_set_pause, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "stretch=", window_set_stretch, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "update", window_update, MRB_ARGS_NONE());
  // RGSS2 / RGSS3 (VX, VX Ace): the open/close animation and the background
  // tone. Native because both have to redraw -- and so they must NOT be
  // redefined in mrblib, which loads after this and would shadow them.
  mrb_define_method(M, window, "openness=", window_set_openness,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "tone", window_tone, MRB_ARGS_NONE());
  mrb_define_method(M, window, "tone=", window_set_tone, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "z=", obj_set_z, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "visible", obj_visible, MRB_ARGS_NONE());
  mrb_define_method(M, window, "visible=", obj_set_visible, MRB_ARGS_REQ(1));
  mrb_define_method(M, window, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, window, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
  MRB_SET_INSTANCE_TT(bmp, MRB_TT_DATA);
  mrb_define_method(M, bmp, "_init_size", bmp_init_size, MRB_ARGS_REQ(2));
  // Decode from bytes already in hand — how an asset packed into an encrypted
  // RGSSAD archive is loaded (mrblib/lib.rb's Bitmap#initialize falls back to
  // it when no loose file matches).
  mrb_define_method(M, bmp, "_init_memory", bmp_init_memory,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bmp, "_init_file", bmp_init_file,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_class_method(M, bmp, "_load_error", bmp_load_error,
                          MRB_ARGS_NONE());
  mrb_define_class_method(M, bmp, "_stbi_error", bmp_stbi_error,
                          MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "width", bmp_width, MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "height", bmp_height, MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "rect", bmp_rect, MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "clear", bmp_clear, MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "fill_rect", bmp_fill_rect,
                    MRB_ARGS_REQ(2) | MRB_ARGS_OPT(3));
  mrb_define_method(M, bmp, "gradient_fill_rect", bmp_gradient_fill_rect,
                    MRB_ARGS_REQ(3) | MRB_ARGS_OPT(4));
  mrb_define_method(M, bmp, "hue_change", bmp_hue_change, MRB_ARGS_REQ(1));
  // RGSS2/RGSS3 blurs: one use each in the stock scripts (the title background
  // and the animation effects).
  mrb_define_method(M, bmp, "blur", bmp_blur, MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "radial_blur", bmp_radial_blur, MRB_ARGS_REQ(2));
  mrb_define_method(M, bmp, "get_pixel", bmp_get_pixel, MRB_ARGS_REQ(2));
  mrb_define_method(M, bmp, "set_pixel", bmp_set_pixel, MRB_ARGS_REQ(3));
  mrb_define_method(M, bmp, "blt", bmp_blt, MRB_ARGS_REQ(4) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bmp, "tone_blt", bmp_tone_blt, MRB_ARGS_REQ(2));
  mrb_define_method(M, bmp, "stretch_blt", bmp_stretch_blt,
                    MRB_ARGS_REQ(3) | MRB_ARGS_OPT(1));
  // Both RGSS forms: (x, y, width, height, str[, align]) and (rect, str[,
  // align]).
  mrb_define_method(M, bmp, "draw_text", bmp_draw_text,
                    MRB_ARGS_REQ(2) | MRB_ARGS_OPT(4));
  mrb_define_method(M, bmp, "blend_text", bmp_blend_text,
                    MRB_ARGS_REQ(10) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bmp, "text_size", bmp_text_size, MRB_ARGS_REQ(1));
  mrb_define_method(M, bmp, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* color = mrb_define_class_under(M, m, "Color", M->object_class);
  MRB_SET_INSTANCE_TT(color, MRB_TT_DATA);
  mrb_define_method(M, color, "initialize", color_init,
                    MRB_ARGS_REQ(3) | MRB_ARGS_OPT(1));
  mrb_define_method(M, color, "set", color_set,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(3));
  mrb_define_method(M, color, "red", component_get<Color, &Color::red>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, color, "green", component_get<Color, &Color::green>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, color, "blue", component_get<Color, &Color::blue>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, color, "alpha", component_get<Color, &Color::alpha>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, color, "red=", component_set<Color, &Color::red, 0, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, color,
                    "green=", component_set<Color, &Color::green, 0, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, color,
                    "blue=", component_set<Color, &Color::blue, 0, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, color,
                    "alpha=", component_set<Color, &Color::alpha, 0, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, color, "==", color_eq, MRB_ARGS_REQ(1));
  mrb_define_method(M, color, "to_s", color_to_s, MRB_ARGS_NONE());
  mrb_define_method(M, color, "_dump", color_dump, MRB_ARGS_REQ(1));
  mrb_define_class_method(M, color, "_load", color_load, MRB_ARGS_REQ(1));

  RClass* tone = mrb_define_class_under(M, m, "Tone", M->object_class);
  MRB_SET_INSTANCE_TT(tone, MRB_TT_DATA);
  mrb_define_method(M, tone, "initialize", tone_init,
                    MRB_ARGS_REQ(3) | MRB_ARGS_OPT(1));
  mrb_define_method(M, tone, "set", tone_set,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(3));
  mrb_define_method(M, tone, "red", component_get<Tone, &Tone::red>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, tone, "green", component_get<Tone, &Tone::green>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, tone, "blue", component_get<Tone, &Tone::blue>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, tone, "gray", component_get<Tone, &Tone::gray>,
                    MRB_ARGS_NONE());
  mrb_define_method(M, tone, "red=", component_set<Tone, &Tone::red, -255, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, tone,
                    "green=", component_set<Tone, &Tone::green, -255, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, tone,
                    "blue=", component_set<Tone, &Tone::blue, -255, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, tone, "gray=", component_set<Tone, &Tone::gray, 0, 255>,
                    MRB_ARGS_REQ(1));
  mrb_define_method(M, tone, "==", tone_eq, MRB_ARGS_REQ(1));
  mrb_define_method(M, tone, "to_s", tone_to_s, MRB_ARGS_NONE());
  mrb_define_method(M, tone, "_dump", tone_dump, MRB_ARGS_REQ(1));
  mrb_define_class_method(M, tone, "_load", tone_load, MRB_ARGS_REQ(1));

  RClass* table = mrb_define_class_under(M, m, "Table", M->object_class);
  MRB_SET_INSTANCE_TT(table, MRB_TT_DATA);
  mrb_define_method(M, table, "initialize", table_init,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2));
  mrb_define_method(M, table, "[]", table_get,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2));
  mrb_define_method(M, table, "[]=", table_set,
                    MRB_ARGS_REQ(2) | MRB_ARGS_OPT(2));
  mrb_define_method(M, table, "resize", table_resize,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(2));
  mrb_define_method(
      M, table, "xsize",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Table>::get(M, self).xsize);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, table, "ysize",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Table>::get(M, self).ysize);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, table, "zsize",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Table>::get(M, self).zsize);
      },
      MRB_ARGS_NONE());
  mrb_define_method(
      M, table, "dim",
      [](mrb_state* M, V self) {
        return mrb_fixnum_value(DataType<Table>::get(M, self).dim);
      },
      MRB_ARGS_NONE());
  mrb_define_method(M, table, "_dump", table_dump, MRB_ARGS_REQ(1));
  mrb_define_class_method(M, table, "_load", table_load, MRB_ARGS_REQ(1));

  // RGSS::Input is otherwise pure Ruby (mrblib/lib.rb reopens this module); the
  // two native hooks are the backend drain Input.update calls and the test-side
  // push that stands in for a keyboard.
  RClass* input = mrb_define_module_under(M, m, "Input");
  mrb_define_module_function(M, input, "_poll", input_poll, MRB_ARGS_NONE());
  mrb_define_module_function(M, input, "_push", input_push, MRB_ARGS_REQ(2));

  RClass* gfx = mrb_define_module_under(M, m, "Graphics");
  mrb_define_module_function(M, gfx, "update", gfx_update, MRB_ARGS_NONE());
  // RGSS2+: the rendered screen as a Bitmap. Graphics.freeze/transition are
  // built on it (mrblib/lib.rb), and RGSS.effect_probe measures with it.
  mrb_define_module_function(M, gfx, "snap_to_bitmap", gfx_snap_to_bitmap,
                             MRB_ARGS_NONE());

  profiler_init(M);

  rgss_audio_define(M, m);

  define_rect(M, m);
}

extern "C" void mrb_mruby_rgss_gem_final(mrb_state* mrb) {
  // Flush and close a Chrome trace still open at shutdown (native path; the
  // Emscripten loop never returns, but the format tolerates the missing close).
  profiler_trace_stop();
}

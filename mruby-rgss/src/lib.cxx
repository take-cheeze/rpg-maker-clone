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

mrb_value table_set(mrb_state* M, V self) {
  mrb_int p0, p1, p2 = 0, p3 = 0;
  mrb_get_args(M, "ii|ii", &p0, &p1, &p2, &p3);
  mrb_int argc = mrb_get_argc(M);
  mrb_int x = p0, y = 0, z = 0, v;
  if (argc == 2) {
    v = p1;
  } else if (argc == 3) {
    y = p1;
    v = p2;
  } else {
    y = p1;
    z = p2;
    v = p3;
  }
  Table& t = DataType<Table>::get(M, self);
  long i = table_index(t, x, y, z);
  if (i >= 0)
    t.data[i] = (int16_t)v;
  return mrb_fixnum_value(v);
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
// returns nullptr when `f` is not a readable XYZ file. When `trans` is set the
// first palette entry is treated as the transparent colour, matching stb's
// transparent-palette handling for PNGs.
static uint8_t* load_xyz(const char* f, int* w, int* h, int* c, bool trans) {
  std::FILE* fp = std::fopen(f, "rb");
  if (!fp)
    return nullptr;
  std::fseek(fp, 0, SEEK_END);
  const long sz = std::ftell(fp);
  std::fseek(fp, 0, SEEK_SET);
  if (sz < 8) {
    std::fclose(fp);
    return nullptr;
  }
  std::vector<uint8_t> data((size_t)sz);
  const size_t got = std::fread(data.data(), 1, (size_t)sz, fp);
  std::fclose(fp);
  // Not an XYZ file: stay silent and let the caller keep stb_image's own error.
  if (got != (size_t)sz || std::memcmp(data.data(), "XYZ1", 4) != 0)
    return nullptr;

  const int width = data[4] | (data[5] << 8);
  const int height = data[6] | (data[7] << 8);
  if (width <= 0 || height <= 0) {
    set_bitmap_load_error("XYZ: invalid dimensions %dx%d in '%s'", width,
                          height, f);
    return nullptr;
  }

  const char* stream = reinterpret_cast<const char*>(data.data() + 8);
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
          width, height, f, zerr, (unsigned)data[8], (unsigned)data[9],
          stream_len, expected);
      return nullptr;
    }
  }

  if ((long)outlen < expected) {
    set_bitmap_load_error(
        "XYZ %dx%d '%s': short data, got %d bytes, expected %ld (768 palette + "
        "%d pixels)",
        width, height, f, outlen, expected, width * height);
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

// Decode `f` as a PNG using the tolerant inflater above. Returns a freshly
// stb-allocated (free with stbi_image_free) width*height*4 B, G, R, A buffer
// and sets *w/*h/*c, or nullptr when the file is not a PNG this fallback
// handles (non-interlaced; bit depth 8, or indexed 1/2/4). `trans` maps palette
// index 0 to transparent, matching the primary loader's colour-key handling.
static uint8_t* load_png_tolerant(const char* f,
                                  int* wout,
                                  int* hout,
                                  int* c,
                                  bool trans) {
  std::FILE* fp = std::fopen(f, "rb");
  if (!fp)
    return nullptr;
  std::fseek(fp, 0, SEEK_END);
  const long sz = std::ftell(fp);
  std::fseek(fp, 0, SEEK_SET);
  static const uint8_t sig[8] = {0x89, 0x50, 0x4e, 0x47,
                                 0x0d, 0x0a, 0x1a, 0x0a};
  if (sz < 8) {
    std::fclose(fp);
    return nullptr;
  }
  std::vector<uint8_t> d((size_t)sz);
  const size_t got = std::fread(d.data(), 1, (size_t)sz, fp);
  std::fclose(fp);
  if (got != (size_t)sz || std::memcmp(d.data(), sig, 8) != 0)
    return nullptr;

  int w = 0, h = 0, depth = 0, ct = 0, interlace = 0;
  std::vector<uint8_t> idat, plte, trns;
  size_t i = 8;
  while (i + 8 <= (size_t)sz) {
    const uint32_t len = png_tol::be32(d.data() + i);
    const uint8_t* typ = d.data() + i + 4;
    const uint8_t* body = d.data() + i + 8;
    if (i + 12 + len > (size_t)sz)
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
        w, h, depth, ct, f);
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

mrb_value bmp_init_file(mrb_state* M, mrb_value self) {
  const char* f;
  mrb_bool trans = false;
  mrb_get_args(M, "z|b", &f, &trans);
  int w, h, c;
  stbi__png_transparent_palette = trans;
  stbi__png_to_bgr_palette = true;
  std::shared_ptr<uint8_t> img(
      stbi_load(f, &w, &h, &c, stbi__png_transparent_palette ? 4 : 3),
      stbi_image_free);
  if (!img)
    img.reset(load_xyz(f, &w, &h, &c, trans), stbi_image_free);
  // stb_image rejects some valid-enough PNGs (e.g. RPG Maker windowskins whose
  // deflate stream references a zero pre-history, giving "bad dist"); retry
  // with the tolerant PNG decoder before giving up.
  if (!img)
    img.reset(load_png_tolerant(f, &w, &h, &c, trans), stbi_image_free);
  if (!img) {
    // Some archives store filenames in NFD form while the game data refers to
    // them in NFC (or vice versa); retry with the decomposed form before giving
    // up so accented paths still resolve.
    const std::string nfd_f = una::norm::to_nfd_utf8(f);
    img.reset(stbi_load(nfd_f.c_str(), &w, &h, &c,
                        stbi__png_transparent_palette ? 4 : 3),
              stbi_image_free);
    if (!img)
      img.reset(load_xyz(nfd_f.c_str(), &w, &h, &c, trans), stbi_image_free);
    if (!img)
      img.reset(load_png_tolerant(nfd_f.c_str(), &w, &h, &c, trans),
                stbi_image_free);
    if (!img)
      return mrb_nil_value();
  }
  Bitmap& bmp = DataType<Bitmap>::alloc_obj(
      M, self, w, h,
      c == 4 ? LV_COLOR_FORMAT_ARGB8888 : LV_COLOR_FORMAT_RGB888);
  std::memcpy(bmp.buffer.data(), img.get(), bmp.buffer.size());
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
      const int inv = 255 - alpha;
      bmp_put(dst, dx, dy, (r * alpha + dr * inv) / 255,
              (g * alpha + dg * inv) / 255, (bl * alpha + db * inv) / 255,
              std::max(da, alpha));
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
      const int inv = 255 - alpha;
      bmp_put(dst, dx, dy, (r * alpha + dr2 * inv) / 255,
              (g * alpha + dg * inv) / 255, (bl * alpha + db * inv) / 255,
              std::max(da, alpha));
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

// Loaded fonts cached by requested family name (the search roots are fixed for
// a run). A cached entry may hold an unloaded font (ok == false), i.e. "no
// usable font for this name"; that negative result is cached too, so the
// Fonts/ directory is scanned only once per name.
std::shared_ptr<TtfFont> ttf_for_name(mrb_state* M, const std::string& name) {
  static std::map<std::string, std::shared_ptr<TtfFont>> cache;
  const auto it = cache.find(name);
  if (it != cache.end())
    return it->second;
  const std::string path = find_font_path(M, name);
  std::shared_ptr<TtfFont> f =
      path.empty() ? std::make_shared<TtfFont>() : load_ttf(path);
  cache[name] = f;
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

mrb_value bmp_draw_text(mrb_state* M, mrb_value self) {
  auto& bmp = bmp_self(M, self);

  mrb_int x, y, w, h, len;
  mrb_int align = 0;
  const char* s;
  mrb_get_args(M, "iiiis|i", &x, &y, &w, &h, &s, &len, &align);
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

mrb_value obj_disposed(mrb_state* M, mrb_value self) {
  return mrb_bool_value(DATA_PTR(self));
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

mrb_value gfx_update(mrb_state* M, mrb_value self) {
  const uint32_t frame_start = lv_tick_get();
  const mrb_value rgss_mod = mrb_obj_value(mrb_module_get(M, "RGSS"));

  rgss_terminal_poll(M);
  rgss_sdl_poll(M);
#if defined(WIO_TERMINAL)
  rgss_wio_poll(M);
#endif
#if defined(PSP_BUILD)
  rgss_psp_poll(M);
#endif
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

  const int32_t sleep = 1000 / 60 - lv_tick_elaps(frame_start);
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
void spr_bind_display(mrb_state* M, mrb_value self, lv_obj_t* obj) {
  const mrb_value bmp_v = mrb_iv_get(M, self, mrb_intern_lit(M, "@bitmap"));
  if (mrb_nil_p(bmp_v))
    return;
  Bitmap& src = DataType<Bitmap>::get(M, bmp_v);
  if (mrb_test(mrb_iv_get(M, self, mrb_intern_lit(M, "@mirror")))) {
    RClass* bmp_class =
        mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Bitmap");
    const mrb_value flip_v =
        DataType<Bitmap>::make(M, bmp_class, src.width, src.height, src.format);
    Bitmap& flip = DataType<Bitmap>::get(M, flip_v);
    const int px = lv_color_format_get_size(src.format);
    const int w = src.width;
    for (int y = 0; y < src.height; ++y) {
      const uint8_t* srow = src.buffer.data() + static_cast<size_t>(y) * w * px;
      uint8_t* drow = flip.buffer.data() + static_cast<size_t>(y) * w * px;
      for (int x = 0; x < w; ++x)
        std::memcpy(drow + static_cast<size_t>(x) * px,
                    srow + static_cast<size_t>(w - 1 - x) * px, px);
    }
    flip.dirty = true;
    // Hold the scratch bitmap on the sprite so the GC keeps it alive.
    mrb_iv_set(M, self, mrb_intern_lit(M, "@_mirror_bitmap"), flip_v);
    lv_canvas_set_buffer(obj, flip.buffer.data(), src.width, src.height,
                         src.format);
  } else {
    mrb_iv_set(M, self, mrb_intern_lit(M, "@_mirror_bitmap"), mrb_nil_value());
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

// ---- Viewport -------------------------------------------------------------

// Build an RGSS::Rect value.
mrb_value make_rect(mrb_state* M, mrb_int x, mrb_int y, mrb_int w, mrb_int h) {
  const mrb_value args[] = {mrb_fixnum_value(x), mrb_fixnum_value(y),
                            mrb_fixnum_value(w), mrb_fixnum_value(h)};
  return mrb_obj_new(
      M, mrb_class_get_under(M, mrb_module_get(M, "RGSS"), "Rect"), 4, args);
}

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

// Present so the game loop can drive per-frame behaviour (flash, etc.); no
// animated viewport effects are modelled yet, so this is a no-op.
mrb_value vp_update(mrb_state* M, mrb_value self) {
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

  RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
  MRB_SET_INSTANCE_TT(bmp, MRB_TT_DATA);
  mrb_define_method(M, bmp, "_init_size", bmp_init_size, MRB_ARGS_REQ(2));
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
  mrb_define_method(M, bmp, "get_pixel", bmp_get_pixel, MRB_ARGS_REQ(2));
  mrb_define_method(M, bmp, "set_pixel", bmp_set_pixel, MRB_ARGS_REQ(3));
  mrb_define_method(M, bmp, "blt", bmp_blt, MRB_ARGS_REQ(4) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bmp, "stretch_blt", bmp_stretch_blt,
                    MRB_ARGS_REQ(3) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bmp, "draw_text", bmp_draw_text,
                    MRB_ARGS_REQ(5) | MRB_ARGS_OPT(1));
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

  RClass* gfx = mrb_define_module_under(M, m, "Graphics");
  mrb_define_module_function(M, gfx, "update", gfx_update, MRB_ARGS_NONE());

  profiler_init(M);

  rgss_audio_define(M, m);

  define_rect(M, m);
}

extern "C" void mrb_mruby_rgss_gem_final(mrb_state* mrb) {
  // Flush and close a Chrome trace still open at shutdown (native path; the
  // Emscripten loop never returns, but the format tolerates the missing close).
  profiler_trace_stop();
}

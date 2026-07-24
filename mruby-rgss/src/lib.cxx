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

#include "shinonome.hxx"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <vector>

#include <iostream>

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

// Defined in terminal.cxx (same gem).  A no-op unless the game was started with
// a terminal backend (--sixel / --iterm); forwards terminal keyboard input to
// RGSS::Input.
extern "C" void rgss_terminal_poll(mrb_state* M);

namespace {
mrb_value to_nfd(mrb_state* M, mrb_value self) {
  const char* ptr;
  mrb_int len;
  mrb_get_args(M, "s", &ptr, &len);
  std::string nfd = una::norm::to_nfd_utf8(std::string_view(ptr, len));
  return mrb_str_new(M, nfd.data(), nfd.size());
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
  if (!img) {
    // Some archives store filenames in NFD form while the game data refers to
    // them in NFC (or vice versa); retry with the decomposed form before giving
    // up so accented paths still resolve.
    const std::string nfd_f = una::norm::to_nfd_utf8(f);
    img.reset(stbi_load(nfd_f.c_str(), &w, &h, &c,
                        stbi__png_transparent_palette ? 4 : 3),
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

  // Text color comes from the bitmap's font when one has been assigned,
  // otherwise default to opaque black.
  uint8_t col[4] = {0, 0, 0, 255};
  V fv = mrb_iv_get(M, self, mrb_intern_lit(M, "@font"));
  if (!mrb_nil_p(fv)) {
    V cv = mrb_funcall(M, fv, "color", 0);
    if (!mrb_nil_p(cv)) {
      Color& c = DataType<Color>::get(M, cv);
      col[0] = (uint8_t)c.blue;
      col[1] = (uint8_t)c.green;
      col[2] = (uint8_t)c.red;
      col[3] = (uint8_t)c.alpha;
    }
  }

  // Horizontal alignment: 0 left, 1 center, 2 right.
  int tw = 0;
  unsigned th = 0;
  measure_text(std::string_view(s, len), tw, th);
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

  for (const char32_t c : std::string_view(s, len) | una::views::utf8) {
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

  int w = 0;
  unsigned height = 0;
  measure_text(std::string_view(s, len), w, height);

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

  lv_timer_handler();
  lv_task_handler();

  // Advance Graphics.frame_count, matching RGSS semantics.
  V gfx = mrb_obj_value(
      mrb_module_get_under(M, mrb_module_get(M, "RGSS"), "Graphics"));
  V fc = mrb_iv_get(M, gfx, mrb_intern_lit(M, "@frame_count"));
  mrb_iv_set(M, gfx, mrb_intern_lit(M, "@frame_count"),
             mrb_fixnum_value((mrb_fixnum_p(fc) ? mrb_fixnum(fc) : 0) + 1));

  const int32_t sleep = 1000 / 60 - lv_tick_elaps(frame_start);
  if (sleep > 0) {
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

mrb_value spr_set_bmp(mrb_state* M, mrb_value self) {
  Bitmap* p;
  mrb_get_args(M, "d", &p, &DataType<Bitmap>::data_type);
  V bmp;
  mrb_get_args(M, "o", &bmp);
  mrb_iv_set(M, self, mrb_intern_lit(M, "@bitmap"), bmp);
  lv_obj_t* obj = reinterpret_cast<lv_obj_t*>(DATA_PTR(self));
  mrb_assert(obj);
  lv_canvas_set_buffer(obj, p->buffer.data(), p->width, p->height, p->format);
  // Repaint the newly assigned bitmap on the next Graphics.update, even if its
  // contents were drawn before it was attached to this sprite.
  p->dirty = true;
  return bmp;
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

extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display) {
  mrb_assert(!mrb_const_defined(M, mrb_obj_value(mrb_module_get(M, "RGSS")),
                                mrb_intern_lit(M, "_display")));
  mrb_const_set(M, mrb_obj_value(mrb_module_get(M, "RGSS")),
                mrb_intern_lit(M, "_display"), mrb_cptr_value(M, display));
}

extern "C" void mrb_mruby_rgss_gem_init(mrb_state* M) {
  RClass* m = mrb_define_module(M, "RGSS");
  mrb_define_module_function(M, m, "to_nfd", to_nfd, MRB_ARGS_REQ(1));

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

  RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
  MRB_SET_INSTANCE_TT(bmp, MRB_TT_DATA);
  mrb_define_method(M, bmp, "_init_size", bmp_init_size, MRB_ARGS_REQ(2));
  mrb_define_method(M, bmp, "_init_file", bmp_init_file,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
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

  define_rect(M, m);
}

extern "C" void mrb_mruby_rgss_gem_final(mrb_state* mrb) {}

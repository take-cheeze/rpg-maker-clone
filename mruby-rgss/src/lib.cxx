#include <mruby.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/value.h>
#include <mruby/variable.h>

#include <uni_algo/norm.h>
#include <uni_algo/ranges.h>
#include <uni_algo/ranges_conv.h>

#include <lvgl.h>

#include "shinonome.hxx"

#include <cstring>
#include <memory>
#include <vector>

#include <iostream>

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>

namespace {
mrb_value to_nfd(mrb_state* M, mrb_value self) {
  const char* ptr;
  mrb_int len;
  mrb_get_args(M, "s", &ptr, &len);
  std::string nfd = una::norm::to_nfd_utf8(std::string_view(ptr, len));
  return mrb_str_new(M, nfd.data(), nfd.size());
}

using V = ::mrb_value;

struct Rect {
  mrb_int x{0}, y{0}, width{0}, height{0};
};

struct Bitmap {
  int32_t width, height;
  lv_color_format_t format;
  std::vector<uint8_t> buffer;

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

  static T& get(mrb_state* M, V self) {
    return *reinterpret_cast<T*>(mrb_data_get_ptr(M, self, &data_type));
  }
};

template <class T>
mrb_data_type DataType<T>::data_type{
    typeid(T).name(),
    &DataType<T>::free_obj,
};

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
    return mrb_nil_value();
  Bitmap& bmp = DataType<Bitmap>::alloc_obj(
      M, self, w, h,
      c == 4 ? LV_COLOR_FORMAT_ARGB8888 : LV_COLOR_FORMAT_RGB888);
  std::memcpy(bmp.buffer.data(), img.get(), bmp.buffer.size());
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

mrb_value bmp_draw_text(mrb_state* M, mrb_value self) {
  mrb_assert(DATA_PTR(self));

  auto& bmp = *reinterpret_cast<Bitmap*>(DATA_PTR(self));

  mrb_int x, y, w, h, len;
  const char* s;
  mrb_get_args(M, "iiiis", &x, &y, &w, &h, &s, &len);

  auto draw = [&x, y, &bmp](const auto& c) {
    static const uint8_t col[] = {0, 0, 0, 0};
    const unsigned col_len = lv_color_format_get_size(bmp.format);
    for (unsigned i = 0; i < c.HEIGHT; ++i) {
      for (unsigned j = 0; j < c.WIDTH; ++j) {
        const unsigned idx = i * c.WIDTH + j;
        if (c.data[idx / 32] & (1 << (idx % 32)))
          std::memcpy(
              bmp.buffer.data() + ((y + i) * bmp.width + j + x) * col_len, col,
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
    auto h = find_char(c, shinonome::LATIN1, shinonome::LATIN1_LEN);
    if (h) {
      draw(*h);
      continue;
    }
    h = find_char(c, shinonome::HANKAKU, shinonome::HANKAKU_LEN);
    if (h) {
      draw(*h);
      continue;
    }
  }

  return self;
}

mrb_value bmp_text_size(mrb_state* M, mrb_value self) {
  mrb_int len;
  const char* s;
  mrb_get_args(M, "s", &s, &len);

  int w = 0;
  unsigned height = 0;

  for (const char32_t c : std::string_view(s, len) | una::views::utf8) {
    auto f = find_char(c, shinonome::GOTHIC, shinonome::GOTHIC_LEN);
    if (f) {
      w += f->WIDTH;
      height = std::max(height, f->HEIGHT);
      continue;
    }
    auto h = find_char(c, shinonome::LATIN1, shinonome::LATIN1_LEN);
    if (h) {
      w += h->WIDTH;
      height = std::max(height, h->HEIGHT);
      continue;
    }
    h = find_char(c, shinonome::HANKAKU, shinonome::HANKAKU_LEN);
    if (h) {
      w += h->WIDTH;
      height = std::max(height, h->HEIGHT);
      continue;
    }
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

mrb_value gfx_update(mrb_state* M, mrb_value self) {
  const uint32_t frame_start = lv_tick_get();
  const mrb_value rgss_mod = mrb_obj_value(mrb_module_get(M, "RGSS"));

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

  lv_timer_handler();
  lv_task_handler();

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

lv_obj_t* parent_object(mrb_state* M, mrb_value vp) {
  if (mrb_nil_p(vp))
    return lv_display_get_screen_active(get_display(M));

  mrb_assert(mrb_type(vp) == MRB_TT_DATA && DATA_TYPE(vp) == &obj_type);
  return reinterpret_cast<lv_obj_t*>(DATA_PTR(vp));
}

mrb_value spr_init(mrb_state* M, mrb_value self) {
  mrb_value vp = mrb_nil_value();
  mrb_get_args(M, "|o", &vp);

  lv_obj_t* p = lv_canvas_create(parent_object(M, vp));
  mrb_data_init(self, p, &obj_type);
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
  return bmp;
}

mrb_value vp_init(mrb_state* M, mrb_value self) {
  lv_obj_t* p = lv_canvas_create(lv_display_get_screen_active(get_display(M)));
  mrb_data_init(self, p, &obj_type);
  return self;
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

  RClass* vp = mrb_define_class_under(M, m, "Viewport", M->object_class);
  MRB_SET_INSTANCE_TT(vp, MRB_TT_DATA);
  mrb_define_method(M, vp, "initialize", vp_init, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, vp, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* spr = mrb_define_class_under(M, m, "Sprite", M->object_class);
  MRB_SET_INSTANCE_TT(spr, MRB_TT_DATA);
  mrb_define_method(M, spr, "initialize", spr_init, MRB_ARGS_OPT(1));
  mrb_define_method(M, spr, "bitmap=", spr_set_bmp, MRB_ARGS_REQ(1));
  mrb_define_method(M, spr, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, spr, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* bmp = mrb_define_class_under(M, m, "Bitmap", M->object_class);
  MRB_SET_INSTANCE_TT(bmp, MRB_TT_DATA);
  mrb_define_method(M, bmp, "_init_size", bmp_init_size, MRB_ARGS_REQ(2));
  mrb_define_method(M, bmp, "_init_file", bmp_init_file,
                    MRB_ARGS_REQ(1) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bmp, "draw_text", bmp_draw_text,
                    MRB_ARGS_REQ(5) | MRB_ARGS_OPT(1));
  mrb_define_method(M, bmp, "text_size", bmp_text_size, MRB_ARGS_REQ(1));
  mrb_define_method(M, bmp, "dispose", obj_dispose, MRB_ARGS_NONE());
  mrb_define_method(M, bmp, "disposed?", obj_disposed, MRB_ARGS_NONE());

  RClass* gfx = mrb_define_module_under(M, m, "Graphics");
  mrb_define_module_function(M, gfx, "update", gfx_update, MRB_ARGS_NONE());

  RClass* rect = mrb_define_class_under(M, m, "Rect", M->object_class);
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
}

extern "C" void mrb_mruby_rgss_gem_final(mrb_state* mrb) {}

// The port's half of the own compositor (RGSS_GFX_OWN, mruby-rgss/src/
// gfx_own.cxx): the port lends it a strip of RGB565 pixels and a way to push a
// rectangle of them to the panel, and gets back the display to hand to
// rgss_set_display.
#pragma once

#include <cstddef>
#include <cstdint>

struct mrb_state;

// Pushes `px` (w x h RGB565, rows w apart) to the panel at (x, y). The strip
// is drawn into again once this returns.
typedef void (*RgssOwnFlush)(int32_t x,
                             int32_t y,
                             int32_t w,
                             int32_t h,
                             const uint16_t* px);

struct RgssOwnConfig {
  int32_t width, height;
  // At least `width` pixels; a strip is as many whole rows as fit.
  uint16_t* strip;
  size_t strip_px;
  RgssOwnFlush flush;
  uint32_t (*tick_ms)(void);
  void (*delay_ms)(uint32_t);
  // The least time between two draws (LVGL's refresh period); 0 draws on
  // every Graphics.update.
  uint32_t refresh_period_ms;
};

// The one display (a second call answers the first). The config is copied.
struct RgssOwnDisplay;
RgssOwnDisplay* rgss_own_display_create(const RgssOwnConfig* config);
void rgss_own_set_refresh_period(RgssOwnDisplay* d, uint32_t ms);
// Draws what changed now, whatever the refresh period says.
void rgss_own_draw_now(RgssOwnDisplay* d);

extern "C" void rgss_set_display(mrb_state* M, RgssOwnDisplay* display);

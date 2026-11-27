- The RGSS natives draw through a small display-list backend
  (`mruby-rgss/src/gfx.hxx`) instead of calling LVGL directly; LVGL is its only
  implementation (`gfx_lvgl.cxx`), so every port draws the same frames as
  before.

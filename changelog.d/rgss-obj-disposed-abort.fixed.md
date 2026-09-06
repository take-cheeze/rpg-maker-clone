- **Touching a disposed Sprite/Viewport/Window/Tilemap now raises a catchable
  `RGSS::RGSSError`, instead of either aborting the whole process or (in a
  release build) making an unguarded null-pointer LVGL call.** `Bitmap`
  already had this: `bmp_require` (`mruby-rgss/src/lib.cxx`) turns a disposed
  source into `RGSSError`, matching real RGSS. The `lv_obj_t`-backed types
  (Sprite, Viewport, Window, Tilemap) never got the same treatment — their
  explicit setters (`x=`, `y=`, `visible=`, `opacity=`, `bitmap=`, `angle=`,
  `zoom_x=`/`zoom_y=`, `mirror=`, `tone=`/`color=`, `src_rect=`,
  `blend_type=`, `bush_depth=`, `#flash`, a Tilemap's `visible=`, a Window's
  `viewport=`) read `DATA_PTR(self)` straight into a bare
  `mrb_assert(obj)`, which is a real `abort()` under this build's
  `-DMRB_DEBUG` — the exact crash fixed by the previous entry above, a
  battle-loss Game Over disposing the whole scene mid-frame while
  `Scene::Map#update` kept running and touched its own now-disposed
  `@player_sprite` — and, since `mrb_assert` compiles away to nothing without
  `MRB_DEBUG`, silent undefined behaviour otherwise. A new `obj_require`
  helper (the `lv_obj_t` twin of `bmp_require`, right next to
  `wrap_lv_obj`) replaces every one of those `mrb_assert(obj)` sites, plus
  one setter (`window_ensure_canvas`, reached from `width=`/`height=`) that
  had no guard at all. This is defense in depth on top of the `Scene::Map`
  fix above: that fix stops this specific mid-frame case from ever reaching
  a disposed sprite; this one means any *other* path that still manages to
  touch one — a script bug, a future refactor — fails with a normal Ruby
  exception a `rescue` can catch, the same as a disposed Bitmap already
  does, rather than crashing the process outright.

- **`RGSS::Bitmap#clone` / `#dup` copy the pixels.** RGSS's own `RPG::Cache`
  builds a hue variant with `@cache[path].clone` followed by `hue_change`, so one
  decode of a charset serves every hue a game asks for. mruby's `clone` left a
  data object's native payload behind entirely, and a copy that merely *shared*
  the buffer would have been worse — `hue_change` rewrites it in place, so it
  would have recoloured the cached original along with the variant.
  `initialize_copy` now copies the buffer, marks the copy dirty so anything
  already showing it repaints, and gives it its own `Font` so a size or colour
  set on the clone cannot reach back into the bitmap it came from. With that,
  `RPG::Cache` is the definition RGSS publishes again, instead of loading the
  file a second time per hue.

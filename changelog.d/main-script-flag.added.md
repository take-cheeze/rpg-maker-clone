- **`--script <file>`** runs an mruby script directly as the entry point
  instead of booting a detected RPG Maker project, with `ARGV`/`$0` set up the
  same way a native `ruby` invocation would. Not available in the emscripten
  build. `scripts/preview_image.rb` is a first user: it loads a single
  `Bitmap` into a `Sprite` for a quick visual check.

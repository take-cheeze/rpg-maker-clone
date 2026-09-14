- `app/wio/exclude_lvgl_asm.py` (drops LVGL's Helium/NEON `.S` kernels
  before every embedded build) globbed relative to the invoking
  PlatformIO project's working directory instead of the repo root, so it
  silently excluded nothing for `app/m5stack`'s own standalone project
  (which sits one directory root away) -- found while adding that port.
  Now walks up from `$PROJECT_DIR` to find `3rd/lvgl/src`, verified against
  both project roots.

- **The embedded Shinonome JIS0208 kanji face can now live on the SD card
  instead of in flash**, opt-in via `SHINONOME_GOTHIC_SD_FILE` (build time)
  and `RGSS_SHINONOME_GOTHIC_SD_PATH` (the on-device path) — real, measured
  cut on a full relink: 164,816 bytes, essentially the whole face. Unlike
  the mruby-rpg2k SD-offload attempt this project already tried and
  abandoned (RAM cost scaling with bytecode size), a font glyph is fixed-
  size raw data: the new `find_gothic_char` (mruby-rgss) falls back to a
  plain `std::fopen`-based binary search — the same file API every asset
  load already uses — with a small 64-glyph cache, verified byte-for-byte
  against the compiled-in data on the host. Neither flag is on by default;
  see ADR 110 for what's still open (SD read latency on a cache miss is
  unmeasured against any real game data).

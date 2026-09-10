- **wio: stb_image's JPEG decoder no longer compiles in.** `wio` ships
  `mruby-rpg2k` only (`single_format_only`) and RPG2000/2003's own real asset
  search never tries a `.jpg`/`.jpeg` candidate (`RGSS::Bitmap::
  RPG2K_EXTENSIONS`, measured against a real `RPG_RT.exe` under wine) — JPEG
  only exists for the RPG Maker XP/VX RTP, a maker wio never compiles in.
  `mruby-rgss/src/lib.cxx` now defines `STBI_NO_JPEG` under `WIO_TERMINAL`,
  alongside the existing GIF/PSD/TGA/HDR/PIC/PNM exclusions. Desktop/wasm/
  android/psp are unaffected. Measured on a real `wio_rgss_boot` relink:
  `region 'FLASH' overflowed by` 684,624 → 675,960 bytes (8,664 bytes). See
  `docs/adr/0140-wio-jpeg-decoder-trim.md`.

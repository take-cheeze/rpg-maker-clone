- **The Wio Terminal build no longer links uni-algo's NFD normalization
  tables (~94 KB, docs/adr/0105's own measurement).** `RGSS.to_nfd` and
  `Bitmap#_init_file`'s own filename-normalization retry both exist to work
  around a real but narrow bug class (a macOS-authored archive storing
  filenames in NFD while the game data references them in NFC, or vice
  versa) — genuinely useful on desktop/PSP, but a meaningful chunk of a
  512 KB-flash target's budget for a fallback path this project's own export
  pipeline never actually exercises (it writes one consistent normalization
  form). Both are now no-ops on `WIO_TERMINAL` specifically; every other
  target's behavior, including the existing `RGSS.to_nfd` test, is
  unchanged. Confirmed via a real relink: flash overflow drops by 96,424
  bytes.

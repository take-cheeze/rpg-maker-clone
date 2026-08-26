- **RPG2k's weather, screen-flash, and picture compositing overlays now
  build their screen-sized buffer lazily on first actual use, instead of
  every map visit paying for all three whether or not they're ever
  needed.** `Scene::Map#setup_screen_overlay`/`#setup_pictures` used to
  allocate `@weather_bmp`/`@flash_bmp`/`@picture_bmp` (307,200 B decoded
  each, ARGB8888) unconditionally at scene setup; most maps never turn on
  weather, many never trigger a Screen Flash, and a fair number never run
  Show Picture at all. Each buffer (and the sprite it feeds) is now created
  the first time `#draw_weather`/the flash branch of
  `#update_screen_overlay`/`#draw_pictures` actually needs to paint into
  it -- an untouched map now skips up to ~900 KB of what
  `docs/adr/0047-psp-memory-budget.md`'s Finding 3 calls the "third pool"
  (native-heap `Bitmap` buffers, not the mruby arena; see also #1385's new
  `bmp_blank` heartbeat field, which measured this exact pool as the
  largest uncapped one found so far). `@fade_bmp` stays eager -- a map
  transition arrives via a fade far too often for laziness to pay off
  there. Verified locally: `scripts/rpg2k_scene_check.rb` (929 checks) and
  `scripts/rpg2k_logic_check.rb` (1145 checks) both pass unchanged, after
  updating four scene-check tests that grabbed `@picture_bmp`/`@weather_bmp`
  before the first draw that would now create them.

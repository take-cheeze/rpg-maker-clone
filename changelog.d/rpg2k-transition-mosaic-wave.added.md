- **Erase / Show Screen's Mosaic (setting 17) and Wave (setting 18) styles now
  paint real per-pixel resamples.** They were the last two styles in the
  transition family and used to run as a plain fade of the right length —
  scroll, combine / division, zoom and random blocks were already done, but
  these two genuinely wanted a native pass (a `get_pixel`/`set_pixel` loop
  over every frame of a 320x240 screen is far too slow in Ruby). Added two
  `mruby-rgss` `Bitmap` primitives following `#tone_blt`/`#stretch_blt`'s
  shape: `#mosaic_blt(src, block_size)` resamples each pixel from the pixel
  nearest the centre of its `block_size`x`block_size` block, and
  `#wave_blt(src, depth, phase)` displaces each scanline horizontally by a
  sine wave. Both are ported from EasyRPG Player's real source
  (`src/transition.cpp`'s `TransitionMosaicIn`/`Out` and
  `TransitionWaveIn`/`Out` cases, and `Bitmap::WaverBlit` in
  `src/bitmap.cpp`, fetched verbatim): the mosaic block size ramps
  `@frames..1` for a Show (sharpening out of a mosaic) and `1..@frames` for
  an Erase (dissolving into one); the wave depth follows the same ramp with
  `phase = p * 5 * PI / tf_off + PI`. RPG_RT also nudges the mosaic sampling
  window by a small per-frame random offset, which this port omits for a
  deterministic, unit-testable block centre — the same kind of reasoned
  simplification the random-blocks Down/Up bias already is elsewhere in
  `Game::Transition`. Both styles ride the same captured-screen snapshot
  machinery scroll / combine / division / zoom already use
  (`Game::Transition::CAPTURED`, `Scene::Map#draw_captured_transition`)
  rather than a black mask, since a mask cannot express a resample. With
  this, every Erase / Show Screen setting (0–19) paints for real. Covered by
  new checks in `mruby-rgss/test/test.rb` (the native primitives),
  `scripts/rpg2k_logic_check.rb` (the block-size/depth/phase ramps) and
  `scripts/rpg2k_scene_check.rb` (the native calls reached with the right
  per-frame parameters).

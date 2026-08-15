- **Erase / Show Screen's random-blocks styles (settings 1–3) now paint real
  blocks.** They used to run as a plain fade of the right length, the wrong
  texture, because the style wants RPG_RT's *incremental* per-frame block
  reveal rather than a full repaint every frame — the last unbuilt style in
  the transition family (scroll, combine / division, zoom and the mask
  styles were already done). Confirmed against EasyRPG's real source: `size_
  random_blocks = 4` in `src/transition.h` (a 4×4-pixel block, so 320×240 is
  an 80×60 grid, 4800 blocks) and `src/transition.cpp`'s `Draw`
  (`blocks_to_print = random_blocks.size() * (current_frame + 1) / tf_off`,
  a linear cumulative-reveal ramp — 120 blocks a frame over the 41-frame
  default length). `Game::Transition#new_block_rects` returns only the
  blocks newly revealed each frame, computed from a deterministic
  permutation of every block index rather than held shuffle/RNG state, so it
  stays pure logic and replayable like `#capture_ops`/`#visible_rects`.
  `Scene::Map#draw_random_blocks_transition` paints the overlay solid black
  once and punches only the new blocks out of it every frame after, instead
  of the full-cumulative-mask-every-frame shape `#visible_rects`'s other
  mask styles use — the "incremental paint" this style was left without.
  The plain style shuffles every block into one random order; **Down**/**Up**
  bias that order by row (top-to-bottom / bottom-to-top) rather than
  attempting to replicate EasyRPG's own windowed per-row shuffle, since that
  depends on matching its RNG stream too. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` (block-grid geometry, cumulative no-repeat
  coverage, the Down/Up row bias) and `scripts/rpg2k_scene_check.rb` (the
  incremental overlay paint).

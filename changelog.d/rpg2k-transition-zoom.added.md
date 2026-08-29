- **Erase / Show Screen's zoom style now paints real pixels.** It used to run
  as a plain fade of the right length, the wrong texture, because zoom's own
  in/out direction had nothing in either test bed to confirm it against (see
  the prior "scroll and combine / division" note, which finished every other
  captured style and left zoom, mosaic/wave and random blocks). Porting from
  a reference implementation settles the direction, not independently
  confirmed against genuine RPG_RT under wine: zoom always draws the
  *destination*
  as the full screen and instead shrinks or grows the *source* crop it
  resamples from, so `ZOOM_IN` shrinks the departing scene down to nothing (an
  Erase) and `ZOOM_OUT` grows the arriving scene back out from nothing (a
  Show), both centred on the screen — `Game::Transition` stays pure logic with
  no scene/player access, so it does not follow that reference
  implementation's own hero-position centring on the map. `Scene::Map` snapshots the screen the same way it
  already does for scroll and combine / division, but composites zoom's one
  piece with `Bitmap#stretch_blt` instead of `blt`, since the destination and
  source rects now differ in size. The RPG2003 test-bed's real Erase/Show
  Screen parameters (`scripts/analyze_game.rb --params --code 11010/11020
  data/mtf-meido-action/Debug`) confirm setting 16 is genuine, in-use data.
  Mosaic / wave and random blocks still fall through to the plain fade: mosaic
  and wave want a native per-pixel resample, and random blocks wants RPG_RT's
  incremental per-frame block paint. Covered by new checks in
  `scripts/rpg2k_scene_check.rb` (per-style geometry at the start and end of a
  zoom-in and a zoom-out transition).

- **Erase / Show Screen's scroll and combine / division styles now paint real
  pixels.** They used to run as a plain fade of the right length, the wrong
  texture, on the assumption they needed a screen capture the renderer does not
  have — `RGSS::Graphics.snap_to_bitmap` already exists and is what the RPG
  Maker XP scene uses for its own transitions (see the prior "transition
  blocker correction" note). `Scene::Map` now snapshots the screen once when
  one of these starts and blits the capture back sliding into (or out of)
  place every frame: the four scroll directions paste the whole capture at a
  sliding offset, and vertical / horizontal / cross combine and division split
  it into two (or four, for cross) pieces that slide together or apart.
  `Game::Transition` stays pure logic — it only computes where each piece
  goes (`#capture_ops`); Scene::Map does the actual blitting and disposes the
  snapshot once the transition ends. Cross combine/division's exact quadrant
  motion is this build's own reading (diagonal from each screen corner),
  reasoned from the vertical/horizontal pair rather than confirmed against
  RPG_RT, since neither test bed exercises that specific style. Zoom / mosaic /
  wave and random blocks still fall through to the plain fade: zoom's own
  in/out direction has nothing in either test bed to confirm it against, mosaic
  and wave want a native per-pixel resample, and random blocks wants RPG_RT's
  incremental per-frame block paint. Covered by new checks in
  `scripts/rpg2k_scene_check.rb` (snapshot caching, per-style geometry at the
  start and end of a transition, and the no-snapshot-backend fallback).

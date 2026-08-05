- RPG Maker 2000: the **remaining map / common-event commands** are now
  implemented, closing the RPG2000 event-command set outside battle pages.
  **Change Skills** (10440) teaches or removes a skill on the usual actor scopes
  (constant or variable skill id, id 0 ignored); **Simulated Attack** (10500)
  hurts the target actors with EasyRPG's `atk - def * p_def / 400 - spi *
  p_spi / 800` formula, spread by ±(variance × 5) percent, floored at 0 and
  optionally storing the damage in a variable; **Change Actor Face** (10640)
  overrides an actor's FaceSet; **Enter/Exit Vehicle** (10840) boards or leaves a
  vehicle from an event, reusing the action-button toggle; **Flash Sprite**
  (11320) pulses a character with a decaying colour, drawn by toning its CharSet
  frame (so the flash keeps the sprite's outline) and holding the event when its
  wait flag is set; **Fade Out BGM** (11520) fades the music over the given
  tenths of a second and forgets the current track; **Play Movie** (11560)
  records and reports the request (no video decoder is linked in, so playback is
  the one part not modelled); **Tile Substitution** (11750) rewrites a tile id on
  a map layer through a `Game::Map` substitution table, so drawing *and*
  passability follow the swap until the map is left; and **Open Save Menu**
  (11910) / **Open Main Menu** (11950) hand control to the save and field menus
  and resume the event afterwards. **Conditional Branch** gained its last two
  RPG2000 tests: "the decision key started this event" (type 8, set by
  `Scene::Map` when the action button launches a trigger-0 event) and "the BGM
  has played through once" (type 9, detected from a `RGSS::Audio.bgm_pos` that
  jumped backwards, which is how SDL_mixer loops a track). Covered by new checks
  in `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.

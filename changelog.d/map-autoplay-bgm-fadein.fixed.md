- **A map's own Autoplay BGM (the map-tree node's `bgm` chunk, set on the
  Map Properties dialog in the editor) now honours its `fade_in` field
  instead of silently dropping it.** Cycle #203 threaded the same liblcf
  `BGM`-struct field 2 `fade_in` (`mruby-lcf/mrblib/schema.rb`) through to
  `RGSS::Audio.bgm_play`'s 5th argument for `#battle_bgm`, the inn's
  restore path, and `#vehicle_bgm` (all via `Scene::Map`'s shared
  `#music_fadein` helper and its own `#play_bgm` choke point), but
  `#play_map_bgm` — the helper a reference implementation's own
  map-transfer code calls on the initial map load and every Transfer
  Player (ported from it, not independently confirmed against genuine
  RPG_RT under wine) — was the one call site that cycle missed: it built
  the `{ name:, volume:, tempo: }` hash
  passed to `#play_bgm` without ever reading `#music_fadein(bgm)`, so a
  map's own configured fade-in was always read as 0 and every map entry
  restarted the track at full volume instantly instead of ramping in.
  Fixed by passing `fadein: music_fadein(bgm)` through the same way
  `#battle_bgm`/`#vehicle_bgm` already do. Found by a systematic sweep of
  every call site of `#music_fadein`/`Audio.bgm_play` after cycle #217's
  near-identical miss (`Scene::Title#play_title_bgm`), not by chance
  reading.

- **Battle, Show Inn, boarding a vehicle, the Game Over screen, and a map's
  own Autoplay BGM now honour a configured pan (balance) instead of
  silently dropping it.** The `rpg2k-bgm-pan` cycle wired Play BGM's own
  balance parameter through to `RGSS::Audio.bgm_pan` (`Game::Interpreter
  #play_audio`'s `:bgm` branch), and Play Memorized BGM already does the
  same, but every helper that funnels through `Scene::Map#play_bgm` --
  `#battle_bgm`/`#inn_bgm`/`#vehicle_bgm` (and their restore counterparts)
  and `#play_map_bgm` (the map-tree node's own Autoplay BGM) -- never called
  `bgm_pan` at all, and `Scene::GameOver#play_gameover_bgm` had the same
  gap. This is the same shape of miss cycle #202/#203 already found and
  fixed for `fade_in` on these exact call sites (and cycle #218 found again
  for `#play_map_bgm` specifically), just for the `BGM` struct's field 5
  (`balance`, `mruby-lcf/mrblib/schema.rb`) instead of field 2: `#battle_bgm`
  / `#inn_bgm` / `#vehicle_bgm` read a Change System BGM (10660) override's
  `balance:` and the database's own `battle_music`/`inn_music`/
  `boat_music`/`ship_music`/`airship_music`/`gameover_music` fields for
  every other parameter but never this one, and `Scene::Map#play_bgm` --
  the shared choke point every one of them funnels through, alongside
  `#play_map_bgm`'s own map-tree `bgm` chunk -- never called `RGSS::Audio
  .bgm_pan` at all, so a configured pan on any of those slots left whatever
  balance a prior Play BGM (or the continue-from-save current-BGM record,
  which already round-trips `balance`) had last set. Added a `#music_balance`
  helper alongside the existing `#music_fadein` (both read the same `BGM`
  struct defensively), added `balance:` to every helper's returned hash, and
  `#play_bgm` now re-applies `music[:balance] || 50` to `RGSS::Audio.bgm_pan`
  unconditionally on every call, same-file-or-not, matching Play BGM/Play
  Memorized BGM's own idiom since panning has no per-track state to restart.
  The victory fanfare (`#play_victory_bgm`) is deliberately left alone here:
  it plays through the distinct one-shot `RGSS::Audio.me_play` "ME" channel,
  which (unlike `bgm_play`) has never had a `bgm_pan` call wired to it at
  all, in this build or any prior cycle -- extending pan there would be a
  new claim about RPG_RT's own ME-balance behaviour with no existing
  precedent to extend, out of scope for a fix that only forwards an
  already-plumbed field through mrblib call sites that already handle every
  other field of the same struct.

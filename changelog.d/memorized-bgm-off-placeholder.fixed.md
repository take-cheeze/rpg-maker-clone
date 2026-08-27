- `Game::State#to_lsd` now writes chunk 101 (SAVE_SYSTEM) field 78
  (`stored_bgm`, Memorize BGM's own stash) unconditionally, "(OFF)" when
  nothing has been memorized — the same convention fields 76/77
  (before_vehicle_music/before_battle_music) already follow, not the
  "omit when nil" this field used before. Confirmed against a genuine
  kk1.12 save under wine: field 78 was present even though that session
  never ran Memorize BGM, decoding as a BGM struct whose own `file` read
  the literal "(OFF)". A recent fix to `Game::State.bgm_from_chunk` (treating
  the "(OFF)" placeholder as nil, matching `#play_bgm_or_stop`'s existing
  live-playback fix) exposed this: previously "(OFF)" round-tripped as a
  truthy value by accident, masking that genuine RPG_RT never actually
  omits this field at all.

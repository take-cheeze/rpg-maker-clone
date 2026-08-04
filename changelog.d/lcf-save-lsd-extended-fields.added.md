- The `Save<slot>.lsd` export is now near-parity with the portable `Marshal`
  save. `Game::State#to_lsd` / `from_lsd` gained the fields ADR 0019 had dropped:
  the **message-window configuration** (position / transparency / face,
  SaveSystem 41-54), the **current & memorised BGM** (75 / 78), the
  **player-transparent flag** (55) and the **menu / save / teleport / escape
  access flags** (121-124), plus the leader's on-map **CharSet override** in the
  hero chunk (104). It also now writes the **title chunk (100)** — the OLE
  timestamp, the leader's name / level / current HP and each party member's
  FaceSet — so a real RPG_RT / EasyRPG file-select screen shows the party. The
  timestamp is a `:double`, so the `mruby-lcf` writer gained `LCF.pack_double`
  (a byte-wise IEEE-754 encoder, the inverse of `unpack_double`) and a `:double`
  `encode` branch. The only live-state fields still not in the `.lsd` are the
  game timer (liblcf's SaveSystem has no field for it) and per-actor name/title
  overrides for non-leader members, so the Marshal save stays primary.
  `scripts/rpg2k_save_load_check.rb` now mutates every new field before the
  `state -> to_lsd -> from_lsd` round-trip and asserts each survives, against the
  real Nepheshel (2000) and mtf-meido-action (2003) saves. See ADR 0019.

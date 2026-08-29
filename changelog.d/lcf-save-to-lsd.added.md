- The in-game **Save** now also exports a genuine RPG2000/2003 `Save<slot>.lsd`,
  not just our portable `Marshal` dump. New `Game::State#to_lsd` builds the
  `SAVE_DATA` chunks from live state -- system (101: switches, variables,
  save_count), hero position/facing (104), the per-actor level/exp/equipment/
  skills/HP/MP table (108) and the party roster / gold / item bag (109) -- the
  exact inverse of `Game::State.from_lsd`. `save_game` writes it beside the
  Marshal save (best-effort; a failed export never fails the save), so a slot is
  now readable by real RPG_RT tooling. To build a save from scratch the
  `mruby-lcf` writer gained `LCF.pack_int16` + an `:int16_array` `encode` branch
  (equipment / skills / item ids), `Array2D#[]=` with an empty-table constructor,
  and an empty `File` constructor (`SaveData.new` with no stream). Continue now
  prefers our full-fidelity Marshal save and falls back to a `.lsd` only when
  there is no Marshal save (a foreign editor save dropped in), so the lower
  -fidelity export never shadows a richer save. `scripts/rpg2k_save_load_check.rb`
  proves `state -> to_lsd -> from_lsd` preserves every modelled field against the
  real Nepheshel (2000) and mtf-meido-action (2003) saves. See ADR 0019.

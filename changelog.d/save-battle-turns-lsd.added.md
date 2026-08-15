- **Chunk 109's `turns` field (41, "turns passed in latest battle") now
  round-trips through the `.lsd` too**, the one save-inventory field left
  deliberately undecoded by the step-counter/battle-tallies fix for lack of a
  source value. `Game::Battle` already tracks the fight's own round count
  live (`@rounds`, incremented once per round up to `MAX_ROUNDS`; `#turn`
  simply returns it) — it just never survived past the fight, since
  `Scene::Map#finish_battle` discards the `Battle` object once it hands the
  outcome back to the event. A new `Game::State#last_battle_turns` (nil
  until a battle has ever finished) is now set from
  `@battle_ui[:battle].turn` right there, alongside the existing
  `apply_to_party` call, and persists in both the Marshal save and the
  `.lsd`, the same as `#steps`. `LCF::Schema::SAVE_INVENTORY` decodes field
  41 as a plain undefaulted `:int`, matching its neighbours;
  `Game::State#to_lsd` writes it only when set (so a save taken before any
  battle leaves the field genuinely absent, not a spurious 0) and
  `.from_lsd` restores it. Covered by a new `scripts/rpg2k_logic_check.rb`
  check (a multi-round battle, capturing the round count the way
  `#finish_battle` does, then an in-memory `to_lsd`/`from_lsd` round-trip; a
  legacy save with the field absent keeps the `nil` default) and a new
  `scripts/rpg2k_scene_check.rb` end-to-end check driving a real battle
  through `Scene::Map` to confirm `#finish_battle` performs the capture.

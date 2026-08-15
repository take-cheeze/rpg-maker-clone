- **The step counter and battle win/defeat/escape/victory tallies now
  round-trip through the real `.lsd` export**, not just the portable Marshal
  save. `Game::State#steps`/`#battle_count`/`#win_count`/`#defeat_count`/
  `#escape_count` were already persisted in the Marshal save and already live
  in-game (bumped by `#walk_step` and by `Interpreter`'s battle-result
  handling, both readable via Control Variables selectors 4-7), but chunk 109
  only decoded the two Timer Operation countdowns. Confirmed against
  liblcf's `SaveInventory` struct (every field here is a plain `int32_t`,
  like `gold`): `LCF::Schema::SAVE_INVENTORY` now also decodes
  `battles`(32)/`defeats`(33)/`escapes`(34)/`victories`(35)/`steps`(42),
  undefaulted like the timer fields so an absent field reads back as `nil`
  rather than a concrete zero. `Game::State#to_lsd` writes the five live
  counters into them and `.from_lsd` restores them, leaving a legacy save's
  zeroed `State.new` defaults in place when the fields are absent. Chunk
  109's `turns` field (41, "turns passed in latest battle") stays
  deliberately undecoded — there is no per-battle turn tracker on the Ruby
  side to source it from, and building one is a separate, larger feature.
  Covered by a new `scripts/rpg2k_logic_check.rb` check (a non-zero step
  count and battle tallies both round-trip through an in-memory
  `to_lsd`/`from_lsd`; an old save missing the five fields keeps the default
  zeroed counters).

- **Both Timer Operation countdowns now round-trip through the real `.lsd`
  export**, not just the portable Marshal save. `docs/TODO.md` used to call
  this the one field the `.lsd` "cannot yet carry", guessing it would need "a
  documented chunk id" of its own — it already has one: liblcf's own
  `ChunkSaveInventory` enum documents `timer1_frames`..`timer2_battle` at ids
  0x17-0x1E (23-30), filed under the inventory chunk (109) next to gold, not
  the system chunk (101), with a "value is seconds\*60+59" doc comment that
  matches `Game::Timer#set`'s own encoding exactly. `LCF::Schema::SAVE_INVENTORY`
  now decodes the eight fields (no `default:`, so an absent field reads back as
  nil rather than a false zero, distinguishing "not in this save" from
  "explicitly stopped"), `Game::State#to_lsd` writes both `Game::Timer`s into
  them and `.from_lsd` restores them, leaving a legacy save's fresh
  `Timer.new` defaults untouched when the fields are absent. Covered by a new
  `scripts/rpg2k_logic_check.rb` check (both timers round-trip independently
  through an in-memory `to_lsd`/`from_lsd`; an old save missing the eight
  fields keeps the default stopped/hidden timers), confirmed to fail against
  the pre-fix code (the first timer read back at 0 seconds) before the fix.

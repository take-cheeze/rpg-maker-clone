- **`Game::State.from_lsd` no longer crashes loading a genuine save whose**
  **chunk 113/114 execution state this codebase's own schema cannot decode.**
  Found by generating a real `Save01.lsd` for kk1.12 (`scripts/gen-lcf-save-wine.bash`,
  EasyRPG Player's F9 debug-menu Save under wine) and running it through
  `scripts/rpg2k_save_load_check.rb`: its chunk 113 `stack` field is a single
  `0x01` byte, which `Array2D#initialize` reads as "1 row" and then has
  nothing left to read that row's own id from, raising a `RuntimeError:
  truncated BER integer` that used to abort the whole load. Cycle #191's own
  schema.rb comment already flagged this exact risk ("not confirmed against
  a genuine multi-frame capture, since none was available"); a malformed
  capture now degrades to "nothing to restore" the same way an absent chunk
  already does, logging an `[RPG2k]` diagnostic instead of crashing Continue
  outright.
- **`Game::State#to_lsd` writes chunk 100 (the file-select title/preview**
  **data) even for a party with no leader at all.** The same kk1.12 capture
  surfaced a second real, reachable gap: kk1.12's own genuine starting state
  is an *entirely empty party* (all five members join later through Change
  Party Member events), and `#to_lsd` used to skip chunk 100 outright
  whenever there was no leader to name it after — not merely writing a zero
  timestamp, which is the exact failure ADR 0021 already fixed for a
  *populated* party (a zero OLE date reads as an empty file slot and
  Continue silently refuses it). A missing chunk risked the identical
  outcome for an empty-party save. The timestamp is now written
  unconditionally; only the leader-specific name/level/hp fields, which have
  nothing to read from an empty party, stay conditional.
  `scripts/rpg2k_save_load_check.rb`'s own leader-dependent assertions
  (already guarded everywhere else in the file) are guarded the same way at
  the two spots that were not. Both fixes covered by new
  `scripts/rpg2k_logic_check.rb` checks, confirmed to fail against the
  pre-fix code before the fix.

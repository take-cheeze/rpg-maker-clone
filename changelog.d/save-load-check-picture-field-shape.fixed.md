- **Tests:** closed the last of `scripts/rpg2k_save_load_check.rb`'s
  long-standing "known pre-existing failures" -- a Show Picture round-trip
  check whose expected hash predated the `show_x`/`show_y`/`fixed_to_map`/
  `use_transparent_color` fields `Game::State.restore_pictures` has actually
  passed through for many cycles now. The runtime was already correct; only
  the test's own fixture had drifted from it (the same root cause already
  diagnosed and fixed for two sibling BGM assertions in this same file).
  The check now also sets fields 2/3/6/9 in its synthetic save entry to
  values distinct from the neighbouring finish_x/finish_y fields, so it
  actually exercises this round-trip instead of merely matching whatever
  the code happens to default to. `rpg2k_save_load_check.rb` now reports
  zero known failures, down from one.

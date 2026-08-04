- The RPG2000 renderer can now be diffed against the genuine `RPG_RT.exe` on an
  actual **game map**, not just the title screen.
  `scripts/compare-nepheshel-save-wine.bash` resumes both runtimes from the same
  `Save<N>.lsd` — ours through a new `--rpg2k_continue` (the headless title
  auto-select of `--rpg2k_new_game`, pointed at Continue), RPG_RT through a
  fixed three-key sequence — so they cannot drift apart the way the previous
  harness did through Nepheshel's timed opening.
  `scripts/gen-rpg2k-save.rb` moves the party in that save to any map, and
  Continue now logs the `[RPG2k-MAP]` marker the New Game path already did.
  It found two gaps straight away, both recorded in `docs/TODO.md` and the
  ADR 0021 addendum: shown pictures are not restored on load (blocked on
  `SAVE_PICTURE` modelling no position fields), and `Game::State#to_lsd`'s own
  output — five chunks against a real save's sixteen — is refused by RPG_RT,
  which is why the harness edits a genuine save rather than writing one.

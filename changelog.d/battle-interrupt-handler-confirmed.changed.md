- **Battle Interrupt (Terminate Battle, 13410) matching neither the
  enclosing Enemy Encounter's [Victory] nor [Escape]/[Defeat] handler, and
  leaving the win/escape/defeat tallies alone, is confirmed rather than an
  open yado.tk claim.** `Game::Interpreter#resume_battle` and
  `#find_battle_option`'s `BATTLE_HANDLERS` table already have no `:abort`
  case, so a Terminate Battle resumes the event right after Branch End with
  none of the three outcome counters touched. No game-logic change was
  needed — but the existing `scripts/rpg2k_scene_check.rb` coverage that
  looked like it proved this turned out to be vacuous: its loop broke the
  instant `@battle_ui` read `nil`, which is true before the battle opens as
  well as after it closes, so the check "passed" without the battle event
  ever running (confirmed by replaying it against an injected counter bug
  and watching it stay green). Replaced with a new `open_then_close_battle`
  helper that asserts the battle actually opens before waiting for it to
  close, plus a new check asserting the counters directly — both confirmed
  to fail against the bug the old check missed.

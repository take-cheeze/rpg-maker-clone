- **A state 10+ priority below the current highest is now auto-removed the
  instant a new one lands.** yado.tk: multiple active states all still apply
  mechanically (a hidden poison keeps ticking under a displayed confusion),
  but RPG_RT crowds out anything trailing the top priority by that much —
  either the new state pushes an existing low-priority one out, or an
  existing high-priority one pushes the new arrival right back out.
  `Game::States.prune` implements the rule (death exempt on both sides, same
  as the existing display-priority logic in `Game::States.significant`) and
  is now called from every state-infliction path: `Game::Actor#add_state`'s
  callers (the Change Condition event command, field skill casting) via a new
  `Game::Party#state_table` accessor, and `Game::Battle#roll_inflict` for
  battle. Covered by new `scripts/rpg2k_logic_check.rb` checks, confirmed to
  fail against the pre-fix code before the fix.

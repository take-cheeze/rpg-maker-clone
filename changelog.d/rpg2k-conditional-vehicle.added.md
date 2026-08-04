- RPG Maker 2000: the **Conditional Branch** command now evaluates the **vehicle**
  condition (type 7) — true when the party is riding the boat, ship, or airship
  (`param1` 0 / 1 / 2), checked against `Game::State#boarded`. Previously every
  condition type past the actor checks (6 and up) fell through to an unconditional
  "true", so a "if the hero is on the airship" branch always ran; it now branches
  correctly. Covered by a new `scripts/rpg2k_logic_check.rb` check (riding the
  ship takes the branch, asking about a different vehicle or being on foot takes
  the else). The event-facing condition (type 6) remains a follow-up.

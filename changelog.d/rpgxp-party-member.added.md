- RPG Maker **XP** *Change Party Member* (129) event command plus the party-
  related conditional and variable sources. The interpreter adds or removes an
  actor from `Game::State#party` (no duplicates, removals delete the id), the
  Conditional Branch **actor "is in the party"** test (type 4, sub-type 0) is
  evaluated, and Control Variables can read the **"other" game quantities**
  (operand type 7) — map id, party member count and gold. Covered by new
  `mruby-rpgxp/test` cases (add/remove/duplicate party changes, the in-party
  conditional, and the game-quantity operands).

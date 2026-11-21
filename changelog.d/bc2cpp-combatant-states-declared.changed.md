- The closed bc2cpp build trusts declared instance variables that an
  `attr_accessor` writes, because their synthesized writer now checks the
  declaration as well. `Combatant#@states` is declared `Array?`. Together
  these remove 19 by-name owner calls (1350 -> 1331).

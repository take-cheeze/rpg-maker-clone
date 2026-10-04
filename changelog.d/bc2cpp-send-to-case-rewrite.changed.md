- **bc2cpp** rewriting the closed world's 8 remaining computed `send` sites as `case` arms was measured and not
  shipped (ADR 0339). The lint and the name sets were fine -- every one of the 8 names is a literal the program spells --
  but the rewrite makes the generated C++ worse: 4,412 -> 4,482 `bc2cpp_send` sites, +70. Each `case` arm compiles to its
  own by-name `:===` on the Symbol, a by-name `respond_to?` and a by-name `!`, so `Game::Battle.singleton#flag_of` went
  from 2 by-name lines to 35. Removing a computed `send` does not remove the dynamic dispatch, it changes which name is
  computed: the receivers are parameters, whose class the closed world cannot prove (ADR 0331), so the arms pay for a
  receiver check the one `send` they replaced made once. `Dynamic/Send` stays at 8 and the lint baseline at 16.

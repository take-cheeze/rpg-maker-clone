- **bc2cpp**: the NoMethodError / nil-receiver / guard-violation arms of the
  compiled engine are noreturn calls, and a nil arm no longer passes its
  receiver, which cuts the Wio Terminal firmware by about 51 KB. A nil
  receiver of an inlined `inject(init)` now raises with the same
  `NoMethodError#args` as the interpreter.

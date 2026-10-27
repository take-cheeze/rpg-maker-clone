- **bc2cpp**: the numeric flow now models a method whose `while` loop ends in `break`/`next` (OP_JMPUW) when the
  method has no `rescue`/`ensure`, where the VM runs that jump as a plain jump
  ([JMPUW_PLAIN](docs/bc2cpp-numeric-jmpuw.md)). Such a method used to be unmodelled, which failed every ivar it
  writes for the whole program. In optcarrot this covered the resumable `PPU#main_loop`. A core-body compile
  no longer memoizes its closed-world-less constant and nil-operator answers, which had hidden every constant
  proof once such a method was modelled. `BC2CPP_NUMERIC_JMPUW=0` restores the old flow; check
  `scripts/bc2cpp/numeric_jmpuw_check.rb`.

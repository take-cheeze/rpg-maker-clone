- **bc2cpp**: psp, wio and maix builds (single-format, RPG2000/2003 only) now
  generate in a checked closed-world mode. The build fails if its real gem
  list could load or define Ruby at runtime. A class guard that can only be
  true is dropped, and a guard chain proven to list every class that answers
  a name ends in a shared `bc2cpp_nomethod`. It raises the same
  `NoMethodError` the dispatch did. On wio the RPG2k compiled gem is 2.3%
  smaller at `-Os`: 1,741 dispatch fallbacks are gone. Desktop output is
  unchanged. See ADR 0210.

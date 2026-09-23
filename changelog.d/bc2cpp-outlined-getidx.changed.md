- **bc2cpp**: an untyped `x[i]`, `x[0]` or `x[i] = v` in generated code now
  calls one file-scope helper (`bc2cpp_getidx`, `bc2cpp_getidx0` or
  `bc2cpp_setidx`) instead of repeating the Array/Hash/String fast paths and
  the `#[]` dispatch chain at every site. The RPG2k compiled gem is 15.9%
  smaller at `-Os` (21.8% with LCF bracket field access), with no behaviour
  change. See ADR 0216.

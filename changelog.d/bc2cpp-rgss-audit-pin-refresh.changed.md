- The closed bc2cpp build trusts its audit of the RGSS native code again.
  The audit had switched itself off after a Wio-only stub change in
  `mruby-rgss/src/lib.cxx` (that change touches no instance variables).
  Removes 5 owner calls (1329 -> 1324).

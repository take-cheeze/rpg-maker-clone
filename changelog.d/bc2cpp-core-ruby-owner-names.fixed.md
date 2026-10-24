- **bc2cpp: owner calls name the core Ruby definitions the registry never
  lists.** An alias of a native-named core method (`IO#each_line`,
  `IO#to_i`) and a core method the compile refuses
  (`Enumerator#each_with_index`) were missing from the owner set, so after
  the owner-call else fix a `File#each_line` in the closed build raised
  `BC2cppGuardViolation`; `RPG2k#read_ini_title` then fell back to the folder
  name instead of `RPG_RT.ini`'s `GameTitle`. The set now also scans the
  program's own core Ruby. Covered by
  `scripts/bc2cpp/block_iterator_direct_check.rb`.

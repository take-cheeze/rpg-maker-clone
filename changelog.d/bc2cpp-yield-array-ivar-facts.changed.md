- The Fiber yield analysis proves that an instance variable's reads hold no Proc when every write stores a literal, an
  `Array#*` result on an array literal, or another such variable. `@ram[i]` in optcarrot's CPU no longer counts as a
  possible Proc call. Writes made by name at run time (`instance_variable_set`) are assumed non-Proc only at the sites in
  `scripts/bc2cpp/dynamic_ivar_writes_whitelist.txt`; any other such site disables the fact.

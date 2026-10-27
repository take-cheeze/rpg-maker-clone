- **bc2cpp owner calls accept the singleton method of a constant that holds an
  object.** With `LIST = []; def LIST.find_all ... end`, a compiled
  `list.find_all { }` on LIST raised `closed-world owner violation: Array#find_all
  resolves to a definer the closed world does not list`. The owner test only
  knew singleton classes of classes and modules. It now compares a listed
  `Const.singleton` with the object the constant holds
  (`docs/bc2cpp-core-definers.md`, `scripts/bc2cpp/core_definer_mono_check.rb`).

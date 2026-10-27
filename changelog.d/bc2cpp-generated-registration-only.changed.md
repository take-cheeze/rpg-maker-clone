- **bc2cpp registers every compiled method from generated code.** The
  compiled gems' `src/register.cxx` files no longer list methods by hand.
  They call the generated `bc2cpp_gem_init` and `bc2cpp_gem_final`, which
  register every owner a gem compiles and set up the direct-construct class
  accessors. Five compiled entries no hand line registered
  (`Game::Battle::Combatant#initialize` and four `LCF` methods) now run
  compiled instead of as bytecode, and `RPG2k::Scene::Map#vehicle_charset_index`
  is private as its Ruby source says. The registration proof now counts
  `bc2cpp_define_private_class_method` as a registration, and proves the open
  list against the open build's registrations. The closed list grows from
  2315 to 2356 names. `prune_static_dispatch_registrations.rb` is gone, and
  `static_dispatch_scan_check.rb` fails if a `register.cxx` defines a method.

- **bc2cpp**: the closed build now really leaves its closed-list methods out of the method tables. Hand-written
  `register.cxx` lines registered 847 of them anyway (840 in rpg2k, 7 in lcf), because only the generated
  registration read the closed list, and in verify mode they overwrote the abort stub with the real method.
  - Each such line is now wrapped in `#ifndef BC2CPP_UNREGISTERED_<entry>`. The generated code defines the macro
    for every entry the build's list leaves out. `scripts/bc2cpp/prune_static_dispatch_registrations.rb --closed`
    writes the guards; `--closed --check` (run by `static_dispatch_scan_check.rb`) fails when they drift.
  - The prune script now spells entry symbols as the generator does (`$3f` for `?` and the like), so predicate,
    setter and operator names are matched too.
  - The closed list may now also take RGSS owners and the engine modules' own singletons (`Game.singleton`):
    RPG2000/2003 games carry no Ruby, so nothing in the closed build calls an RGSS method by name from a script.

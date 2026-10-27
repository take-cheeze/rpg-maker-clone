- **The optcarrot benchmark probe runs again.** Its compiled binary stopped
  with `uninitialized constant Optcarrot (NameError)` once the generated
  `bc2cpp_register_owner_methods` registered every compiled owner: the probe
  calls it from `OptcarrotProbe.install_prelude!`, before the Optcarrot classes
  exist. The generated registration now has a core half
  (`bc2cpp_register_core_owner_methods`) and a program half
  (`bc2cpp_register_program_owner_methods`). The probe installs the core half
  in its prelude and the program half from `install!`. The engine gems still
  register both through `bc2cpp_gem_init`. The new
  `scripts/bc2cpp/registration_split_check.rb` in the `bc2cpp-build` job runs a
  fixture in the bundle's order and fails on this regression.

- MZ (M6.2): `MZ.runnable_scripts` now uses `Array#-` from the core
  `mruby-array-ext` gem — declared as a proper `add_dependency` in
  `mruby-mvjs/mrbgem.rake` — instead of the `reject`/`include?` workaround. The
  earlier `undefined method '-' for Array` in CI came from the gem's own test
  build not pulling in `mruby-array-ext`; declaring the dependency fixes that at
  the source. AGENTS.md now documents the rule: depend on the core `*-ext`
  mrbgem that provides a stdlib method rather than hand-rolling around it.

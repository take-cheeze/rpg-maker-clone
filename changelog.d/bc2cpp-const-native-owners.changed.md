- **bc2cpp**: the constant binding cache also covers names that a native source defines as a class or module at a
  path it can name (`Window`, `Audio`, `Profiler` under RGSS), and `Scope::NAME` reads inside a `begin`/`rescue`
  range. Reads in rpg2k that still run the full lookup fell from 210 to 46 scope walks and from 196 to 7 scoped
  lookups. A `Scope::NAME` read in an inlined body now asks the dataflow about its unshifted receiver register.
  See `docs/bc2cpp-constant-lookup.md`.

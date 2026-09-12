- **bc2cpp gains `Game.singleton` coverage** — `def self.x` methods defined
  directly on the `Game` module itself (`mruby-rpg2k/mrblib/game.rb`), never
  `class << self`-wrapped: `#clamp`, `#round_half_even`, `#trans_to_opacity`,
  `#opacity_to_trans`, and `#camera_offset`. All 5 were already real,
  registry-visible entries since the original `.singleton` SDEF fix, but no
  `owners:` list had ever actually named `Game.singleton` until now, so none
  of their bodies had been emitted. Four are MONO by name and now
  devirtualize every already-compiled call site that references them
  (`Game::Interpreter`, `Game::Screen`, `Game::State`, and others) straight
  into a direct C++ call instead of falling back to `mrb_funcall` — a real,
  additive optimization to already-shipped code, not just new code of its
  own.
- **Fixed a real stale-rebuild gap in the CMake/mruby build integration**:
  `tools/bc2cpp/bc2cpp.rb` and `tools/bc2cpp/compiled_gems.rb` live outside
  every mrbgem directory, so neither was ever a member of the dependency
  list that triggers a `libmruby.a` rebuild — editing either file and
  re-running a plain `cmake --build` (no reconfigure) silently kept linking
  the previous, now-stale generated compiled-gem code, with `ctest` still
  reporting green against code that was never actually regenerated. Fixed
  by tracking `tools/bc2cpp/*.rb` as a real rebuild dependency
  (`cmake/build-mruby.cmake`), and by adding the three opt-in
  `RPGMAKER_BC2CPP=1`-only compiled gems' own directories to both
  `CMakeLists.txt`'s and `app/psp/CMakeLists.txt`'s dependency-tracked
  `GEMS` list so their own `src/register.cxx` edits are tracked too.

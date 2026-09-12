- `tools/bc2cpp/bc2cpp.rb`'s `DIRECT_CONSTRUCT_TARGETS` devirtualization
  (`SomeClass.new` compiled straight to `bc2cpp_direct_alloc` +
  `#initialize`'s own compiled body, skipping `Class#new`'s ordinary
  allocate+initialize dispatch) never fired for a bare, lexically-scoped
  `.new` receiver (e.g. `Switches.new` written inside `module Game`'s own
  namespace, really meaning `Game::Switches`) -- `trace_new_target`'s own
  `GETCONST` case only ever captured the literal bare token, which could
  never equal a fully-qualified table entry, a real, previously-flagged
  gap (`Game::Screen`'s own long-documented miss). Fixed: `trace_new_target`
  now resolves a bare single-token receiver through its enclosing method's
  own real lexical nesting chain, innermost scope first (mirroring real
  Ruby's `Module.nesting` search order and this file's own `GETCONST`
  runtime codegen) -- but only ever as far as an exact, already-vetted
  `DIRECT_CONSTRUCT_TARGETS` entry, never a general namespace guess, so a
  bare name that doesn't resolve this way still safely misses exactly as
  before. `Game::Switches`, `Game::Timer` and `Game::MessageConfig` (all
  three referenced bare inside `Game::State#initialize`,
  `mruby-rpg2k/mrblib/game.rb`) join the table as a result. Verified a true
  no-op for whole-program registry building (byte-identical
  `wio_registered_methods.rb` output across all three `*-compiled` gems)
  and confirmed for real against the regenerated `rpg2k_compiled_gen.cpp`,
  which now devirtualizes all four real call sites.

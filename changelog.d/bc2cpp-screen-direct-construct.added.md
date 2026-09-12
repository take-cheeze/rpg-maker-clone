- `tools/bc2cpp/bc2cpp.rb`'s `DIRECT_CONSTRUCT_TARGETS` table (`SomeClass.new`
  compiled straight to `bc2cpp_direct_alloc` + `#initialize`'s own compiled
  body, skipping `Class#new`'s ordinary allocate+initialize dispatch,
  runtime-guarded by a real `mrb_class_ptr(recv) == <owner>_compiled_class()`
  check falling back to `mrb_funcall` otherwise) gains `Game::Screen`, the
  last of the four bare-reference-gap classes the previous round's own
  `trace_new_target` GETCONST fix already proved unlockable but left off its
  own table. Independently re-verified against the real 4-part soundness bar
  rather than just trusted: zero `def self.new`/`self.allocate`/`class <<
  self` anywhere on `Game::Screen` (confirmed both by source grep and by a
  real whole-program `wio_registered_methods.rb` registry dump showing no
  `Game::Screen.singleton` entry at all); `#initialize` is 0-arg, already
  compiles clean, and matches its one real call site's own `n=0`
  (`@screen = Screen.new`, `Game::State#initialize`,
  `mruby-rpg2k/mrblib/game.rb`); and `Game::Screen` is a real, unambiguous
  single entry in `mruby-rpg2k-compiled`'s own `owners:` list, already a
  `NATIVE_ARG_TARGETS` owner for several of its OTHER methods (never
  `#initialize`), confirmed not to interact with this table at all. A full
  `wio_registered_methods.rb` TSV dump for all three `*-compiled` gems is
  byte-for-byte identical before and after. The real regenerated
  `rpg2k_compiled_gen.cpp` now devirtualizes the call site into the same
  guarded shape as every sibling entry, diffing only a new
  `Game__Screen_compiled_class` forward declaration plus this one call site.

  `mruby-rpg2k-compiled/src/register.cxx` gains the matching hand-written
  accessor plumbing this mechanism requires per owner (a durable `RClass*`
  global, the `Game__Screen_compiled_class()` definition, a gem-init capture
  right after `Game::Screen`'s own `RClass*` lookup, and a gem-final reset) --
  the same pattern `Game::Transition`/`Game::Map` already had. Verified by
  actually compiling `register.cxx` (`g++ -c`, real mruby headers, all three
  gems' generated output and cross-gem decls headers) and checking the
  resulting object file's symbol table: `Game__Screen_compiled_class` now
  resolves, alongside `Game__Transition_compiled_class`/
  `Game__Map_compiled_class`.

  That same real compile surfaced a pre-existing gap unrelated to this
  change: `Game::Switches`/`Game::Timer`/`Game::MessageConfig`, added to
  `DIRECT_CONSTRUCT_TARGETS` by the prior bare-reference-fix round, never
  got this same `register.cxx` accessor wiring -- `Game__Switches_
  compiled_class`/`Game__Timer_compiled_class`/`Game__MessageConfig_
  compiled_class` are still genuinely undefined symbols in the real object
  file today (confirmed directly via `nm`, with and without this round's own
  changes -- the gap predates and is independent of this round). A real
  `RPGMAKER_BC2CPP=1` build would fail to link over it; the SKIP_UNSUPPORTED
  text-generation and TSV-diff verification that round's own writeup relied
  on never compiles or links this file, so it never caught this. Left
  unfixed here (out of this round's own scope -- it only ever targeted
  `Game::Screen`) but flagged both in `register.cxx`'s own comment and here
  for a dedicated follow-up: add the same three-line pattern this round adds
  for `Game::Screen` for each of those three owners.

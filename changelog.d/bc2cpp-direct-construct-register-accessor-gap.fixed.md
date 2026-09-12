- `mruby-rpg2k-compiled/src/register.cxx` was missing the hand-written
  `DIRECT_CONSTRUCT_TARGETS` accessor plumbing (a durable `RClass*` global,
  the `Game__<Owner>_compiled_class()` definition, a gem-init capture, and a
  gem-final reset) for `Game::Switches`/`Game::Timer`/`Game::MessageConfig` --
  added to `tools/bc2cpp/bc2cpp.rb`'s `DIRECT_CONSTRUCT_TARGETS` table by an
  earlier round (the `trace_new_target` bare-reference fix) alongside this
  same round's own `Game::Screen` addition, but never mirrored into this file.
  `Game__Switches_compiled_class`/`Game__Timer_compiled_class`/
  `Game__MessageConfig_compiled_class` were genuinely undefined symbols: the
  generated code's own guarded direct-construct call sites reference them
  (confirmed by regenerating `rpg2k_compiled_gen.cpp` for real from this
  round's owner list), so a real `RPGMAKER_BC2CPP=1` build would fail to
  link. Neither the registry-level (`wio_registered_methods.rb` TSV) nor the
  generated-`.cpp`-text-level verification every prior round in this series
  relied on ever actually compiles or links `register.cxx`, so the gap
  shipped unnoticed until this round's own real `g++ -c` compile of the file
  surfaced it.

  Fixed by adding the exact same three-line pattern `Game::Transition`/
  `Game::Map`/`Game::Screen` already use for each of the three owners:
  a `g_direct_construct_game_<owner>_class` global, a
  `Game__<Owner>_compiled_class()` definition returning it, a capture
  assignment right after each owner's own `RClass*` lookup in
  `mrb_mruby_rpg2k_compiled_gem_init`, and a reset to `nullptr` in
  `mrb_mruby_rpg2k_compiled_gem_final`.

  Verified independently of the round that found the gap: regenerated all
  three `*-compiled` gems' own `_gen.cpp`/`_decls.h` output from scratch
  (`bc2cpp.rb`, real owner lists from `compiled_gems.rb`), compiled all three
  gems' `register.cxx` with real mruby headers (`g++ -std=gnu++17 -c`), and
  inspected the resulting object files' symbol tables with `nm -C`: before
  this fix, `Game__Switches_compiled_class`/`Game__Timer_compiled_class`/
  `Game__MessageConfig_compiled_class` show as undefined (`U`) references in
  `mruby-rpg2k-compiled.o` with no definition anywhere across all three
  gems' object files; after this fix, all six `Game__*_compiled_class`
  accessors (`Transition`/`Map`/`Screen`/`Switches`/`Timer`/`MessageConfig`)
  resolve to exactly one defined (`T`) symbol each, none left undefined, and
  a `-Wall -Wextra` recompile of `register.cxx` produces zero warnings
  attributable to the new lines.

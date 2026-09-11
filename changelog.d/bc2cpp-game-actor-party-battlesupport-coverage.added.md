- Verified the opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler's coverage of
  `mruby-rpg2k/mrblib/game/battle_support.rb`'s own **separate**
  reopening of `Game::Actor` and `Game::Party` (distinct from
  `mruby-rpg2k/mrblib/game.rb`'s own main class bodies for each, already
  covered) against the real diagnostic, and found it was already
  complete: every one of the 9 (`Game::Actor`) + 16 (`Game::Party`)
  methods this reopening defines that this compiler can actually compile
  was already registered in `mruby-rpg2k-compiled/src/register.cxx`, and
  the whole-program `== compiled entry points ==` listing's real
  `Game::Actor#...`/`Game::Party#...` counts (74/85) match
  `register.cxx`'s own registration counts exactly. Zero methods gained
  or lost registration.

  What this round found and fixed were two real, confirmed documentation
  gaps: `register.cxx`'s own comment said `Game::Actor`'s reopening
  defined only "the 9 methods" it registers, without ever naming or
  explaining the other 4 real methods it also defines and correctly
  leaves interpreted (`#states=`, `#prevents_critical?`,
  `#state_resist_mul`, `#physical_evasion_up?` -- each ends in a genuine
  Ruby block, confirmed against its own real `#error unhandled opcode
  BLOCK`/`SENDB` marker); and that same file's `Game::Party` comment
  mistakenly filed `#stat_mode` under "the battle_support.rb reopening's
  own" block-using methods, when it is actually `Game::Party#stat_mode`
  in `game.rb`'s own main class body, unrelated to this reopening (it
  does independently stay interpreted for the same real BLOCK/SENDB
  reason, just misattributed). Both comments are corrected in place;
  `tools/bc2cpp/compiled_gems.rb` gains a new paragraph documenting the
  full re-check.

  Re-ran the real `bc2cpp.rb` diagnostic end to end (a real host `mrbc`
  built fresh for this check) with the exact `ONLY_OWNERS`/
  `OTHER_OWNERS`/`OTHER_DECLS_HEADER`/`NATIVE_SRCS` every compiled gem's
  own `mrbgem.rake` computes, then compiled the real, edited
  `register.cxx` with `g++ -std=c++17 -c` (a real object file, not just
  `-fsyntax-only`) against all three gems' real generated output -- zero
  errors. `nm -C` on that object confirms exactly 74 `Game__Actor_..._impl`
  / 85 `Game__Party_..._impl` symbols and their matching registered
  wrapper symbols, and confirms zero wrapper symbols exist for the 4
  correctly-unregistered `Game::Actor` methods. Grepped every regenerated
  file for the project's empty-method-name bug shape
  (`mrb_funcall(M, <reg>, "", `): zero matches. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up for the
  full writeup.

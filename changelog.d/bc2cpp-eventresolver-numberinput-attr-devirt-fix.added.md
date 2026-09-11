- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 2 of
  `RPG2k::Scene::EventResolver`'s own 3 real bytecode methods (the small
  helper that resolves a Call Event's own command list) and 6 of
  `Game::NumberInput`'s own 7 (the digit-cursor input model backing the
  Input Number event command). Both added to `mruby-rpg2k-compiled`,
  neither needing any new opcode work.

  Verifying this round's own dedicated bug-hunt pass (run in parallel with
  the coverage work) found and fixed a real, live, already-shipped bug:
  `attr_reader`/`attr_writer`/`attr_accessor`-installed methods were
  invisible to the whole-program MONO/POLY devirtualization registry's own
  bytecode-only scan, the same blind spot a prior round's follow-up had
  already found for a *different* piece of this compiler
  (`extract_native_method_names`) but had not checked here. Confirmed live
  in two already-shipped compiled methods, not just one: `Game::Battle
  #critical?(b)` devirtualized `b.crit_chance` straight into
  `Game::Actor`'s own bytecode-defined `#crit_chance` even when `b` is
  actually a `Game::Enemy` (whose own `#crit_chance` is an
  invisible-to-the-old-scan `attr_reader`) -- a real `NoMethodError` on
  every enemy attack's own critical-hit roll; and `Game::Party
  #apply_actor_meta` devirtualized `actor.transparent = ...` straight into
  `RPG2k::Window`'s own bytecode-defined `#transparent=` even though
  `actor` here is always a `Game::Actor` (whose own `#transparent` is the
  same kind of invisible `attr_accessor`) -- unconditionally broken, not
  merely a risk gated on which subclass reaches the call site, meaning
  restoring actor metadata from a save file carrying a transparency
  override was unconditionally broken under `RPGMAKER_BC2CPP=1` before
  this landed. Both in a build that compiled and linked clean with zero
  warnings. Fixed by registering each `attr_reader`/`writer`/`accessor`
  name as a real registry entry, turning each unsound MONO
  devirtualization into a correctly cautious POLY dynamic dispatch;
  verified against the real generated code before and after for both. The
  same fix additionally closes, for free, 13 further whole-program name
  collisions confirmed to have zero live effect today. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.

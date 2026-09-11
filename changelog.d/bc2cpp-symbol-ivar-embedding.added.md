- `tools/bc2cpp/bc2cpp.rb`'s ivar-embedding analysis (`IvarLayout`) can
  now embed a Symbol-typed ivar (`@tag = :ok`) as a real `mrb_sym` struct
  field, not just Fixnum -- confirmed sound first: mruby's own `mrb_sym`
  is a plain `uint32_t`, and the interned symbol table
  (`3rd/mruby/src/symbol.c`) is only ever freed in bulk at `mrb_close`,
  never per-symbol during an ordinary GC sweep, so a raw `mrb_sym` field
  needs no GC-reachability keep-alive any more than the existing
  `mrb_int` embedding does. `GETIV`/`SETIV` codegen, previously
  hardcoded to Fixnum's own box/check/unbox calls, now goes through a
  small per-type table shared by both. `ArgTypes` (reuses the same trace)
  now reports real Symbol-typed call-site arguments for free too.
  Verified via a real built-and-run toy case (embedded Symbol round-trips
  correctly) and both already-shipped compiled targets (byte-identical,
  zero regression). Real whole-program payoff: 174 -> 184 EMBED lines,
  ten real UI-state mode/focus ivars across `RPG2k::Scene::*` classes not
  in either shipped compiled gem's target set yet. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.

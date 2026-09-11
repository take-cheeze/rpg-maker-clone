- Fixed a real, previously-undocumented registry-soundness gap in the
  opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler (`tools/bc2cpp/bc2cpp.rb`):
  `build_registry`'s bytecode walk recognized `private`/`protected`/
  `public` and `attr_reader`/`attr_writer`/`attr_accessor` sends as ways
  a class installs a method, but not `module_function :a, :b, ...` -- a
  fourth, distinct "invisible to a plain `TDEF`/`DEF` bytecode walk"
  installation mechanism (a bare `SEND`, like `attr_reader`, not a
  dedicated opcode). Real, live use in this closed world:
  `mruby-lcf/mrblib/lcf.rb`'s own `module_function :read_ber, :write_ber,
  :to_rb, ..., :elements_of` and `module_function :var_max, :var_min,
  ..., :exp_default`. Read `3rd/mruby/src/class.c`'s own
  `mrb_mod_module_function` directly rather than assumed from CRuby's
  (different) behavior: unlike CRuby, mruby's own implementation does
  NOT privatize the original instance method (that step is commented-out
  dead code) -- it only installs a copy of each named method, marked
  public, onto the module's own singleton class (e.g. `LCF.write_ber`,
  called from `LCF::File#to_lcf` and lazy schema defaults) -- a real,
  distinct method definition this registry never modeled at all. Fixed
  by registering a synthetic `MethodDef` (`irep: nil`) for each name
  under the same `"Owner.singleton"` pseudo-owner `SDEF`/`SCLASS` already
  use, so a same-named real instance `def` on some *other* class
  correctly counts this as a second definition and flips an unsound MONO
  to a correctly cautious POLY, never the reverse. Confirmed not
  currently exploitable: "LCF" (the bare module) is never itself a
  compiled owner in any of the three real gems, so `compile_send`'s own
  owner-not-emitted guard already fell back to ordinary dynamic dispatch
  for every real `module_function`-installed call site regardless --
  confirmed by a real, full closed-world regeneration of all three
  compiled gems' output, byte-identical before/after this fix. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up
  (adversarial bug-hunt sweep, round 27) for the full writeup.

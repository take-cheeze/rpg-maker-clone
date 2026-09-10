- `tools/bc2cpp/bc2cpp.rb` now supports a magic-comment argument-type
  annotation, `# bc2cpp: (T1, T2, ...) -> T3` on the line directly above a
  `def`, closing the one real gap `ArgTypes`' own call-site inference
  documented as structurally unreachable: `#initialize`'s own arguments
  (`X.new(args)` always compiles to `SEND :new`, never `SEND :initialize`).
  Invisible to `mrbc` (a plain comment, stripped before any bytecode
  exists), so it has zero effect on the interpreted path the same way
  every other bc2cpp feature does; a wrong annotation can't silently
  corrupt anything either, since the existing embedded-ivar write guard
  (`mrb_integer_p` + `mrb_raise`) already applies regardless of how the
  type was established. Also adds a diagnostic-only candidate report:
  running against the real `mruby-rpg2k`+`mruby-lcf`+`mruby-rgss` closed
  world found 37 real argument positions only annotation could ever
  unlock (21 of them in `mruby-rpg2k` itself), though a spot check shows
  most aren't actually Fixnum-typed (the only type this compiler models)
  so wouldn't benefit from one regardless. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up for the
  full detail, including why a real Ruby-syntax annotation (vs. a
  comment) was rejected and what automatic annotation would actually
  need.

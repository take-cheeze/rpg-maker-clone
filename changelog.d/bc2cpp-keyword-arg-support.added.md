- `tools/bc2cpp/bc2cpp.rb` now compiles methods with keyword arguments
  (`def foo(a, b: 1, c:)`, both required and optional) -- 29 real methods
  in the whole closed world blocked purely by a keyword-only shape, every
  one with no real `**rest` receiver. `KEY_P`/`KARG`/`KEYEND` (three new
  opcodes) translate in place with no region-replacement machinery at all,
  reading real `_impl` parameters the entry wrapper fills in from mruby's
  own `mrb_kwargs` extraction mechanism -- a missing required keyword or
  an unrecognized one both raise a real `ArgumentError` automatically,
  exactly matching interpreted Ruby's own semantics. Devirtualization and
  ivar embedding are deliberately left untouched this round, matching
  `docs/adr/0148`'s own established practice. Also fixes a real,
  previously-latent bug found during this same verification pass: every
  `JMPNOT`/`JMPIF`/`JMPNIL` target-address extraction in this file
  silently read `0` instead of the real target the moment its own branch
  register happened to be a genuinely named local (a real disassembly
  comment mrbc only emits in that case) -- `KEY_P` is the first opcode in
  this file to ever write directly into such a register and branch on it,
  so no prior real call site ever surfaced this. Verified against a real
  runtime harness (through real interpreted Ruby call sites -- the only
  way to exercise mruby's own real keyword-argument calling convention),
  every pre-existing test harness re-confirmed passing after the
  `JMPNOT`/`JMPIF`/`JMPNIL` fix, and the usual real end-to-end regen +
  `register.cxx` compile (`SKIP_UNSUPPORTED=1`): zero regressions, 17
  newly-clean methods in `mruby-rpg2k-compiled`. `*rest`/`**kwrest` and a
  block parameter remain unsupported. See docs/adr/0149.

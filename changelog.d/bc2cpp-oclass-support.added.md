- `tools/bc2cpp/bc2cpp.rb` can now compile a method using real `::Foo`
  root-scope constant syntax -- `LCF::File#save_to`'s own
  `::File.open(path, 'wb') { |f| f.write to_lcf }` (`::File` specifically
  because `LCF::File` -- this very class -- would otherwise shadow the real
  top-level `File`, per that method's own existing comment) -- previously an
  honest `#error unhandled opcode OCLASS` regardless of how simple the rest
  of the call was.

  Confirmed against real mruby VM source (`3rd/mruby/src/vm.c`'s own
  `CASE(OP_OCLASS, B)`): `regs[a] = mrb_obj_value(mrb->object_class)` --
  exactly the same "the root/Object scope, as a real `mrb_value`" construct
  `GETCONST`'s own top-level-owner branch already builds by hand a few
  lines up in this same file. A fresh `mrbc -v` disassembly confirms the
  real shape: `OCLASS R3` is always immediately followed by a `GETMCNST R3
  (R3)::Name` reading the named constant off of whatever register `OCLASS`
  just populated -- `GETMCNST` was already unconditionally supported
  (`r<d> = mrb_const_get(M, r<d>, ...)`, reusing whatever scope value is
  already sitting in that register), so the whole fix is exactly the one
  real line `OP_OCLASS` itself performs, with zero special-casing needed on
  the `GETMCNST` side.

  Verified against the real whole-program diagnostic: compiled entry
  points 2248 -> 2249, method-level coverage 96.9% -> 97.0%, `unhandled
  opcode OCLASS` 1 -> 0, total `#error` markers 125 -> 124.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/rpg2k_scene_check.rb`
  (1062 checks), and `scripts/lcf_testbed_check.rb` all still pass
  unchanged. Directly inspected real generated output: `LCF::File#save_to`
  now compiles fully clean, its own `r3 = mrb_obj_value(M->object_class);
  r3 = mrb_const_get(M, r3, mrb_intern_cstr(M, "File"));` correctly
  resolving the real top-level `File` class regardless of this method's
  own `LCF::File` lexical scope -- exactly the semantics the source
  comment's own `::File` was written to guarantee. A real `g++
  -std=c++17 -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1`
  generated output confirms the exact same 17 pre-existing,
  already-documented, unrelated errors as immediately before this change
  and zero new ones.

  Also investigated (this same round) the remaining small `#error`
  buckets this left behind: `LAMBDA` (1 site, `RPG2k::Scene::Menu#
  draw_status_row`'s own `line = ->(n) { y + n * LINE_H }` local-helper
  idiom) needs real upvar capture inside `LAMBDA_FALLBACK_SUPPORT`, which
  -- unlike `BLOCK_FALLBACK`'s own method-name-allowlist safety argument
  (the receiver invokes the block synchronously, never stores it) -- has
  no equivalent soundness story for a real first-class `Proc` value that
  could in principle be stored, returned, or invoked long after its
  enclosing method returns; not pursued for one site without a real
  escape-analysis story. `SCLASS` (2 sites) and `SDEF` (1 site) are both
  inside `RGSS.singleton#effect_probe`/`#audio_probe` -- CLI-flag-only
  diagnostic probes that reopen a live object's own singleton class
  (`class << Graphics; def update; ...; end; end`) or define a method
  directly on one specific object instance (`def archive.read(name)`) --
  genuine runtime monkey-patching this whole-program AOT compiler's own
  static-dispatch model cannot soundly support at all, not merely
  "not yet implemented"; correctly left on the interpreter.

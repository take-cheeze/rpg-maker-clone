- `tools/bc2cpp/bc2cpp.rb`'s `NATIVE_PRIMITIVE_SEND_ARITY` gains a `to_s`
  entry, but as a real `mrb_type(recv)` switch rather than a single
  unconditional/guarded call like the rest of that table: a direct grep
  across `3rd/mruby/src` finds `to_s` registered separately on Array,
  String, Hash, Integer, Float, Range and Module/Class, plus Kernel's own
  inherited default -- eight distinct native bodies `native_only_mono?`'s
  own registry check still collapses into one entry (it only ever proves
  "no bytecode override anywhere", never "one native implementation").
  Only String (`mrb_str_to_s`, hand-reproduced -- a plain-String receiver
  returns itself, a subclass instance gets a real dup) and Integer
  (`mrb_integer_to_str`, a real public `MRB_API`, base 10) are handled
  directly; every other type -- Array/Hash explicitly included, found only
  by reading their real bodies rather than trusting their exported/native
  status -- falls through to ordinary `mrb_funcall`. `mrb_ary_to_s`/
  `mrb_hash_to_s` both unconditionally mutate `mrb->c->ci->mid` as their
  own first line (`3rd/mruby/src/array.c`/`hash.c`), real VM call-frame
  state a direct call from generated code would silently corrupt, not
  merely risk a stale read the way `monomorphic_target`'s own existing
  comment already warns about for calling an arbitrary native function.
  126 real call sites flip from `mrb_funcall` to the guarded switch.

  `GETIDX`'s own opcode-level fast path (Array/Hash, both already
  type-tag-guarded and unconditional -- confirmed via a dedicated survey
  that there was nothing to widen there) now also covers String with an
  Integer/String/Range index, mirroring `3rd/mruby/src/vm.c`'s own
  `OP_GETIDX` handler's third arm exactly (`mrb_str_aref`, the real
  `str[idx]` semantics -- character index, substring search, or a Range
  slice). `mrb_str_aref` is a real, externally-linked function declared
  only in `mruby/internal.h`, which -- unlike every other mruby header
  this file already includes -- has no C-linkage guard at all, so it gets
  a direct `extern "C"` forward declaration in the generated output's own
  preamble instead of a naive `#include` (confirmed by reading the whole
  header, not assumed). Does not reproduce the real VM's own exact-class
  guard (rejects an Array/String/Hash subclass overriding `[]`) -- a real,
  pre-existing gap this opcode's own Array/Hash arms already had before
  this round touched String, left alone rather than fixed as a drive-by.
  2293 real `GETIDX` call sites gain the new arm (purely additive: every
  site keeps its existing Array/Hash fast paths and `mrb_funcall`
  fallback unchanged, just with one more branch tried first).

  Both verified via real whole-program regen diffs (`#error` count
  unchanged at 8, zero unrelated diff lines) and independent runtime tests
  against a minimal `libmruby.a`: `to_s` checked for String (including the
  self-identity/no-allocation case), Integer, and the Array fallback path;
  `GETIDX` checked for a positive and negative Integer index, a matching
  and non-matching String index, a Range index, and an unsupported index
  type (Symbol) correctly falling through to `mrb_funcall` and raising the
  same real `TypeError` both ways. `scripts/rpg2k_logic_check.rb`/
  `scripts/rpg2k_scene_check.rb` both still pass, and `docs/
  bc2cpp_coverage.txt` needed no regeneration.

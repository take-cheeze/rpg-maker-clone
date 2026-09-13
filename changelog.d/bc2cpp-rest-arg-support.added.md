- `tools/bc2cpp/bc2cpp.rb` now compiles methods with a real `*rest` splat
  parameter (`def foo(a, *rest)`) -- 7 real methods in the whole closed
  world blocked purely by a rest-only shape. Needs no opcode-level
  recognition at all: mruby's own real `ENTER` VM semantics already
  populate the rest register directly with a real, boxed `Array` before
  the method body starts, contiguous with the mandatory arguments, so this
  folds straight into the same mechanism `docs/adr/0148`'s own optional-
  argument round already established -- the entry wrapper's own real
  `mrb_get_args` `*` extraction is the only genuinely new code, copying
  the VM's own transient argument pointers into a real, independently-
  owned `Array` via `mrb_ary_new_from_values` before handing it to the
  compiled body. Devirtualization and ivar embedding are left untouched
  this round, matching established practice. Verified against a real
  runtime harness (through real interpreted Ruby call sites) and the usual
  real end-to-end regen + `register.cxx` compile: zero regressions, 1
  newly-clean method (`LCF::Array1D#method_missing`) in
  `mruby-lcf-compiled` -- the remaining real rest-only methods each stay
  blocked for their own separate, already-understood gap (a splat *at a
  call site*, or a bare `super` outside the existing allowlist), not
  anything left over here. A splat at a call site, post-splat mandatory
  arguments, and a block parameter remain unsupported. See docs/adr/0150.

- **bc2cpp**: an ivar written only Integers and nil now embeds as a tagged
  Integer-or-nil field instead of staying in `iv_tbl` (ADR 0232). Both arms
  are immediates, so the payload still needs no GC rooting or write
  barrier. `FIXNUM_NIL_IVARS` additionally names fields whose only Integer
  write is an opaque send, which the analysis cannot type on its own.

- **bc2cpp**: the ivar analysis's `ADD`/`ADDI` arm no longer assumes a
  Fixnum without reading its operands -- `ary + ary` is `Array#+`, not an
  Integer add. `ADDI` traces its destination instead. This matches the rule
  code generation already used for its own arithmetic fast path. The real
  build's embedded-ivar count drops from 290 to 281 as a result: fields
  like `@n = @n + x` with an unproven `x` were being typed as Integers
  without proof. Method-level coverage is unchanged at 100.0% with zero
  `#error`, and the real build embeds no nilable field yet.

- **bc2cpp**: fix a link failure for an embedded ivar that has both an
  `attr_reader` and an `attr_writer`. The synthesized writer reused the
  reader's entry-wrapper name, so every such class generated the same C++
  function twice. The writer now uses the `_eq` suffix the rest of the
  toolchain already assumes.

- **optcarrot probe**: fix three build problems that left the benchmark
  unable to run at all. The temporary C++ gem's `register.cxx` is created
  before mruby discovers the gem's sources and C++ exception compilation
  is enabled before the gem is added, so `src/register.o` is actually
  buildable; the probe now applies the same mruby patches the real build
  does (its generated code reads `mrb_state::errinfo`, which
  `patches/mruby-dollar-bang-scoped.patch` adds); and `LD` is removed from
  the rake environment rather than set to an empty string, which had left
  mruby's link command blank. `OPTCARROT_FIXNUM_NIL_IVARS` runs an opt-in
  Integer-or-nil A/B that also reports the linked binary's `.text`.

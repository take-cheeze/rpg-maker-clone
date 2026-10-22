# 541. Object placement for int16 vectors in bc2cpp

Date: 2026-10-22

## Status

Proposed

## Context

bc2cpp already embeds some ivars in the owner's C struct (ivar_layout.rb,
`C_TYPE` in codegen.rb). The embedded types today are `mrb_int`, `mrb_sym`,
`mrb_bool` and `Bc2cppFixnumOrNil`. Every one is POD, so the struct is allocated
with `mrb_calloc`, freed with `mrb_free`, and the generated `*_ivars_free`
destructor call compiles to nothing (codegen_emit.rb, NON_POD_MEMBER_SUPPORT).

A sealed int16 array ivar (see the design of the sealed element proof) would be
a `std::vector<int16_t>`. Its element storage has no references, so the GC
never needs to mark it. It is the first non-POD member, so three things have to
hold: it is constructed, it is destroyed, and reflection can still see it.

The earlier note on sealed locals (stack placement) is the other placement. This
ADR decides when a sealed array goes in the owner's struct and when it stays on
the C++ stack.

## Decision

1. **Ivar placement.** A sealed int16 array ivar lives in the owner's C struct
   as a `std::vector<int16_t>` member. It is not stored in `iv_tbl` and not in an
   `mrb_value` slot. The owner's struct is the only place that holds it, and the
   sealed proof (no escape, no reflection write, in-range stores) is what allows
   that.

2. **Construction.** The struct is no longer only `mrb_calloc`ed. Immediately
   after the allocation, and before `mrb_data_init` publishes `DATA_PTR`, bc2cpp
   placement-constructs every non-POD member. No call that can raise sits between
   the construction and the publication. A `dfree` that runs on an object whose
   `initialize` raised early already has the `if (!p) return;` guard, so an
   unconstructed struct is never destroyed.

3. **Destruction.** The existing `*_ivars_free` already calls `~T()` before
   `mrb_free`. Nothing new is needed there. Its comment says it exists for this
   case.

4. **Reflection.** The slot descriptor gains a new kind, `MRB_DATA_IVAR_INT16_VEC`
   (vendored mruby patch `mruby-rdata-ivar-slots.patch`). On read it boxes the
   vector into a fresh Array, so `instance_variable_get` and `inspect` see the
   same values as the generic path. On write it refuses: a write through
   reflection means the sealed proof's premise is false, so the object raises
   instead of storing a value the compiled reads would not expect. The proof
   already excludes `instance_variable_set` on the owner, so the refusal is a
   backstop, not the normal path.

5. **GC.** Typed slots are not marked (rdata_ivar mark loop). The vector's
   contents are `int16_t`, so no marking is needed.

6. **Stack placement** stays for sealed arrays that never reach an ivar. Those
   are `std::vector<int16_t>` locals. Their destructor runs on the C++ exception
   path, which covers the `raise`/`break` paths bc2cpp emits.

## Consequences

- The only new C++ type is `std::vector<int16_t>`. It needs one `C_TYPE` entry
  (`int16_vec`) and one box/unbox/check helper trio, plus the new descriptor
  kind. Those are the three edit points.
- The vendored mruby change is the one new patch in this design. It has to go
  in the `patches/` chain the same way the other RData patch does.
- Reflection gets a copy on every `instance_variable_get`. That matches what
  `int16_values` already does for the LCF arrays, and it only happens for owners
  that are sealed.
- Owners in `NATIVE_DATA_OWNERS` keep their ivars in `iv_tbl`, as today.
  Their `DATA_PTR` is taken, so they cannot host a vector.
- The LCF fields are not covered. They escape and are written with arbitrary
  values (ADR 0537, deprecated, records the measurement). This design applies
  only to owners and locals that the proof seals.

## Open questions

- Whether the reflection refusal should be a `TypeError` or a silent copy-on-write
  to a boxed Array. The first matches the existing typed-slot store check; the
  second would hide a real violation.
- Whether `dup` and `Marshal` need the vector to be copied or re-derived from the
  Array form. Both currently go through the reflection path.

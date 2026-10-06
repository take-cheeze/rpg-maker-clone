# 0363. The index helpers' by-name arm cannot be closed with today's world facts

Date: 2026-10-06

## Status

Accepted (analysis only; no generator change)

## Context

ADR 0360 closed `bc2cpp_slow_div` because only Integer and Float answer `/` and the helper already ran both bodies.
The next-largest helper-held by-name calls are the shared index helpers (shipped wio pass, base `887e1c9`):

| Helper | Name | Generated callers |
| --- | --- | ---: |
| `bc2cpp_getidx` | `[]` | 2,017 |
| `bc2cpp_getidx0` | `[]` | 32 |
| `bc2cpp_setidx` | `[]=` | 348 |

`CallFacts::Answers` on that world gives:

* `[]`: ruby definers Sections, Array1D, Array2D, File, Switches, Variables, Actors, LRUBitmapCache; native
  definers Array, Hash, String, Struct, Method, Table, OnigMatchData, Proc; no module, foreign or singleton definer.
* `[]=`: ruby definers Array1D, Array2D, File, Switches, Variables, LRUBitmapCache; native definers Array, Hash,
  String, Struct, Table.

A closed form would be a class-tag switch (a direct call for each registry class, the native body for each core
class) with a proven `bc2cpp_nomethod` else, as in ADR 0360. This ADR records why it was not built.

## Decision

Neither helper is changed. The by-name arm stays, because the proof the closed else needs is not available:

1. **`members` is blind to class-object receivers (`[]` only).** `Answers` reads instance registrations
   (`MRB_MT_ENTRY` tables and the instance `mrb_define_method*` forms); class and singleton registrations are
   deliberately left out (`NativeExpressionDevirt.scan_class_registrations`, "cannot shadow the same name in an
   instance receiver's method lookup"). `[]` has class-level natives that a helper receiver can be:
   `Array.[]` (`mrb_ary_s_create`), `Hash.[]` (mruby-hash-ext `hash_s_create`), every `Struct.new` class's `.[]`
   (`mrb_instance_new`, which runs `initialize`), and `Set.[]` when mruby-set is linked. A receiver that is a Class
   object reaches the helper's else, so a proven NoMethodError there would be wrong (it would trip
   `closed-world proof violated`). `[]=` has no class-level native, so it does not have this gap.
2. **Proc#[] and Method#[] have no helper-callable body.** `Proc#[]` is `call_proc`, a VM-level method that
   re-enters the interpreter on the proc's own frame (break/return/lambda arity semantics); `Method#[]` is
   `method_call`. A C helper can only reach them through a dispatch (`mrb_funcall*`, `mrb_yield*`), which is the
   by-name call being removed or an inexact stand-in.
3. **The other native bodies are `static` in mruby and read the caller's frame.** `mrb_ary_aget`/`aset`,
   `mrb_str_aref_m`/`aset_m` (with `str_convert_range`, `str_replace_partial`, `chars2bytes`),
   `mrb_struct_aref`/`aset` (with `struct_members`, `struct_index`) and the rgss `table_get`/`table_set` are not
   exported, and several (`aget_index`, `mrb_str_aset_m`, `table_set`) call `mrb_get_args`, which reads the
   arguments of the *current* callinfo, i.e. the calling compiled method, not the helper's. A mirror has to
   re-implement each body (including the `MRB_UTF8_STRING` string paths) from the public API; Table lives in
   another library, so it would also need a new exported symbol. Array and Hash (`mrb_hash_set` ignores the frame)
   are mirrorable with `mrb_range_beg_len`, `mrb_ary_set`/`splice` and `mrb_hash_get`/`set`; String, Struct,
   Table and the three registry-derived subclasses (`LCF::Database`, `MapTree`, `MapUnit`, `SaveData` are members
   through inheritance) would each need an arm plus an equivalence matrix.
4. **Partial closure buys nothing measurable.** The census counts a helper as by-name as long as one arm is. Until
   every arm is direct the 2,397 callers (2,017 + 32 + 348) still reach a by-name call, so mirroring Array and
   Hash alone would add risk (a reimplemented body that can drift from mruby's) for no change in the table.

## Consequences

The three helpers keep their shape and their by-name tail (ADR 0216). What would unblock them, in order of cost:

* `[]=` first: no class-level native, one fewer member set than `[]`. It needs exact mirrors of Array (range
  splice, `aget_index`'s TypeError text, frozen check), Hash, String, Struct and Table (an exported rgss entry),
  plus direct arms for the six registry classes and their subclasses, checked against the real method over a
  matrix at mrb_int 64, int32 and no-bigint (the shape of `scripts/bc2cpp_numeric_slow_check.rb`).
* `[]` then needs `Answers` to scan class-method registrations (`mrb_define_class_method*`, the `.singleton`
  forms) so a Class-object receiver is a member, plus a body for `Array.[]`, `Hash.[]` and Struct classes, and a
  decision for Proc#[] and Method#[] (an exact call needs a VM entry point, not a name).
* Alternatively, export the static bodies from the patched mruby (the project already patches it) so the helpers
  call mruby's own functions instead of copies.

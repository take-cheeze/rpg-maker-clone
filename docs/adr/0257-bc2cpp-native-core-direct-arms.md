# 0257. bc2cpp calls verified mruby core natives directly

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0253 lets a send to an RGSS native skip dispatch when the receiver class is
one of the RGSS classes. The same idea applies to mruby's own natives, and the
wio closed-world report suggested a large opportunity: the excluded-definition
reason `native_or_uncompiled` was 1,033, and the largest unresolved generic
names were core methods (`min`, `inspect`, `pack`, `index`, `compact`, `join`,
`sort`, `send`, `bytes`).

Measured against the sources, that picture was mostly wrong.

- The 1,033 are not core methods. They are chains whose collapsed `<native>`
  placeholder is an RGSS native (`dispose` 166, `width` 113, `y` 103, `x` 102,
  `color=` 56, `visible=` 53 ...) that ADR 0253 already covers with exact-class
  arms. The diagnostic kept counting them because it only knew the definition
  has no irep.
- Of the top unresolved generic names, only `join`, `shift`, `index`,
  `compact`, `bytes` and `Integer#inspect` are core natives with a body that
  does not read the caller's frame. `min` is `Enumerable#min` (Ruby, in
  `enum.rb`), `sort` is Ruby, `pack`/`unpack`/`send`/`raise` call
  `mrb_get_args`, and `Time#min` is the only native registration `min` has, so
  it looks single-definition to the registry.
- Only `Array#join`, `#shift` and Integer `#inspect` have a public MRB_API entry
  point. `compact`, `index` and `bytes` are `static` in mruby's sources.

## Decision

Table. `tools/bc2cpp/native_core_direct.rb` lists hand-audited rows: name,
builtin owner, arity, argument guard, C expression. Every compile re-audits each
row against the real sources (`NativeCoreDirect.audit`): the ROM registration
must still bind the audited function to that name on that class with that
`aspec`; the registered function's body (and, for mirrors, the bodies it calls)
must equal the text the row was written from, comments and whitespace aside; no
other native registration may spell the name on that class or on an unresolved
one; and a public API the expression names must still be declared `MRB_API`. A
row that fails is dropped, not trusted. The registration scan is the one
`analyze_exact_class_expressions` already ran, now shared
(`NativeExpressionDevirt.class_registrations`) and memoized on file identity.

Mirrors. Where the body is static, the row calls `bc2cpp_ary_compact`,
`bc2cpp_ary_index` or `bc2cpp_str_bytes`, small `static inline` helpers emitted
into the output only when it uses them (`emit_native_core_helpers`). The audited
body text is what pins their behavior.

Arms. `tools/bc2cpp/codegen_native_core_direct.rb` is prepended to `CodeGen` and
wraps `native_direct_dynamic_line` and `guarded_fallback_line`. It puts an
exact-class arm in front of the send: `mrb_array_p(r) && mrb_obj_ptr(r)->c ==
M->array_class` (a subclass or singleton receiver fails it), or
`mrb_integer_p(r)` for Integer. The argument guard keeps the C wrapper's
coercion out of the fast path: `join` takes only nil or a String separator,
`index` any value, and anything else reaches the send, which raises what the
wrapper would. Blocks, other arities (`shift(n)`, `inspect(base)`) and non-closed
worlds get no arm.

Closed world. An arm is emitted only when nothing can shadow the native:

- no project definition on the class, no prepend, no unresolved mixin, no
  dynamic installer (`symbol_installed_names`);
- no outside Ruby definition, alias, `undef`/`remove_method`, visibility change,
  `prepend`, `*_eval` or computed definition on that class
  (`ClosedWorld#core_native_arm_safe?`). The closed world only knew outside Ruby
  names globally, which refuses `inspect` because `Rational#inspect` exists, so
  `tools/bc2cpp/foreign_definers.rb` walks the outside sources with Prism and a
  lexical class stack and attributes each definition to its class. It is
  deliberately over-approximate (a nested `Foo::Array` counts as `Array`; a
  computed definition makes the whole class wild).

The arm's else is the unchanged dispatch, so the closed world's by-name refusal
(`core_or_native`) is untouched: this ADR removes executed dispatches, not send
sites.

Diagnostic. A definition whose chain the RGSS arms fully cover (ADR 0253's lift)
is now reported as `native_direct`, not `native_or_uncompiled`, in `POLY_DIAG`
and the coverage report. Emitted code does not change for it.

## Consequences

The wio report: `native_or_uncompiled` falls from 1,033 to 261 and
`native_direct` is 772; the rest is other classes' natives (`name`, `delete`,
`resume`, `string`, `parameters`, ...) that this ADR does not cover. There are
69 new arms (`inspect` 23, `index` 13, `join` 11 of which 5 take a separator,
`compact` 11, `shift` 6, `bytes` 5). Cached send sites (10,185) and
generic POLY sites (467) are unchanged: every arm keeps the send as its else,
because none of these sites has a receiver-class proof, and a literal-array
receiver proof was tried and found to apply to no site (every `[x].compact`
here sits on a join of two branches). Executed dispatches drop, not the count.

Not converted, with the reason: `min`, `sort`, `uniq`, `cover?` (Ruby in mruby),
`pack`, `unpack`, `send`, `raise`, `write`, `read` (frame-dependent bodies),
`String#inspect` (`mrb_str_inspect` is in `internal.h`), Float and Symbol
`inspect` (static). `Array#at` is already generated from its registered body by
`NativeExpressionDevirt`.

Adding a row means writing the audited body next to it; a mruby upgrade that
changes a body disables the row and fails
`scripts/bc2cpp_native_core_direct_check.rb`, which also compiles every
emitted arm against the core library and compares it with ordinary dispatch on
edge inputs (subclasses, frozen and recursive arrays, non-String separators,
`MRB_INT_MIN`/`MAX`). `Array#compact` is a gem method and is not in that
library, so it is pinned by its audited body only.

Residual risk: the direct calls allocate in the enclosing function's GC arena
without the save/restore `mrb_funcall` performs, like the other direct
`mrb_*` calls. A hot loop in one compiled method that joins many arrays grows
that arena until the method returns.

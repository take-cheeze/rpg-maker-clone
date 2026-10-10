# 0394. bc2cpp: an exact Array's non-fixnum index runs the native body (INTEGER_TAG_ELSE)

Date: 2026-10-10

## Status

Accepted

## Context

An index site (`x[k]`, `x[k] = v`) whose receiver is proven an Array (INDEX_EXACT, ADR 0296) emits an Integer-tag test
on the index and, as its else, a by-name send. The tag test is on the index register, not the receiver, so the else
runs for every key that is not a fixnum (a Range, a String, a Float, nil, a bignum).

Measured on master `67084574` (wio closed world, `3rd/mruby` at the pinned commit, `SKIP_UNSUPPORTED=1`,
`scripts/bc2cpp_dynamic_site_census.rb` with the exact SiteOriginTable), the census's `numeric_tag_guard` shape holds
141 by-name sends: `[]` 106, `inspect` 25, `[]=` 5, and five others (`push` 2, `unshift` 1, `sort` 1, `div` 1).

- The receiver origins of the 141 (exact): constant 32, direct call result 25, captured upvar 24, parameter 19, literal
  or fresh 14, ivar read 10, embedded ivar 8, other 4, indexed result 2, self 1, join 1, call result 1.
- All 111 `[]` / `[]=` sites are INDEX_EXACT: the receiver is exactly Array, and the index's tag test guards only the
  key. The by-name else therefore dispatches `[]` / `[]=` on a known Array with a non-fixnum key.
- The 25 `inspect` sites test the receiver itself. Their receivers are not exact, and `inspect` has no bounded
  definer set: `mrb_obj_inspect` is registered on Kernel (`src/kernel.c`), which is in `CallFacts::EVERYTHING`, so
  `CallFacts::Answers#definers` returns nil. No class set is provable, and they stay by name.
- The five others are not index sites, and their receivers are not proven exact. They stay by name.

The closed world already answers `[]` and `[]=` on an Array with a verified native body: the INDEX_CLOSED Array arms
(ADR 0365) call `mrb_ary_aget1_impl` and `mrb_ary_aset2_impl`, exported by `patches/mruby-expose-index-bodies.patch`,
and the generator checks those bodies in the sources it builds from (`index_arm_verified?`). The helper tails
`bc2cpp_getidx` / `bc2cpp_setidx` already use them; the inline else of an exact site did not.

## Decision

For an INDEX_EXACT Array receiver, the else of the index's Integer-tag test calls the native body directly
(`codegen_integer_tag_else.rb`, used by the GETIDX and SETIDX Array arms in `codegen_insn.rb`):

    r<d> = mrb_ary_aget1_impl(M, r<d>, r<s>);            // GETIDX
    r<d> = mrb_ary_aset2_impl(M, r<d>, r<idx>, r<val>);  // SETIDX, the value is the result (as the SETIDX fast path)

The direct call is taken only when `integer_tag_else_array_refusal` finds nothing wrong:

- the closed world is indexable (`index_closed_world?`: no global refusal, no method_missing class, singleton-free
  instances) and the name is not blocked;
- `CallFacts::Answers#definers(name)` is bounded (nil for an Object, Kernel or BasicObject definer, an install, or a
  hook), and no definer is a singleton;
- the native registration of `name` on Array is present, linked, and verified against the sources
  (`index_arm_verified?`);
- no Ruby or foreign definer, and no module definer, is on Array's ancestry (prepended modules included).

Otherwise the else stays the by-name send, and the refusal reason is counted: `unbounded`, `singleton_definer`,
`no_native_array`, `ancestor_definer`, `module_definer`, `arm_not_linked`, `arm_unverified`, `blocked_name`, `disabled`,
or `receiver_not_exact` (a static Array hint that is not exact). The stderr summary prints the counts.

No candidate class set is needed for these sites, and the brief's `[]` candidate list (Array, Hash, String, Range,
Struct, LCF) does not enter. The receiver is already exactly Array, so the answer for `[]` is the Array body for every
key, and the miss path is unreachable. A direct call on the exact class tests nothing further, because the INDEX_EXACT
proof is the test (ADR 0296). Subclasses are not affected: a definer on a subclass is not on Array's ancestry.

`BC2CPP_INTEGER_TAG_ELSE=0` restores the by-name else, and then the output is byte-identical to master.

## Measurement

Same method as the census above, on the wio closed world with `SKIP_UNSUPPORTED=1`.

| | master | this change |
|---|---|---|
| `bc2cpp_send(` | 1946 | 1835 (-111) |
| `mrb_funcall*` in shipped text | 395 | 395 (the sites' by-name text is `bc2cpp_send`, so unchanged) |
| `numeric_tag_guard` by-name sends | 141 | 30 |
| `shipped.cxx` bytes | 21,536,897 | 21,534,959 (-1,938: the removed by-name text, less the new prototypes) |
| `shipped.cxx` lines | 442,530 | 442,534 |

The stderr counter `direct` counts emissions, not shipped sites: a method compiled and later dropped is counted too. The
census of the shipped text is the measure of record (111 sites removed: 106 `[]`, 5 `[]=`).

Refusals in the shipped build (emission counts): `[]` receiver_not_exact 129, `[]=` receiver_not_exact 68. Those are
static Array hints that are not exact, and are unchanged by this ADR. The 30 remaining `numeric_tag_guard` sites are the
25 `inspect` (unbounded) and the five others above.

Kill switch: `BC2CPP_INTEGER_TAG_ELSE=0` gives a `shipped.cxx`, a stderr, and an origin table byte-identical to master.

## Checks

- `scripts/bc2cpp_integer_tag_else_check.rb`: the emitter in process (the direct text, each refusal reason counted, the
  kill switch counts nothing); generated fixtures (the exact literal receiver emits the direct calls and the prototype, and a subclass's own `[]` does not block them;
  the kill switch and the non-exact and Object-definer fixtures are byte-identical to the reference, which is the
  origin/master tool when `BC2CPP_BASE_TOOL` is set, else the kill switch; a prepended module refuses with
  `ancestor_definer`); and a mutant that drops the ancestor rule, which the refused fixture then exposes (`MUTANT=1`).
- `scripts/bc2cpp_integer_tag_else_run_check.rb`: on a full-core mruby built from this tree's `3rd/mruby`, the compiled
  `get` / `put` over 19 keys (fixnums either side of the range, out-of-range counts, Float, nil, String, Ranges,
  reversed and out-of-bounds Ranges, NaN) answers as the interpreter does: value, class, exception class and message.
- Existing checks rerun against this change, all PASS: `bc2cpp_getidx_integer_arm_check`, `bc2cpp_index_closed_check`
  (with the full build), `bc2cpp_outlined_index_check` (with a core-only build), `bc2cpp_setidx_devirtualization_check`,
  `bc2cpp_frozen_tables_check`, `bc2cpp_class_pools_check`, `bc2cpp_constructor_pools_check`.

## Consequences

- A non-fixnum key on an exact Array runs in the native body with no by-name dispatch. The body is the one the interpreter
  calls, so the value, the exception class and the message are the same (checked on real mruby). A native call made
  directly does not push a C frame for `[]`; backtraces for an exception raised inside the body may differ from the
  by-name path. ADR 0365 already accepted this for the helper tails, which call the same bodies.
- The change depends on `patches/mruby-expose-index-bodies.patch`: without it `index_arm_verified?` refuses and the
  else stays by name.
- The `inspect` sites are not addressed. A bounded set for them needs a receiver class proof the closed world does not
  give for these origins (direct call results, parameters); that is follow-up work, and the brief's "inspect on a proven
  class set" needs that proof first.

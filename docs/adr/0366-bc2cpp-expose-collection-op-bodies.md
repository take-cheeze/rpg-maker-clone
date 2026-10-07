# 0366. The `- & | <<` helpers call exported bodies of the mruby gems that keep them static

Date: 2026-10-06

## Status

Accepted

## Context

ADR 0360, 0361 and 0364 closed the by-name fallback of the shared numeric helpers (`bc2cpp_slow_*`, ADR 0292) whose
operator is answered by classes the helper can run with public mruby API. They left four open because a member class
answers with a body that is `static` in mruby:

| Helper | Callers (wio) | Member classes | Body that was out of reach |
| --- | ---: | --- | --- |
| `-` (`bc2cpp_slow_sub_f`) | 471 | Integer, Float, Array (Time where mruby-time is linked) | `ary_sub`, mruby-array-ext: a khash set or an `==` walk calling the elements' `hash`, `eql?`, `==` |
| `&` (`bc2cpp_slow_and`) | 66 | Integer, nil, true, false, Array | `ary_intersection`, mruby-array-ext |
| `\|` (`bc2cpp_slow_or`) | 14 | same | `ary_union`, mruby-array-ext |
| `<<` (`bc2cpp_slow_lshift`) | 122 | Array, String, IO, Integer, `Enumerator::Yielder`, `RGSS::ErrorReport::Tee` | `str_concat_m` (mruby-string-ext), `io_lshift` (mruby-io) |

Mirroring `ary_sub` line by line would copy a khash set, the shared-copy protection of the operands and the user
callbacks, and would drift from mruby silently. The project already patches mruby (`patches/*.patch`, applied by
`scripts/apply_mruby_patch.bash`), so the bodies are exported instead.

## Decision

### The patch

`patches/mruby-expose-collection-op-bodies.patch` (one file, applied last) splits five static bodies. Each gets an
exported C-linkage function that takes its operands explicitly and holds the whole body; the method wrapper keeps its
argument parsing and calls it.

| Exported | Wrapper | Notes |
| --- | --- | --- |
| `mrb_ary_ext_sub_impl(mrb, self, other)` | `ary_sub` | `mrb_get_args "A"` stays in the wrapper; the impl is `ary_subtract_internal(mrb, self, 1, &other)` |
| `mrb_ary_ext_and_impl` | `ary_intersection` | same shape over `ary_intersection_internal` |
| `mrb_ary_ext_or_impl` | `ary_union` | same shape over `ary_union_internal` |
| `mrb_str_ext_concat_impl(mrb, self, other)` | `str_concat_m` | one operand: `str_concat` with the receiver's binary flag, returns `self` |
| `mrb_io_lshift_impl(mrb, io, str)` | `io_lshift` | stream checks, `mrb_obj_as_string`, `fd_write` |

The interpreter runs the same statements in the same order. `String#<<` and `IO#<<` call the impl only for the
one-operand shape (`mrb_get_argc == 1`) and keep their old sequence for any other, so `io.<<()` on a closed stream still
raises the IOError before the arity error. The declarations sit in `MRB_BEGIN_DECL` so the function keeps C linkage
when mruby is compiled as C++ (the host and test builds). `Array#<<` needs no patch: `mrb_ary_push_m` with one operand
is the public `mrb_ary_push`.

How every target applies it: `cmake/build-mruby.cmake` (`rpg2k_mruby_patch`, after `mruby-no-irep-debug`) serves the
native, Emscripten, PSP (`app/psp/CMakeLists.txt` includes the same file), Android and Wio (cmake) builds and
`mruby_host_mrbc`; `scripts/maix_mruby_build.bash` and `scripts/wio_bc2cpp_measure.bash` keep their own copies of the
list and gained the entry. PlatformIO links the libmruby those produce, and the nix flake builds through cmake, so
neither has a list. The width builds of `scripts/bc2cpp_width_build.rb` use the patched tree.

### The helpers

`NUMERIC_SLOW_CLOSED` gains `-` (Integer, Float, Array), `&` and `|` (Integer, nil, true, false, Array) and `<<`
(Integer, Array, String, IO). The conditions of ADR 0360 stay (closed world, no global refusal, singleton-free, no
`method_missing` class, every definer native: no Ruby, module, foreign or singleton definer, members inherit an
owner) and `numeric_slow_collection_ready?` adds the proof that the exports are real in the tree bc2cpp scanned:

* the build's gem list (`BC2CPP_BUILD_GEMS`) names mruby-array-ext (`- & |`) or mruby-string-ext and mruby-io (`<<`);
  an unknown list or a missing gem keeps the helper open;
* the complete native registration table of the operator is the expected one (class, function, source file), with no
  attribute-less registration (`opaque_owners`): a second native `Array#-` or an unreadable one opens the helper.
  mruby-time's `Time#-` is the one tolerated extra, and `numeric_slow_members` already removes it only without the gem;
* the scanned source defines each `_impl` without `static` and the method's wrapper calls it. A tree without the patch
  therefore keeps the by-name helper instead of failing to link.

The closed text switches on the receiver and calls the export; the by-name copy stays under
`#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)` (Complex and Rational define `-`). `BC2CPP_NUMERIC_SLOW_CLOSED=0`
restores the old helpers byte for byte. The generated C++ declares the exports itself with `extern "C"`.

| Helper | Arms |
| --- | --- |
| `-` | Fixnum pair (unchanged), Integer/bigint/Float `mrb_num_sub`, Array `mrb_ensure_array_type` then `mrb_ary_ext_sub_impl`, else `bc2cpp_nomethod_named` |
| `&` `\|` | Integer/bigint as the `^` helper, nil/false and true as `false_and`/`true_and` (`false_or`/`true_or`) via `mrb_test`, Array `mrb_ensure_array_type` then the export |
| `<<` | Integer `int_lshift` (`mrb_as_int` count, `MRB_INT_MIN`, bigint), Array `mrb_ary_push`, String `mrb_str_ext_concat_impl`, IO (the class and subclasses, `mrb_obj_is_kind_of`) `mrb_io_lshift_impl` |

Every element callback (`hash`, `eql?`, `==`, `to_s`) is still a by-name call, made by mruby's own body through the VM.
That is the method's behaviour, so equivalence holds, and it is not generated code, so the census does not count it.

### What stays open, and why

`<<` does not close in the shipped wio world. Its definers there include `RGSS::ErrorReport::Tee#<<` (compiled Ruby of
mruby-rgss) and `Enumerator::Yielder#<<` (interpreted Ruby of mruby-enumerator). A foreign Ruby definer has no compiled
body to call directly, and mirroring it means a by-name `yield` and `Proc#call`. The closed `<<` form is therefore
produced only in a world without such a definer (the test fixtures drop mruby-enumerator) and is proven equivalent
there. `-` also stays open wherever mruby-time is linked (psp, maix, desktop): `Time#-` is static in mruby-time and its
patch is outside this family.

### Soundness

* The else is the proven NoMethodError of ADR 0360 (`bc2cpp_nomethod_named` dispatches by name first).
* The patch is part of the proof: bodies are pinned by digest in `scripts/bc2cpp_numeric_slow_check.rb`
  (`MIRRORED_BODIES`: the numeric and object.c bodies, `mrb_ary_push_m`, and the wrappers and `_impl` bodies of the three
  patched gems), so an mruby bump or an edit of the patch fails the check until the arms are re-derived.
* A world where the helper would call an export that is not linked cannot be generated (gem and source proofs above).

## Consequences

See `docs/bc2cpp-dynamic-site-census.md` for the measurement. A build that applies the patch but does not link
mruby-array-ext keeps `- & |` by name; a build that links mruby-set (not in any shipped gem list, and not in the
scanned sources) would add `Set#- & | <<` definers the scan cannot see, so the ADR 0360 assumption that the scanned
gems are the build's gems applies unchanged.

Equivalence is `scripts/bc2cpp_numeric_slow_check.rb` with `scripts/bc2cpp_collection_ops_matrix.rb`: every helper
called directly against the real operator over fresh receivers and operands (empty, frozen, subclass, shared copy,
UTF-8, 70,000 elements, nested, elements with a logging `hash`/`eql?`/`==`, one whose `hash` raises, wrong operand
types, closed and read-only streams), comparing result or error class and message, result class, frozen-ness and
identity, the receiver and operand afterwards, the elements' logged calls and what the pipe received, then compiled
against interpreted, at `mrb_int` 64, 32 (`BC2CPP_MRUBY_FULL32`) and without mruby-bigint (`BC2CPP_MRUBY_NOBIGINT`),
once more with the Complex and Rational macros set. The existing `+ - *` matrix now also covers the closed `-`.

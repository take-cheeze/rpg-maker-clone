# 0367. The `%` and `-@` helpers call mruby bodies a patch exports, and drop the by-name else

Date: 2026-10-06

## Status

Accepted

## Context

ADR 0360 and 0364 closed the by-name else of the numeric helpers whose members the helper already computed from
public API. Their tables left `%`, `-@`, `zero?`, `===` and the Hash arm of `< <= > >=` open for one of two reasons:
the body is a **static** function of mruby (`flodivmod`, `String#-@`, the sprintf formatter), or the definer is Ruby.
The project already carries local mruby patches (`patches/mruby-*.patch`, applied by `scripts/apply_mruby_patch.bash`
from `cmake/build-mruby.cmake`), so a static body that a helper needs can be exported instead of re-derived.

`CallFacts::Answers` for the wio closed world (all three compiled gems, `SKIP_UNSUPPORTED=1`):

| Name | Definers | Members | Callers | Outcome |
| --- | --- | --- | ---: | --- |
| `%` | native `Integer#%` `Float#%` (numeric.c), foreign Ruby `String#%` (mruby-sprintf) | Integer, Float, String | 138 | closed here |
| `-@` | native `String#-@` (mruby-string-ext), foreign Ruby `Numeric#-@` (`0 - self`) | Integer, Float, Numeric, String | 71 | closed here |
| `zero?` | foreign Ruby `Numeric#zero?` (`self == 0`), native class methods `File.zero?`/`FileTest.zero?` | none: unbounded | 33 | open |
| `< <= > >=` Hash arm | foreign Ruby `Hash#<` ... over `Enumerable#all?` and `==` | Hash | 908 | open |
| `===` | `Kernel#===` answers every object | none: unbounded | 110 | open |

## Decision

### The patch

`patches/mruby-expose-misc-bodies.patch` (one file, mruby only) exports four functions. Three of them are the whole
body of a method, moved out of the static method function, which keeps the registered name and now reads its
argument and calls it:

| Exported | From | Wrapper that stays registered |
| --- | --- | --- |
| `mrb_int_mod_impl(mrb, x, y)` | `int_mod` (`src/numeric.c`) | `return mrb_int_mod_impl(mrb, x, mrb_get_arg1(mrb));` |
| `mrb_flo_mod_impl(mrb, x, y)` | `flo_mod` (the `flodivmod` caller) | `return mrb_flo_mod_impl(mrb, x, mrb_get_arg1(mrb));` |
| `mrb_str_uminus_impl(mrb, str)` | `str_uminus` (`mruby-string-ext/src/string.c`) | `return mrb_str_uminus_impl(mrb, str);` |
| `mrb_str_format_impl(mrb, argc, argv, fmt)` | forwards to the static `mrb_str_format` (`mruby-sprintf/src/sprintf.c`) | none: `mrb_str_format` already took explicit arguments |

Interpreted behaviour is unchanged: each wrapper evaluates the same `mrb_get_arg1` the old body evaluated first and
passes it on. `flodivmod` stays static; the helper reaches it through `mrb_flo_mod_impl` / `mrb_int_mod_impl`, which
are the entire methods. There is no header change: the generated C++ declares each function `extern "C"` itself, in
the closed form that calls it. The three non-forwarding bodies sit in `#ifndef MRB_NO_FLOAT` and gem boundaries
exactly as before.

How each target gets the patch. `cmake/build-mruby.cmake`'s `rpg2k_mruby_patch` chain runs ahead of every rake
build that goes through cmake: the root `CMakeLists.txt` (native, Emscripten, and Android, whose Gradle project points
its CMake build at it) and `app/psp/CMakeLists.txt`; one line after `mruby-no-irep-debug.patch` covers them. Three
builds do not go through that module and keep their own list, which the cmake file's comment says must stay in sync,
and each got the same entry: `scripts/maix_mruby_build.bash` (the Kendryte build),
`scripts/wio_bc2cpp_measure.bash` (the `MRUBY_TARGET=wio rake` the PlatformIO `wio_rgss_boot` env links, in CI and
for the size measurement) and the check libmruby builds (`scripts/bc2cpp_width_build.rb`, which runs on a tree "any
cmake build" already patched, `docs/ci.md`). The nix flake patches no mruby source (its patch list is ppsspp and the
psp fixup tool), `platformio.ini` names no patch, and `scripts/apply_mruby_patch.bash` is idempotent, so the patch
applies on top of the other thirteen in the order of the chain (the last link) and a second configure leaves it
alone. `scripts/mruby_patch_context_check.rb` passes (every hunk carries context).

### The analysis

`tools/bc2cpp/core_misc.rb` (`CoreMisc`, modelled on `CoreCompare`) names what the two helpers stand on and
`CodeGen#numeric_slow_misc(op)` (`codegen_numeric_slow_misc.rb`) proves it for the world:

* Ruby: exactly one definer of the name in the build's own Ruby sources (`ClosedWorld#outside_ruby_paths`, the linked
  gems), with the model's owner, file and normalized body: `Numeric#-@` is `0 - self`
  (`mrblib/numeric.rb`), `String#%` is `args.is_a? Array` / `sprintf(self, *args)` / `sprintf(self, args)`
  (`mruby-sprintf/mrblib/string.rb`). A second definer (Complex's `-@`), an alias or a changed body turns the
  operator off.
* Native: every registration of the name is one the model lists, with the owner and function it names, and each
  registered wrapper's text, whitespace removed, is the one the patch writes. **A tree without the patch fails this
  pin and keeps the by-name helpers**; so does a tree where the patch's hunks moved the wrapper.
* The String arm of `-@` and `%` needs the gem that holds its exported body in `CodeGen.build_gem_names` (the scan
  reads the sources it is given, a build's link line decides what exists); without it the operator stays by name. A
  `%` world without sprintf's Ruby has no String#% at all, so its helper closes without the arm.
* `definers(op)` has no engine Ruby, module or singleton definer, and `members(op)` is inside the owner set
  (`numeric_slow_inherits_owner?`, as ADR 0360).
* The String arm of `%` mirrors `args.is_a?(Array) ? sprintf(self, *args) : sprintf(self, args)` as C, so `is_a?`
  and `sprintf` must be the one native each (kernel.c `mrb_obj_is_kind_of_m`; sprintf.c `mrb_f_sprintf`, pinned by text
  because `mrb_define_module_function_id` is not read by the registration scan, with exactly one registration),
  no Ruby, unknown or computed definition of either name (`kernel_native_dispatch_safe?`, `name_unrebound?`,
  `native_only_in?`), no declared class under BasicObject and no bytecode that names the constant BasicObject (an
  object without Kernel would raise where the mirror formats), and the constant `Array` bound by nothing but the
  core (`ClosedWorld#core_constant_plain?`: no SETCONST, one outside write, no nested class of that name).
* `-@` also needs `Integer#-` to be the native (`integer_ancestry_native?('-')`): `0 - self` is a send of `-` to 0
  for a bigint or any Numeric that is not an Integer or Float.

### The helpers

`bc2cpp_slow_mod`: an Integer or bigint is `mrb_int_mod_impl`, a Float `mrb_flo_mod_impl`, a String the formatter
(`mrb_obj_is_kind_of(M, b, M->array_class)` selects the Array form; the elements are copied into a fresh Array first,
as the splat copies them, so a `to_s` that empties the argument Array cannot move them), every other receiver
`bc2cpp_nomethod_named`, which dispatches by name before it raises, so a wrong proof raises `closed-world proof
violated` (ADR 0262, 0275).

`bc2cpp_slow_neg`/`neg_f`: an Integer is the overflow-checked `0 - x` (`mrb_bint_sub_ii` on overflow, `RangeError
integer overflow` without bigint, as OP_SUB), a Float `0 - f` (so `-0.0` stays `0.0`), a String
`mrb_str_uminus_impl`, a bigint or any other Numeric `mrb_num_sub(M, 0, a)` (what `0 - self` sends to `Integer#-`),
every other receiver `bc2cpp_nomethod_named`.

The Integer and Float exports are core (`numeric.c`) and referenced strongly. The two gem exports
(`mrb_str_format_impl`, `mrb_str_uminus_impl`) are declared weak and the String arm tests the address: a libmruby
without the gem, which the shared gem-free check builds are, links the same generated code and a String falls to the
NoMethodError arm, exactly what that libmruby's interpreter answers (no String#% or String#-@ exists there). On a real
target the gem is in the gem list the closed world was proven for, so the test is always true.

Both keep the by-name copy under `#if defined(MRB_USE_COMPLEX) || defined(MRB_USE_RATIONAL)` (a libmruby that links
those gems has more definers than the scan lists); `BC2CPP_NUMERIC_SLOW_CLOSED=0` keeps it everywhere.

### Not closed, and why

* **`zero?`**: `Numeric#zero?` is `self == 0`. A receiver that is not an Integer or Float (`Numeric.new`, any Numeric
  subclass) dispatches `==` by name, and nothing in the world bounds which `==` that is (Comparable's Ruby, or a user
  definition), so a closed form would still hold a by-name call. The scan gap is real too (`members` is nil because
  `File.zero?` / `FileTest.zero?` are registered by `mrb_define_class_method_id`, which `class_registrations` does
  not attribute) and parsing it would at most add a singleton definer: it cannot close the helper, so the scan is
  not changed.
* **The Hash arm of `< <= > >=`**: `Hash#<` is Ruby (mruby-hash-ext) over `Enumerable#all?`, `Hash#each`, `Hash#key?`
  and `==` of the stored values. No native body exists to export, and a C mirror would either call `==` by name per
  element (no gain) or use `mrb_equal`, which short-circuits identical objects (an `==` that returns false for `self`,
  and NaN, answer differently). The arm stays by name; nothing that is not exactly equivalent was shipped.
* **`===`**: `Kernel#===` answers every object, so `members` is nil by construction. The helper's default arm
  receives Procs, Data objects (Regexp from mruby-onig-regexp, whose `===` is static in a gem this patch does not
  carry) and plain objects; the plain-object case is `mrb_equal` only while no Ruby `===` exists on any class of the
  receiver, which the registry could prove for engine classes, but the Data and Proc arms keep the by-name call, so
  no census gain comes of splitting it.

## Consequences

Measured with `scripts/bc2cpp_dynamic_site_census.rb` on the wio closed world (shipped pass), base `b4efe59e` (the
head of PR #2045, which carries ADR 0360-0364), the `#if` arm kept for Complex/Rational builds stripped from both
runs:

| | Before | After |
| --- | ---: | ---: |
| by-name calls held in helpers | 17 | 14 |
| generated callers of a helper that still holds a by-name call | 4,331 | 4,122 |
| `bc2cpp_send` in generated bodies | 2,306 | 2,306 |
| sites that can reach by-name dispatch (bodies + helper callers + 414 block + 30 funcall sites) | 7,081 | 6,872 (-3.0%) |

The generated method bodies are byte-identical to the base's; only `bc2cpp_slow_mod` (138 callers) and
`bc2cpp_slow_neg_f` (71) changed. A build that links Complex or Rational, a tree without the patch, and
`BC2CPP_NUMERIC_SLOW_CLOSED=0` keep the old helpers byte for byte.

Equivalence is run by `scripts/bc2cpp_numeric_slow_check.rb` (also `BC2CPP_NUMERIC_SLOW_ONLY=misc`): every helper is
called directly against the operator over every member class pair (Fixnum, heap Integer and bigint edges, `MRB_INT_MIN`,
zero divisors, Float NaN/-0.0/infinities, every sprintf directive class including the `%<a>` / `%{a}` / `%1$s` /
`%*d` forms, frozen strings, String and Array subclasses, Hash arguments with NaN values, an Array a `to_s` empties
mid-format, Numeric subclasses), compared as value, class, frozen-ness, identity with the receiver, exception class and
message, compiled against interpreted (about 9,000 answers per run and 8,900 direct cases), and the by-name call counts
are checked (0 for an owned receiver, 1 for the proof's dispatch). It runs at `mrb_int` 64, 32 (`BC2CPP_MRUBY_FULL32`)
and without bigint (`BC2CPP_MRUBY_NOBIGINT`), each also with `MRB_USE_COMPLEX` and `MRB_USE_RATIONAL` defined (the
by-name copies), plus a link of the closed forms against the gem-free core build. The libmruby builds are made from a
tree with every `patches/mruby-*.patch` applied in order (`scripts/bc2cpp_width_build.rb`, `docs/ci.md`). Six mutants of
the generator (the splat copy dropped, `Float#%` replaced by `fmod`, `-0.0` negated directly, `String#-@` dup-and-freeze,
the Array test inverted, the `MRB_INT_MIN` overflow dropped) each fail the check. `CoreMisc` has its own unit cases
(changed Ruby body, second definer, alias, unpatched wrapper, extra or opaque registration) and runs against the real
tree.

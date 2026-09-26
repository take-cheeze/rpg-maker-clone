bc2cpp: repair 238 hand-written registration symbols, and add the Integer
equality native expression

**The repair.** `sanitize`'s injective mangling (commit b26889d9 / 8ff84013)
renamed every operator- and predicate-named generated symbol, but only
`mruby-lcf-compiled/src/register.cxx` was updated with it. The other two, and
238 more names in the rpg2k file, still spelled the old `_`-collapsed names, so
all three translation units failed to compile:

  mruby-rpg2k-compiled/src/register.cxx:1181: error: 'Game__Picture_shown_' was
  not declared in this scope; did you mean 'Game__Picture_shown$3f'?

222 in mruby-rpg2k-compiled, 14 in mruby-rgss-compiled, 2 in mruby-lcf-compiled
-- every one a predicate (`#shown?`, `#erase!`, `#alive?`, ...), which is why
they were missed: the earlier fix only looked for operator names.

The replacements are derived from the real `CodeGen#cpp_name` (via the run's
own "compiled entry points" listing, which prints both spellings) rather than by
a text substitution, so the repair cannot disagree with the compiler. All three
register.cxx now compile clean.

**The addition.** `NAMED_TWIN_CALLS` adds `Integer#==` as
`mrb_bool_value(mrb_obj_equal(M, recv, BC2CPP_ARG0))`, guarded by the existing
exact-class chain. The registered body for `==` is `mrb_obj_equal_m`, which
reads its argument with `mrb_get_arg1(mrb)` -- out of the caller's VM frame --
so it cannot be called from a C++ call site, and the body-extraction path in
`analyze_exact_class_expressions` correctly refuses it. `mrb_obj_equal` is the
function that wrapper delegates to: MRB_API, exported, and frame-independent.
Note it returns `mrb_bool` (include/mruby.h:1390), not `mrb_value`, so the
`mrb_bool_value` wrapper the registered body uses is required -- assigning the
bare `mrb_bool` does not compile.

`+`, `-` and `*` were tried in the same table and emit ZERO sites:
`compile_send` consults it only behind `builtin_class_send_safe?`, which
requires that no registered definition of the name be one of the guarded
builtins, and for `+` the registered owner IS Integer (numeric.c's own ROM
table), so the gate can never pass. Those names also have no POLY left in this
program. They are not listed, so the table claims only the coverage it has.

Measured on the hot-only wio closed world, full compilation, core mrblib in the
world, `BC2CPP_NO_ONLY_OWNERS=1`: 640 Integer#== sites emit the direct call.
Object `.text` 3,912,660 -> 3,932,968 (+20,308, +0.52%) with POLY unchanged at
2353. This is a CPU trade, not a flash one, which matches every other guarded
devirtualization measured in this build.

`scripts/bc2cpp_*_check.rb`: 44 pass, 5 fail -- the same 5 that fail at the
commit this branch started from.

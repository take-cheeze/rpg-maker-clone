# Generated type tests

The numeric operators (`+`/`-`/`*`/`/` and the comparisons), the native-registration dispatch chains and
`Float#/` test a value's type with mruby's predicate macros (`mrb_integer_p`, `mrb_float_p`, `mrb_string_p`, ...)
rather than `mrb_type(v) == MRB_TT_*`. `CodeGen.type_test` (`tools/bc2cpp/codegen.rb`) picks the macro for an
`MRB_TT_` tag and keeps the `mrb_type` comparison for a tag that has none.

Both spellings mean the same thing under every boxing; `value.h` defines the predicates through `mrb_type` when a
boxing header does not define its own. Under word boxing, though, `mrb_type` is an inline function, and GCC stops
inlining it in large generated bodies: the optcarrot probe's binary had 844 out-of-line calls to it, one per tag
test, about 5% of the steady-state instructions. The word-boxing macros test the boxed word directly.

OWNER_SET_NATIVE_ARMS leaves out an arm whose guard already opens an `if` earlier in the method
(`codegen_owner_set_direct.rb`). The guard has to open the `if`: an operator's tag pair such as
`if (mrb_float_p(r2) && mrb_integer_p(r3))` contains the same text but tests something else.

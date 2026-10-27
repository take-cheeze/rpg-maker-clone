# Ivar proof scope: undefined rebinders and self-scoped computed writes

The whole-program ivar proof (`NUMERIC_IVAR_PROOF`, `tools/bc2cpp/codegen_numeric_ivars.rb`) answers which class
set each `@name` of a class family can hold. The class pools ([ADR 0296](adr/0296-bc2cpp-class-pools.md)), the
numeric operand facts and the LCF row flow all read it. The proof is sound only while every write to an ivar is
a `SETIV` it can see. So it turns itself off, for the whole program, when some code could write an ivar it
cannot see:

- a send that runs a block under another `self` (`instance_eval`, `define_method`, `eval`, ...) without a
  literal block, or such a name as a Symbol;
- an `instance_variable_set` or `remove_instance_variable` whose name is not a literal ivar Symbol.

Two of these turned the proof off for the optcarrot probe, and neither could write a tracked ivar:

1. `eval(File.read(...))` in `CPU#initialize` and `PPU#initialize` (the `--load-cpu`/`--opt-cpu` paths). The
   sealed probe has no mruby-eval, so no `eval` exists to call.
2. `opts.each { |id, val| instance_variable_set(:"@#{id}", val) }` in `Config#initialize`. The receiver is the
   implicit `self`, a `Config`.

## UNDEFINED_REBINDER

A rebinder or named-write send no longer counts when no definition can answer its name: the registry has no
definition, and no native source, outside Ruby source or computed installer can define it
(`ClosedWorld#invisibly_definable?`). Such a send raises NoMethodError. It may also reach a `method_missing`,
but that is Ruby the closed world compiles, and the same scan reads every send in it.

In practice this applies to `eval` in a build without mruby-eval. Every other rebinder is defined by mruby's
core.

## SELF_SCOPED_IVAR_WRITE

A computed `instance_variable_set` or `remove_instance_variable` sent to the implicit `self` (an `SSEND` in a
method or one of its blocks) writes an ivar of that `self`. That object is an instance of the method's
owner or of a class in the owner's family, the connected component of the class graph the proof groups ivars
by. The send now fails every ivar group of that family and leaves the other families proven.

It still turns the proof off when:

- the send's block may run under another `self` (a block handed to a rebinder);
- the owner is a singleton, a class body, the top level, or `Object`/`Kernel`/`BasicObject`, whose ivars
  every family can see;
- the receiver is explicit (`obj.instance_variable_set`), so it may be any object.

The typed embedded slots use the same scan through `foreign_written_ivar_facts`. They have no family scope
there, so a self-scoped computed write still demotes every typed slot, as before.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/numeric_ivar_scope_check.rb` generates a world with both sends and no
mruby-eval. It asserts that another class's Array ivar keeps its class pool, that the index read of that ivar
drops its class test, and that the self-written class gets no pool. The same world with mruby-eval's sources,
and a computed `instance_variable_set` on another object, keep the proof off. It also compares interpreted and
compiled runs.

## Measurement

These figures come from the optcarrot probe (Lan_Master, callgrind). Instructions per frame are the
difference between runs of 21 and 1 frames, divided by 20. Checksum `59662` at 180 frames is unchanged.
42 ivar class pools appear, against none before.

| Build | Instructions per frame | 1-frame run (startup) |
| --- | ---: | ---: |
| Before | 35,997,826 | 1,506,852,381 |
| After | 35,161,497 | 1,501,048,509 |

The gain is mostly the `@output_pixels << ...` push in `PPU#render_pixel`, now on an exact Array
(`render_pixel` and `bc2cpp_ary_push` together drop by 2.03M), and `CPU#run` (0.72M). GCC also stops inlining
`bc2cpp_ary_entry` into its callers, which gives back 1.65M as an outlined function. Many hot ivars (`@hclk`,
`@bg_pixels`) still have no pool. Their writers read constants or call methods the pools do not model, or they
are written in the resumable `main_loop`, which the numeric flow did not model until
[JMPUW_PLAIN](bc2cpp-numeric-jmpuw.md). `BC2CPP_POOL_DROP_REPORT=1` lists those causes.

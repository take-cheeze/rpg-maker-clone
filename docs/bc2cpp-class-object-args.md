# bc2cpp class-object arguments (CLASS_OBJECT_ARGS)

> **Historical record.** The `wio` build named here was removed; `closed` is its successor. Figures are as measured then.

Which classes a `klass.new(...)` builds when `klass` is a method parameter, and why that decides how many constructors
CONSTRUCTOR_POOLS (ADR 0313) can pool. The decision record is
[`docs/adr/0416-bc2cpp-class-object-arguments.md`](adr/0416-bc2cpp-class-object-arguments.md); this page is the
operator's view.

## What it changes

CONSTRUCTOR_POOLS pools the arguments of an `initialize` from the `Klass.new`, `super(...)` and rooted `new` sites that
reach it. A `new` whose receiver it cannot name withdraws every `initialize` that takes that many arguments. The typed
save records (`mruby-lcf/mrblib/save_typed.rb`) have two such sites, `Record#table` and `Record#rows`, both with two
arguments, so every two-argument constructor of the program was refused for that reason alone.

With the pass on, the receiver resolves to the class constants every caller of the helper passes
(`table 100, Title, :title`), the sites join the constructors they can reach, and the others are no longer withdrawn.

Measured on the shipped pass of the wio closed world (3rd/mruby patched as `cmake/build-mruby.cmake` does, host `mrbc`,
`LANG=C.UTF-8`, `scripts/bc2cpp/coverage_report.rb` with `BC2CPP_COVERAGE_KEEP_DIR`; kill switch off against on):

| | off | on |
| --- | ---: | ---: |
| constructors pooled (`CTOR ... pooled`) | 16 | 44 |
| constructors refused as `unresolved new with 2 arguments` | 28 | 0 |
| `bc2cpp_getidx(` callers | 1,956 | 1,807 |
| `bc2cpp_nomethod(` sites (a guarded fallback proven to be an error) | 279 | 401 |
| `bc2cpp_slow_*` callers | 3,310 | 3,305 |
| `mrb_funcall_with_block` sites | 379 | 378 |
| functions whose text changes | | 32 of 3,447 |

The generated C++ is byte-identical with `BC2CPP_CLASS_OBJECT_ARGS=0`.

## How to see it

* `== constructor pools (CONSTRUCTOR_POOLS) ==` on stderr prints `SITES ... param_named=N`: the number of `new` sites
  this pass resolved, and one `CTOR` line per constructor (`pooled` or the refusal).
* A site that stays unresolved keeps the old line, `CTOR X#initialize refused: unresolved new with N arguments (new at
  file irep:index)`, naming the `new` that withdraws it.
* `BC2CPP_CLASS_OBJECT_ARGS=0` turns the pass off.

## What it does not resolve

A class object stored in an ivar or a constant table (`[A, B].each { |k| k.new(x) }`), passed through a parameter with a
default, or handed to the helper by a call the closed world cannot enumerate (a Symbol, a splat, a name an outside source
calls). Those keep the receiver unresolved and the constructors withdrawn, as before.

Checks: `scripts/bc2cpp/class_object_args_check.rb` (host half on hand-built bytecode, generated-code half with MRBC) and
`scripts/bc2cpp/class_object_args_mutation_check.rb` (seventeen mutants of the conditions).

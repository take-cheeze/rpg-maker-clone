# Running the strict hint tier and its verify build

`BC2CPP_STRICT_HINTS` (ADR 0411) forces the whole-program class hints of a closed-world
build: the else arm of a guarded hint site, which dispatched by name, becomes

```
[RPG2k] hint violation: <Class>#<name> at <Owner#method (FAMILY)>
```

on `$stderr` followed by a raised `BC2cppHintViolation` (a `NoMethodError`). Default off:
with the variable unset, empty or `0` the generated code is byte-identical.

## Switch

| `BC2CPP_STRICT_HINTS` | forced families |
| --- | --- |
| unset, empty, `0` | none |
| `1` | `typed`, `element`, `ivar_accessor`, `mono_embed` (a receiver hint: layout, annotation, element) |
| `all` | those four plus `poly_small_n`, `poly_table`, `interface_table` (the candidate set of a name, receivers not traced) |
| `typed,ivar_accessor` | the listed ones (an unknown name aborts the run) |

`BC2CPP_STRICT_HINTS_PROVEN=1` restricts the tier to sites whose hint class has no
descendant in the closed world and whose name `nil` does not answer: the conservative
setting, for a first look at a program that has never been verified.

Every forced site carries `/* STRICT_HINT <family>: <name> */`, is printed on stderr as
`STRICT_HINT_SITE Owner#method -> name (FAMILY)`, and must be listed in
`tools/bc2cpp/strict_hints_reviewed.rb`; an unlisted site aborts the generator unless
`BC2CPP_STRICT_HINTS_UNREVIEWED=allow` (fixtures, measurement). Regenerate the list, once the
verify build below is clean, with `MRBC=... ruby scripts/bc2cpp/strict_hints_update.rb --write`.

## Verify build

`-DBC2CPP_NOMETHOD_VERIFY` (ADR 0275, `docs/bc2cpp-nomethod-verify.md`) also covers this
tier: reaching a forced site prints

```
bc2cpp: NOMETHOD_VERIFY: hint violation reached: <Class>#<name> at <Owner#method (FAMILY)>
```

and aborts, so a workload that finishes has reached no forced site wrongly. Build into a
fresh build directory:

```
BC2CPP_STRICT_HINTS=1 BC2CPP_STRICT_HINTS_UNREVIEWED=allow BC2CPP_NOMETHOD_VERIFY=1 \
  RPGMAKER_BC2CPP=1 cmake --build build-strict --target mruby_build
```

then run the real workloads against that binary: `scripts/rpg2k/boot_check.bash` (boot, map,
a battle, a battle played to the end), mruby's own `rake test` of the compiled gems, the
RPG2k game-logic checks that run in-engine, and optcarrot where it is compiled. A violation
is a wrong or incomplete hint: fix the inference or annotation, widen the hint class set if the
extra class is legitimate, or fix the Ruby. `-DBC2CPP_HINT_VIOLATION_DISPATCH` (compile time,
no regeneration) restores the by-name send silently to tell a wrong hint from another bug.

To compare the hints with what ran, generate with `BC2CPP_TRACE_PARAMS=1` as well and feed the
dumps to `scripts/bc2cpp/param_trace_report.rb` (ADR 0298): its second ranking lists a
static fact the run contradicts.

## Checks

`scripts/bc2cpp/strict_hints_check.rb` (generated code and a deliberately violated fixture on
real mruby, default, strict, verify and dispatch builds), `strict_hints_mutation_check.rb`
(16 mutants) and `strict_hints_reviewed_check.rb` (the list against the real wio closed world)
run in the nightly `strict-hints` shard (`docs/ci.md`).

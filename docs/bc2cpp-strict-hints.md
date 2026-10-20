# Running the strict hint tier and its verify build

`BC2CPP_STRICT_HINTS` (ADR 0419) forces the whole-program class hints of a closed-world
build: the else arm of a guarded hint site, which dispatched by name, becomes

```
[RPG2k] hint violation: <Class>#<name> at <Owner#method (FAMILY)>
```

on `$stderr` followed by a raised `BC2cppHintViolation` (a `NoMethodError`). Default on (ADR 0438):
with the variable unset or empty the receiver-hint families are forced; `0` is the byte-identical
baseline with the tier off.

## Switch

| `BC2CPP_STRICT_HINTS` | forced families |
| --- | --- |
| unset, empty, `1` | `typed`, `element`, `ivar_accessor`, `mono_embed` (a receiver hint: layout, annotation, element) |
| `0` | none (the byte-identical baseline) |
| `all` | those four plus `poly_small_n`, `poly_table`, `interface_table` (the candidate set of a name; forced only where no known class outside the set answers the name, ADR 0428) |
| `typed,ivar_accessor` | the listed ones (an unknown name aborts the run) |

`BC2CPP_STRICT_HINTS_PROVEN=1` restricts the tier to sites whose hint class has no
descendant in the closed world and whose name `nil` does not answer: the conservative
setting, for a first look at a program that has never been verified.

Every forced site carries `/* STRICT_HINT <family>: <name> */`, is printed on stderr as
`STRICT_HINT_SITE Owner#method -> name (FAMILY)`, and must be listed in
`tools/bc2cpp/strict_hints_reviewed.rb`; an unlisted site of the engine always aborts the generator
(there is no switch). A fixture program's sites are listed but are not the program the list reviews
(`tools/bc2cpp/review_scope.rb`). Regenerate the list with
`MRBC=... ruby scripts/bc2cpp/strict_hints_update.rb --write`; it reads the listing of a run that fails
only on the list. Writing is not a review: the verify build below is, and a site it reaches is a wrong
hint, fixed at its source.

## Verify build

`-DBC2CPP_NOMETHOD_VERIFY` (ADR 0275, `docs/bc2cpp-nomethod-verify.md`) also covers this
tier: reaching a forced site prints

```
bc2cpp: NOMETHOD_VERIFY: hint violation reached: <Class>#<name> at <Owner#method (FAMILY)>
```

and aborts. `-DBC2CPP_HINT_VIOLATION_LOG` (ADR 0428) is the survey mode: each distinct violation is
printed once as `bc2cpp: HINT_VIOLATION_LOG: <Class>#<name> at <site>` and the by-name send runs, so
one workload run lists every wrong hint.

bc2cpp compiles closed-world programs only (ADR 0466), and the closed world is built for
wio/maix/psp, none of which runs here. The sealed desktop host of ADR 0428
(`RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1`) and `scripts/bc2cpp/strict_hints_verify.bash`, which ran
the real workloads on it, were removed with every other open-world path: the desktop engine is the
plain mruby build. A verify run needs a closed-world target that can run the workloads. mruby's
`rake test` does not test the compiled gems (they are initialised by the dispatch, not by
`mrb_open`), and the CRuby checks never run compiled code.

A violation is a wrong or incomplete hint: fix the inference or annotation, widen the hint class
set if the extra class is legitimate, or fix the Ruby. A candidate-set family (`poly_small_n`,
`poly_table`, `interface_table`) keeps the dispatch when a known class outside the set answers the
name (`ClosedWorld#answered_outside?`), so on the wio world `all` forces what `1` forces.
`-DBC2CPP_HINT_VIOLATION_DISPATCH` (compile time, no regeneration) restores the by-name send
silently to tell a wrong hint from another bug.

To compare the hints with what ran, generate with `BC2CPP_TRACE_TYPES=1` as well and feed the
dumps to `scripts/bc2cpp/trace_types.rb report` (ADR 0298): its second ranking lists a
static fact the run contradicts.

## Checks

`scripts/bc2cpp/strict_hints_check.rb` (generated code and a deliberately violated fixture on
real mruby, default, strict, verify and dispatch builds), `strict_hints_mutation_check.rb`
(16 mutants) and `strict_hints_reviewed_check.rb` (the list against the real wio closed world)
run in the nightly `strict-hints` shard (`docs/ci.md`).

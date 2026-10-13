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
`tools/bc2cpp/strict_hints_reviewed.rb`; an unlisted site aborts the generator unless
`BC2CPP_STRICT_HINTS_UNREVIEWED=allow` (fixtures, measurement). Regenerate the list, once the
verify build below is clean, with `MRBC=... ruby scripts/bc2cpp/strict_hints_update.rb --write`.

## Verify build

`-DBC2CPP_NOMETHOD_VERIFY` (ADR 0275, `docs/bc2cpp-nomethod-verify.md`) also covers this
tier: reaching a forced site prints

```
bc2cpp: NOMETHOD_VERIFY: hint violation reached: <Class>#<name> at <Owner#method (FAMILY)>
```

and aborts. `-DBC2CPP_HINT_VIOLATION_LOG` (ADR 0428) is the survey mode: each distinct violation is
printed once as `bc2cpp: HINT_VIOLATION_LOG: <Class>#<name> at <site>` and the by-name send runs, so
one workload run lists every wrong hint.

The closed world is only built for wio/maix/psp, none of which runs here. The sealed desktop host
(`RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1`, test-only, RPG2000/2003 games only) is the same world with
the real engine around it:

```
RPGMAKER_BC2CPP=1 RPGMAKER_BC2CPP_CLOSED_WORLD_HOST=1 BC2CPP_STRICT_HINTS=all \
  BC2CPP_STRICT_HINTS_UNREVIEWED=allow BC2CPP_NOMETHOD_UNREVIEWED=allow \
  BC2CPP_NOMETHOD_VERIFY=1 BC2CPP_HINT_VIOLATION_LOG=1 BC2CPP_HOT_ONLY=0 \
  cmake --build build-strict      # configure once with cmake -S . -B build-strict -GNinja
ENGINE=build-strict/rpg_maker_clone scripts/bc2cpp/strict_hints_verify.bash
```

(`cp932_table`/`jis0208_table` as for any build without nix, see `scripts/wio/bc2cpp_measure.bash`.)
`BC2CPP_HOT_ONLY=0` compiles every method; leave it out for the shipped hot set, which also needs
`BC2CPP_KEEP_HAND_REGISTRATIONS` (the sealed host defines it, ADR 0428). The script runs boot,
map previews, battles played to the end, the editors and animations on the repo's test beds
(`scripts/download/nepheshel.bash`, `mtf-meido-action.bash`) and fails on any violation or abort.
mruby's `rake test` does not test the compiled gems (they are initialised by the dispatch, not by
`mrb_open`), and the CRuby checks never run compiled code.

A violation is a wrong or incomplete hint: fix the inference or annotation, widen the hint class
set if the extra class is legitimate, or fix the Ruby. A candidate-set family (`poly_small_n`,
`poly_table`, `interface_table`) keeps the dispatch when a known class outside the set answers the
name (`ClosedWorld#answered_outside?`), so on the wio world `all` forces what `1` forces.
`-DBC2CPP_HINT_VIOLATION_DISPATCH` (compile time, no regeneration) restores the by-name send
silently to tell a wrong hint from another bug.

To compare the hints with what ran, generate with `BC2CPP_TRACE_PARAMS=1` as well and feed the
dumps to `scripts/bc2cpp/param_trace_report.rb` (ADR 0298): its second ranking lists a
static fact the run contradicts.

## Checks

`scripts/bc2cpp/strict_hints_check.rb` (generated code and a deliberately violated fixture on
real mruby, default, strict, verify and dispatch builds), `strict_hints_mutation_check.rb`
(16 mutants) and `strict_hints_reviewed_check.rb` (the list against the real wio closed world)
run in the nightly `strict-hints` shard (`docs/ci.md`).

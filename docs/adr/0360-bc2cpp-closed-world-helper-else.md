# 0360. A numeric helper's else becomes a proven NoMethodError when only Integer and Float answer the operator

Date: 2026-10-05

## Status

Accepted

## Context

The shared helpers (`bc2cpp_slow_*` ADR 0292, `bc2cpp_getidx`/`getidx0`/`setidx` ADR 0216, `bc2cpp_eqq` ADR 0293)
hold 24 by-name calls that about 5,800 generated sites reach (`scripts/bc2cpp_dynamic_site_census.rb`, the
"by-name calls held inside shared helpers" table). A call site cannot prove anything about the else of a helper
shared by hundreds of sites, so the proof has to be about the world: which classes can answer the operator at
all. `CallFacts::Answers#members(name)` (ADR 0317/0323) already computes that from the registry, the outside Ruby
sources, the native registrations and the lookup paths of the core classes, and is nil for a name nothing bounds.

Its answer for every helper name in the wio closed world (all three compiled gems, `SKIP_UNSUPPORTED=1`):

| Helper | Classes that may answer | By-name arm needed for |
| --- | --- | --- |
| `/` | Integer, Float | nothing else |
| `>>` | Integer | operand coercion (`mrb_as_int`, `MRB_INT_MIN`) |
| `round` | Integer, Float | `flo_round` (static) |
| `^` | Integer, nil, true, false | the three object.c bodies |
| `+` `-` `*` | Integer, Float, Array, String (and Time `+` `-`: the scan includes mruby-time, which wio does not link) | Array/String/Time bodies, all static |
| `<` `<=` `>` `>=` | Integer, Float, Numeric, String, Symbol, Hash (Comparable and Hash#< are Ruby in mruby's mrblib) | Comparable includers |
| `%` `&` `\|` `<<` `-@` | Array, String, IO, Tee, true/false/nil, Numeric ... | static bodies or Ruby definers |
| `zero?` `===` | unbounded | |
| `[]` `[]=` | 8 registry classes plus Array, Hash, String, Struct, Proc, Method, MatchData, Table | static bodies |

Only `/` has no definer outside what the helper already runs.

## Decision

`bc2cpp_slow_div` is emitted in a closed form when `CodeGen#numeric_slow_closed?('/')` holds: a closed world with no
global refusal, `exact_instances_singleton_free?`, no `method_missing` class, `Answers#definers('/')` bounded with
no Ruby, module, foreign Ruby or singleton definer, and `Answers#members('/')` a subset of `{Integer, Float}`. The
body is then `int_div` (Integer or bigint receiver; a non-numeric operand raises `can't convert %Y into Integer`,
its `default:` arm), `flo_div` (Float receiver) and `bc2cpp_nomethod_named` for every other receiver. A world that
fails the test, a user class answering `/` (the fixture's `NsBox`), and `BC2CPP_NUMERIC_SLOW_CLOSED=0` keep the
old helper byte for byte.

Soundness:

* The else is reached only by a receiver outside Integer/bigint/Float. `members` says no other class can answer
  `/`: every definer source is covered (registry defs, foreign Ruby, native registrations parsed from the ROM
  tables, mixins through `lookup_path`/`ancestors`, `method_missing` classes, computed installers and Object/Kernel
  definers make it nil). `bc2cpp_nomethod` is the existing proven-dead arm: it dispatches by name first, so a wrong
  proof raises `RuntimeError: closed-world proof violated` instead of running the wrong code (ADR 0262, 0275).
* `int_div`'s operand switch has `Complex` and `Rational` arms under `MRB_USE_COMPLEX`/`MRB_USE_RATIONAL`, which the
  gems define. The scan would list those gems as `/` definers, so the closed form never applies to a world that
  has them; the helper also keeps the old by-name body under `#if defined(MRB_USE_COMPLEX) ||
  defined(MRB_USE_RATIONAL)`, so a libmruby that links those gems behaves as before even when the scanned world
  did not list them (the full-core test builds define `MRB_USE_COMPLEX`).
* Float receivers do not arrive here from the `FLOAT_DIV_RECEIVER` arm, but the helper answers them anyway so it
  does not depend on its callers.
* The helper is outside the `NOMETHOD_REVIEWED` list: that list is per generated method, and the marker is not
  emitted for helpers.

## Consequences

Measured with the census script on the wio closed world (shipped pass), base `0a9adfc`:

| | Before | After |
| --- | ---: | ---: |
| by-name calls held in helpers | 24 | 23 |
| generated callers of a helper that still holds a by-name call | 5,781 | 5,509 |
| `bc2cpp_send` in generated bodies | 2,408 | 2,408 |
| sites that can reach by-name dispatch (bodies + helper callers + block + funcall sites) | 8,636 | 8,364 (-3.1%) |

All 272 are removals. The other helpers need a body per static core method (`Array#+`, `String#*`, `Array#&`,
`Hash#<` ...) or a Comparable includer analysis before their else can go; that is follow-up work and the table
above says where each one stands. `scripts/bc2cpp_numeric_slow_check.rb` runs the closed helper against
`Integer#/`/`Float#/` over a matrix of numeric, nil, true, String, Symbol, Array, Hash, Range, class and user
operands on both receiver and operand side, compiled and interpreted.

# 0419. Strict hints: a wrong class hint fails loudly instead of costing a by-name send

Date: 2026-10-12

## Status

Accepted

## Context

A guarded hint site is `if (class guard) direct-call else bc2cpp_send(...)` (ADR 0210: the
class comes from whole-program facts, not proofs). The else arm is kept because a hint can be
wrong or incomplete. Measured on master (`scripts/bc2cpp/coverage_report.rb`, wio closed
world, all three gems) about 1000 of the live `bc2cpp_send(M` sites are such else arms.
ADR 0290 turned the else arms of *proven* guards into `bc2cpp_guard_violation` and left the
hint guards alone: a violation there reaches a correct program with a subclass or another
class, and the dispatch is right.

The request behind this ADR reverses the default for hints: replace the by-name fallback
with a runtime error broadly, run the real workloads, and treat every caught violation as a
wrong or incomplete hint to fix at its source (correct the inference or the annotation,
widen the hint's class set when the extra class is legitimate, or fix the Ruby). A wrong
hint then costs a loud failure, never speed, and the by-name sites disappear from the output.

## Decision

`BC2CPP_STRICT_HINTS` (default on since ADR 0438: unset or empty select `1`; `0` emits byte-identical code, checked)
selects the families whose else arm becomes `bc2cpp_hint_violation`:

| family (`STRICT_HINT` marker, site tag) | the hint | forced when |
| --- | --- | --- |
| `typed` (`TYPED`, `CLOSED_WORLD_TYPED_INHERITED`) | receiver class traced from a ClassLayout ivar fact, a ClassAnnotations argument, a class pool or a capture hint | the guard's else was a by-name send |
| `element` (`TYPED/ELEMENT`) | element hint of an inlined loop parameter | same |
| `ivar_accessor` (`IVAR_ACCESSOR`, ADR 0382's typed slots included) | the same hints, for attr_reader/attr_writer | same |
| `mono_embed` (`MONO_EMBED_GUARD`) | only when a layout, annotation or element hint also names the owner (`strict_hint_names?`) | same |
| `poly_small_n` (`POLY_SMALL_N`, `INHERITED_GUARD`) | the candidate set of the name | same |
| `poly_table` (`POLY_TABLE`), `interface_table` | the table's class set | same |

Mechanism (`CodeGen#strict_hint_wrap`): the chain's ordinary else is built first; only its
*terminal by-name send* is replaced, so the native and singleton arms in front of it keep
answering their receivers, and a chain whose else is already `bc2cpp_nomethod` (a proven-dead
arm, `NOMETHOD_REVIEWED`) is left alone because there is no send to force. `rN =
bc2cpp_hint_violation_named(M, recv, "name", "Owner#method (FAMILY)", argc, ...)` carries
`/* STRICT_HINT family: name */`. SymbolCache indexes it like `bc2cpp_guard_violation`.

Runtime (`bc2cpp_hint_violation`, out of line): logs `[RPG2k] hint violation:
<Class>#<name> at <Owner#method (FAMILY)>` to `$stderr` and raises `BC2cppHintViolation <
NoMethodError`, never dispatching and never undefined behaviour.
`-DBC2CPP_NOMETHOD_VERIFY` aborts naming class, name and site (the same build flag as ADR
0275); `-DBC2CPP_HINT_VIOLATION_DISPATCH` restores the silent by-name send without
regenerating, to tell a wrong hint from another bug.

Review gates, mirroring `NOMETHOD_REVIEWED`: every forced site is marked, printed on stderr as
`STRICT_HINT_SITE Owner#method -> name (FAMILY)` with per-family counts, and must be listed
in `tools/bc2cpp/strict_hints_reviewed.rb` or the generator aborts (no switch; fixture programs
are outside the reviewed scope, `tools/bc2cpp/review_scope.rb`). As with ADR 0290's
sites, which of these exist depends on which callees compile, so a hot-only run is held to
"every site is listed" only, and `strict_hints_reviewed_check.rb` proves exact equality over
the full (not hot-only) run. The existing NOMETHOD, PROVEN_MISS and guard-violation gates are
not touched.

`BC2CPP_STRICT_HINTS_PROVEN=1` is the conservative setting: force only owners with no
descendant in the closed world and names `nil` does not answer, so a legitimate subclass or
nil receiver cannot reach the error. The default does not gate on proofs, by the policy of
this ADR.

### Left out, and why

- **Numeric arms** (Fixnum/Float/Integer/Bignum, overflow and promotion): a legitimate flow
  on the slow-path helpers (ADR 0292), not a hint.
- **Outlined index helpers** (`INDEX_CLOSED`, `getidx`/`setidx` by-name helpers): emitted
  outside any compiled method, where the site name is never resolved and the marker is
  never read; `without_strict_hints` keeps their dispatch.
- **Literal-block sites and argument lists over 16**: the violation helper carries neither.
- **Core owners as hint class** (`Array`, `Hash`, `String`, ...) for the typed families.
- **Exact core-type guards** (`mrb_array_p(x) && x->c == M->array_class` ... with a send
  else), **native exact-class arms** and **class chains of kept reason**: see Consequences for
  the measured counts and the evidence on why they are not forced.

## Consequences

Measured on the wio closed world, all three gems, the shipped (`SKIP_UNSUPPORTED`) codegen of
`scripts/bc2cpp/coverage_report.rb` at master 5ead3a77, counted with the marker-attributing
counter used for ADR 0290:

| | default | `BC2CPP_STRICT_HINTS=1` | `BC2CPP_STRICT_HINTS=all` |
| --- | ---: | ---: | ---: |
| live `bc2cpp_send(M` | 1,837 | 1,793 (-44) | 1,637 (-200) |
| live `mrb_funcall*` | 386 | 387 (+1, the helper's `$stderr` puts) | 387 |
| `bc2cpp_hint_violation` sites | 0 | 45 | 210 |

Forced sites per family (`all`; `1` is the first four rows, 45 sites): `IVAR_ACCESSOR` 25,
`TYPED` 19, `ELEMENT` 1, `MONO_EMBED_GUARD` 0, `POLY_SMALL_N` 134, `POLY_TABLE` 31, interface
tables 0. The sends the tier removes, by the marker of the site that carried them:
`POLY_SMALL_N` 114 -> 21, `IVAR_ACCESSOR` 26 -> 1, `TYPED` 17 -> 7, `NATIVE_DIRECT` 40 -> 8,
`NATIVE_OWNER_MAP` 246 -> 229, `INHERITED_GUARD` 19 -> 0, `NATIVE_CORE_DIRECT` 243 -> 240. The
default output is byte-identical to master (`cmp` of the kept `shipped.cxx` of the same coverage run on master and on this branch: identical, 21,550,689 bytes);
`g++ -fsyntax-only` accepts the strict output.

The first measurement forced every hint chain, including the ones that already ended in
`bc2cpp_nomethod`: 3,527 sites and only the same 200 sends fewer, because 3,300 of them
replaced a proven-dead arm (`NOMETHOD_REVIEWED`) that is already an error and has no by-name
send. `strict_hint_wrap` therefore forces only a chain whose terminal else is a by-name send.

What remains of the 1,637, and why it is not forced:

| marker | live sends | reason it stays |
| --- | ---: | --- |
| `NONE`, `POLY` | 623 + 423 | no class guard at all: a by-name send on a receiver nothing traces. There is no hint to force |
| `NATIVE_CORE_DIRECT`, `NATIVE_OWNER_MAP`, `NATIVE_DIRECT` | 240 + 229 + 8 | else arms of exact core-type guards (`mrb_array_p(x) && x->c == array_class`). 547 sends in the unforced core-type chains of the default output: 423 of them (77%) are names (`empty?` 193, `size` 132, `update` 37, `key?` 20, ...) that engine Ruby classes (`Game::*`, `LCF::*`, `RGSS::*`) also define, so a user class is a legitimate receiver of the else arm, and the receiver is untraced, so there is no class to name in an error |
| `CLOSED_WORLD_STABLE_CLASS`, `..._CONSTANT_OBJECT`, `..._SELF` | 39 + 7 + 3 | module/constant-object arms; the else is the by-name call on an object the proof is about |
| `POLY_SMALL_N`, `TYPED`, `IVAR_ACCESSOR`, `MONO_EMBED_GUARD` | 21 + 7 + 1 + 4 | literal-block sites, calls with more than 16 arguments, sites inside outlined helpers |
| `MONO`, `LEXICAL_SELF`, ... | about 30 | no guard (a single definition), the send is the call itself |
| numeric arms | in `NONE` | Fixnum/Float/Bignum/overflow are a legitimate flow (ADR 0292) |

Verify on the real workloads: **not run, so zero violations is not claimed.** The sandbox this
was written in had 1.3 GB of free disk and a load of 25-40 from concurrent jobs; the engine
build `boot_check.bash` needs (about 700 ninja steps, 1.1 GB, an hour and three quarters on an
idle machine) did not fit, and the coverage run alone took 1 to 2 hours. What was run: the
fixture check on real mruby (a deliberately violated annotation: default dispatches and
answers what the interpreter answers, strict logs and raises `BC2cppHintViolation`, verify
aborts naming the site, dispatch answers again), the mutation check (16 of 16 mutants killed)
and `g++ -fsyntax-only` of the whole strict output. The violations found on the real
workloads are therefore 0 *run*, not 0 *proven*; the tier is off by default for that reason,
`docs/bc2cpp-strict-hints.md` is the procedure, and the first CI/nightly run that does it
decides which sites in `tools/bc2cpp/strict_hints_reviewed.rb` are wrong hints to fix and
which family to drop.

Trade of each family. `typed`, `element`, `ivar_accessor`, `mono_embed` read a receiver
class that a ClassLayout ivar store, an annotation or an element hint names; a violation is a
wrong store/annotation or a legitimate subclass or `nil` (`PROVEN` removes those two). They
are what `1` selects. `poly_small_n`, `poly_table`, `interface_table` use the candidate set of
a name as the hint, so every receiver outside it is an error: 134 + 31 sites whose else arm
was kept for a reason (`core_or_native`, `singleton_definer`, `unlisted_class`) that says
something outside the set answers. They are only in `all` and are not claimed clean until the
verify build has run the workloads.

Residual risk: a hint that is wrong only on a path no workload takes. The default tier is
therefore off, the reviewed list names every site, and `-DBC2CPP_HINT_VIOLATION_DISPATCH`
turns the tier into the old dispatch without regenerating.

## Verify

See `docs/bc2cpp-strict-hints.md`. `scripts/bc2cpp/strict_hints_check.rb` (nightly
`strict-hints` shard) compiles a fixture whose annotations are deliberately violated and
asserts: default build dispatches and answers what the interpreter answers; strict build logs
and raises `BC2cppHintViolation`; verify build aborts naming the site; dispatch build answers
again. `strict_hints_mutation_check.rb` kills 16 mutants of the tier's conditions.

## Addendum

The verify run was done on a sealed desktop host and changed the candidate-set families: see ADR 0428.

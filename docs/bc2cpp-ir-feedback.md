# IR type feedback and RBS suggestions

The type-check workflow now connects RBS contracts, bytecode IR facts and
reviewable RBS suggestions. It retains nominal contracts for required
arguments, ivars and method returns, including nullable and union types.
Ivar reads and implicit calls on `self` use the applicable owner/ancestor
contract. An ordinary explicit receiver with known nominal bounds can also use its
return contracts. An unknown receiver does not inherit a return contract
merely because its method name matches; an existing complete compiler proof
can independently establish its result. See [call-result propagation](bc2cpp-ir-call-results.md).

```sh
ruby scripts/bc2cpp/type_check.rb --files game.rb --sig sig/bc2cpp \
  --format json --out coverage/ir-types.json \
  --emit-rbs-suggestions coverage/rbs-suggestions

# Review the candidate files, then check them against the same sources.
ruby scripts/bc2cpp/type_check.rb --files game.rb \
  --sig coverage/rbs-suggestions --all
```

Set `MRBC` to the host compiler path when it is not on PATH. Use an absolute
path when invoking the script from another directory. Candidate files are
written only to the requested output directory; source signature files are
not updated automatically; an accepted candidate is copied in by the reviewed
[promotion step](bc2cpp-promote-candidates.md). As with `--emit-rbs`, candidates also retain the
existing parameter, ivar, constant and method inventory. Existing types come
from the standard whole-program facts; independently inferred IR returns
replace return declarations in the candidate copy, including contradicted
ones. This is a review workflow, not an automatic fixed-point rewrite.

## Feedback

JSON includes `ir_feedback` rows for method exits, ivar stores and explicit
call receivers. Each row records its source location, type, expected contract,
contract provenance and refusal reason. Statuses distinguish:

| Status | Meaning |
| --- | --- |
| `inferred` | The IR answer needs no RBS assumption |
| `declared` | The answer depends on argument, ivar or self-call contracts |
| `unknown` | No complete answer; `reason` names the unknown producer or dataflow refusal |
| `mismatch` | Every class in the inferred may-set falls outside the nominal contract |
| `possible_mismatch` | The may-set contains both allowed and excluded classes; feasibility/refinement is unresolved |

Text output summarizes statuses and lists inferred return suggestions. Unknown
queries are ranked by `reason`, most frequent first (ties by name), and each
reason lists the files it hits, so the top entry names the next producer worth
modeling. The ranking is text-only; JSON keeps its shape. `--all` adds
location-based unknown-query notes (`TC2004`).
Wholly incompatible inferred returns or ivar stores produce errors (`TC1007`);
partly overlapping sets produce warnings (`TC1008`). Subtype compatibility
uses the program hierarchy, recorded mixins and the primitive classes' core
ancestry. Missing module or external-type relations leave `compatibility`
unknown instead of creating a mismatch. These
checks are static feedback; they do not add runtime enforcement.

Each emitted candidate method has one provenance comment above its `def`, for
example `# bc2cpp: return from lib/x.rb:42 (inferred)`. It names the deciding
IR exit (the first exit row, or the first contract-dependent one for a derived
return), the return's source and status, and up to three contracts a derived
return depends on. A method with no exit row names its definition instead. The
comments are documentation only: RBS parses the candidate to the same types
with or without them.

JSON's `rbs_suggestions` lists return types only when every modeled exit has
an independently inferred answer. Contract-assisted or unknown exits cannot
produce an independent suggestion. New union-return facts also improve normal
`--emit-rbs` output when the existing return analysis has no answer.

Complete contract-assisted return bounds appear with source `derived:contracts`
and retain their dependency list. They are not independent RBS suggestions.

## Runtime evidence

Checking a candidate with `--all` against the same sources cannot catch an
over-claimed suggestion: it reruns the inference that wrote the candidate. Runtime
evidence is the independent check. `scripts/bc2cpp/rbs_suggestion_trace_check.rb`
compares a candidate directory with `BC2CPP_TRACE_TYPES` dumps (the rows
`trace_types.rb` reads, see [trace merge](bc2cpp-trace-merge.md)) and prints one
`[TRACE_CONTRADICTION]` line per contradiction:

```sh
bundle exec ruby scripts/bc2cpp/rbs_suggestion_trace_check.rb \
  coverage/rbs-suggestions param_trace.tsv --hierarchy hierarchy.tsv
```

It exits 0 when every compared site is admitted, 1 on a contradiction and 2 on
bad input. `--hierarchy` takes the `class_hierarchy.rb` rows of the program
sources. With no arguments it runs its fixture self-test, which is what the
`ruby-checks` coverage list runs. Use `bundle exec` locally: the core hierarchy is
read by the pinned RBS 4.

Compared: each required positional parameter (trace kind `req`, matched by
position) and each method return, except `initialize`. A site is skipped when it
was not reached or its class table overflowed, since its classes are then unknown.

A class is a contradiction only where the lookup order is complete: a core class
(from `CoreHierarchySigs`), or a program class whose superclass chain reaches a
core class through `--hierarchy`. Modules are never decided, because a program may
include one into a core class. Everything else is reported as undecided in the
summary. A passing run is evidence about one recorded run, not a proof.

The trace cannot tell the check these things, so they are not compared:

- singleton methods (`trace_types.rb` keys methods by `Owner#name` and drops the rest);
- optional, rest and keyword parameters: this check does not match their trace
  rows (an optional parameter may carry a call-site type, see above);
- ivar and constant types, which are not traced;
- array elements and hash keys and values: the `PARAM_ELEM_*` rows exist, but
  `TraceTypes::Candidates.read_dumps` does not read them;
- module-versus-class kind and mixins for program code: `class_hierarchy.rb`
  records superclasses and methods only.

## Optional parameters

An optional parameter takes its type from the call sites the same way a required
one does, with one extra condition: every reaching call must pass it. A call that
stops short binds the default, and the call-site join says nothing about that
value, so the parameter stays `untyped` (`?untyped` in RBS). When every reaching
call passes it, the join is the parameter's type: `--emit-rbs` writes `?Integer`
(parenthesized when it is a union), the JSON `optional_params` row carries it with
source `inferred:receiver-call-sites`, and the body analysis uses it as an argument
fact. A declared optional type (`ir_optional_types` from a signature) still takes
precedence. The result holds under the closed-world assumption bc2cpp already
makes: no call the program can make omits the argument, so the default is never
bound. Methods with rest, post, keyword or block parameters get no optional
join, and a required parameter of a method that also takes optional parameters
still has no call-site type (its join needs the required-only shape).

## Boundaries

Facts remain nominal when declared; they cannot prove exact dispatch or
native representation. Inference may over-approximate infeasible paths, so
mixed sets are warnings rather than definite errors. Handler and closure
barriers, frame clobbers and traversal budgets still refuse queries.

Shared IREPs with ambiguous owners get no owner-specific contracts. Cyclic
hierarchies supply no inherited contracts. Rest, keyword and block
contracts, required parameters of methods with optional ones, unknown receiver
contract lookup, module mixin contract lookup, constants and nonlocal-return
inference remain follow-up work. Inferred ivar candidates (`@ivar: T` in the
type-check RBS, and the `ivars` rows of the facts file) are the union of every
traced store across the ivar's numeric family: superclass, include and prepend
links, since all of them share the slot. The candidate gains `nil` when some
read may run before any store: a `@x = nil` store, or a reading owner that
`numeric_ivar_assured?` does not clear. That check needs a closed world with no
`allocate` and a #initialize that assigns on every path before `self` escapes;
where it cannot decide, `nil` is included. A store the analysis did not resolve,
or an ivar touched by code no class owns (a module body), leaves the candidate
unknown. The runtime layout is still the layout analysis's; only the candidate
that is written and compared changes. Inferred ivar types
continue to come from the existing whole-program layout analysis; observing
one store does not establish the complete type of an ivar.

Run the signature, type-check and RBS-export checks with a host `MRBC`. The
fixture suites compare guarded dispatch with `BC2CPP_STRICT_HINTS=0`.
See [ADR 0442](adr/0442-bc2cpp-ir-contract-feedback.md).

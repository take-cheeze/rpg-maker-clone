# IR type feedback and RBS suggestions

The type-check workflow now connects RBS contracts, bytecode IR facts and
reviewable RBS suggestions. It retains nominal contracts for required
arguments, ivars and method returns, including nullable and union types.
Ivar reads use the applicable owner/ancestor contract. An implicit call on
`self` joins the contracts of every receiver class the program bounds (see
**Implicit self-calls** below). An ordinary explicit receiver with known nominal bounds can also use its
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
ones. This is a review workflow; the default run does not feed its candidates back.

## Fixed-point rounds (`--iterate N`)

A return whose exits are derived through a callee's contract (`derived:contracts`)
is not a suggestion in a single run: the callee's return is only a contract once
it is declared. `--iterate N` closes that loop, opt-in and off by default:

```sh
ruby scripts/bc2cpp/type_check.rb --files game.rb --iterate 5 \
  --emit-rbs-suggestions coverage/rbs-suggestions
```

- Round 1 runs the analysis under `--sig` alone and accepts the returns it can
  infer from bytecode. Round `r` runs again with the round `r-1` accepted set as
  one more signature directory, written to a scratch directory.
- The loop stops when a round accepts exactly what it was given (converged), or
  after `N` rounds (not converged). The report prints the round count and whether
  it converged; with `--emit-rbs-suggestions` the candidates are written only when
  the set converged. A non-converged set is not written, because its derived
  types were computed under contracts from an earlier round.
- Each round's candidates replace the previous ones rather than accumulating:
  a suggestion whose contract was withdrawn cannot survive as a stale contract.
- The candidate directory of a round holds only the accepted methods: parameters
  are untyped, and there are no ivars or constants. Nothing else can become a
  contract in a later round, including a derived type that was not accepted.

**Acceptance rule.** A derived exit is accepted only when every contract it
depends on is a return contract (`self-call:NAME` or `call-result:OWNER#NAME`)
naming a method accepted in the previous round. Parameter, ivar, keyword and
element contracts keep the method out, including those in your own signatures.
That is stricter than the single-run workflow, which only omits the method.
`self-call:NAME` names no owner, so it is accepted only when some previous-round
method has that name and no user declaration does. A method the user already
declares keeps its declaration and is never a suggestion. The rule is enforced in
`accepted_exit?` and `return_contract_accepted?` in `tools/bc2cpp/type_check_iterate.rb`.

**Cycles.** Round 1 has no candidates, so a derived exit cannot exist there and
only inferred returns are accepted. Every later round is built from the previous
one, so each accepted return traces back to an inferred exit or a user contract.
Two methods whose returns depend only on each other (A on B, B on A) are never
accepted from nothing; the loop converges in one round with neither. The loop stops
only when a round reproduces its own input.

Not verified here: the end-to-end run needs the host `mrbc`. The loop and its rule
are exercised by `scripts/bc2cpp/type_check_iterate_check.rb` against a model of the
analysis, not the real one.

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
partly overlapping sets produce warnings (`TC1008`), unless trace evidence
applies (below). Subtype compatibility
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

### Trace evidence

`type_check.rb --trace CANDIDATES.rbs` takes the candidates that
`scripts/bc2cpp/trace_types.rb candidates` writes from `BC2CPP_TRACE_TYPES`
dumps. A `possible_mismatch` return row whose method the trace observed only
inside the contract is reported as `TC1009` (info), not `TC1008` (warning). The
row gets `provenance: "trace"` and `trace_classes`, and its status stays
`possible_mismatch`: a trace run is evidence from one run, not proof, so it
never becomes `inferred` or `declared`.

The join is by method (owner and instance method name). The trace records no
file or line for a return, and the candidates leave out overflowed sites and
untyped, interface or generic returns, so only a complete observation counts.
Nil and bool in the candidates count as NilClass and TrueClass plus FalseClass;
an expectation must name every such class. `mismatch` rows, ivar stores, block
rows and singleton methods are never changed by trace evidence, so a class the
static analysis excludes still raises `TC1007`. The implementation is
`tools/bc2cpp/ir_trace_evidence.rb`; `scripts/bc2cpp/ir_trace_evidence_check.rb`
is the host-only fixture check.

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

Compared:

- each required positional parameter (trace kind `req`, matched by position) and
  each method return, except `initialize`;
- the elements of a parameter or return declared `Array[T]` or `Hash[K, V]`: the
  `PARAM_ELEM_*` and `RETURN_ELEM_*` rows, by role (`array`, `key`, `value`);
- singleton methods (`def self.x`), against the trace key `Owner.singleton#x`;
- a module method, against the observations of each class that includes the module.
  The class must be known to include it through `--hierarchy`; without that file the
  observations are counted as undecided.

A site is skipped when it was not reached. An overflowed site (its class table was
full, so its classes are unknown) is not compared; the summary counts every
overflowed site and element slot in the trace, declared or not.

A class is a contradiction only where the lookup order is complete: a core class
(from `CoreHierarchySigs`), or a program class whose superclass chain reaches a
core class through `--hierarchy`. A module is never a contradiction. A class that
includes a module the candidate declares is admitted, anything else is undecided.
A module method's observation on a class is accepted only when the lookup reaches
the module before any other definer of the name; a core class in front of the
module, or a native mixin, makes it undecided. Everything else is reported as
undecided in the summary. A passing run is evidence about one recorded run, not a
proof.

`--hierarchy` takes the rows `class_hierarchy.rb` writes: `CLASS`/`MODULE`,
`SUPER`, `INCLUDE`/`PREPEND` (in application order) and `DEF` (including
`define_method`, `alias` and `attr_*` names, and `*` for a computed name). The
mixin rows come only from the sources it is given. A mixin it does not see (a file
left out, an `included` hook, a `class_eval` string) leaves that class's module
observations uncompared: a missed check, never a false failure.

The trace cannot tell the check these things, so they are not compared:

- the receiver of a singleton method: `self` is not traced, only its arguments and
  returns;
- a singleton method reached through `extend` (the module's instance methods become
  the extending class's singleton methods, which the trace keys as
  `Owner.singleton#x`; the check does not model it);
- optional, rest, keyword and block parameters: this check does not match their
  trace rows (an optional parameter may carry a call-site type, see above);
- ivar and constant types, which are not traced;
- overloaded methods, which the candidate reader skips;
- container elements past the first eight of each container (`BC2CPP_ELEM_SAMPLE`):
  the dump does not record them, so a wrong class there is not seen.

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

## Rest, keyword and block parameters

These three kinds take their type from the complete call-site join as well, each
under its own condition. The join is taken only when the reaching call sites are
all known (a dynamic, foreign or poisoned name gets no join at all).

- **Rest** (`*rest`): the element type is the join of every extra argument over
  the reaching calls. RBS writes `*T` (the body sees `Array[T]`); the JSON
  `rest_param` row carries `T`. A call that passes keywords refuses the join, and
  so does a call that passes no extra argument at all (there is no element to
  type). A rest parameter next to keyword parameters gets no join.
- **Required keyword** (`k:`): the join of the value passed for `k` at every
  reaching call. Each call must pass `k` as a literal keyword pair; a call that
  omits it, or passes keywords through `**splat`, refuses the join. RBS writes
  `k: T`. An optional keyword stays `?untyped`.
- **Block** (`&blk`): the block is `Proc` only when every reaching call passes a
  literal block or lambda (`BLOCK`/`LAMBDA` producer in the block slot). A call with
  no block binds `nil`, and a Proc from a variable, a `proc` call or a `&` pass-through
  is not recognized, so each refuses. A block typed `Proc` is written as a required
  block (`{ (*untyped) -> untyped }`); otherwise the block stays optional. A declared
  block signature keeps its optional block.

The body analysis does not yet consume these joins: the candidate RBS and the JSON
rows carry them, and the IR argument facts still cover positional parameters only.
`BC2CPP_IR_ARGUMENT_TYPES=0` restores `untyped` for all three.

## Boundaries

Facts remain nominal when declared; they cannot prove exact dispatch or
native representation. Inference may over-approximate infeasible paths, so
mixed sets are warnings rather than definite errors, and trace evidence only
lowers them to notes. Path-sensitive narrowing is not applied to these rows:
`NilNarrowing` feeds the parameter checks, not the IR type query. Handler and closure
barriers, frame clobbers and traversal budgets still refuse queries.

Shared IREPs with ambiguous owners get no owner-specific contracts. Cyclic
hierarchies supply no inherited contracts.

**Mixin lookup.** A return contract is found through the owner's mixin chain:
included and prepended modules, nested includes, and modules that a superclass
includes, in CRuby's order. A method defined in a module is found through the
module's own declarations, so the chain is `prepend`, the class, `include`
(last first), then the superclass. A module reached twice in that chain (two
include paths, or a module the superclass already includes) supplies no
contract: CRuby keeps it at its first insertion, and that depends on load order
the static links do not record. `class Child < Base; include M; end` with
`Base` also including `M` therefore refuses the call instead of returning
`M#m`, which CRuby dispatches to `Base#m`. Unknown mixins and cycles refuse
the same way. The fixture is `scripts/bc2cpp/rbs_mixin_contracts_check.rb`.

**Unknown receivers.** A receiver whose class set is unknown does not use a
return contract because its method name has one declaration in the program.
Only a receiver the compiler proves (a declared argument, an existing complete
proof) reaches the contract lookup. A call on an unproven receiver stays
`unknown`, and its reason names the upstream producer. This rule is
deliberately narrower than "single contract owner": that inference would
assume a class the analysis has not proven.

**Implicit self-calls.** An implicit `self` send dispatches on the receiver's
class, so its declared result is the join over every class the receiver can
be. The rule, for a send of `name` in a method of `owner`:

- The receiver set for a class owner is `ClosedWorld#known_subclasses(owner)`:
  the owner and every program class that descends from it.
- The receiver set for a module owner is the instances of its includers: each
  declared class whose ancestor chain reaches the module (the registry's
  `include` records, through modules that include it), together with those
  classes' descendants. A module nothing includes has no receiver, so it stays
  untyped. The candidates are `ClosedWorld#known_includer_candidates`, which is
  open when a native or outside Ruby source names the module.
- Each receiver contributes the contract its own dispatch reaches (the first
  owner in its ancestor chain that declares `name`). A `:self` contract answers
  that receiver's class. The result is the union of those contributions.
- With no override anywhere in the set this is the owner's contract. With
  `Base#via_self` calling `greet`, and `Child < Base` overriding `greet` to
  return `Integer`, `Child`'s override joins `Base`'s `Symbol`, so
  `Base#via_self` is `Symbol | Integer`, never `Symbol` alone. A module
  `M` included by `A` (`greet` is `Symbol`) and `B` (`greet` is `Integer`) gives
  `M#via_mod` the same `Symbol | Integer`.
- The send is untyped (no declared result) when the set is open: no closed
  world, a subclass that may come from outside the program (`Class.new`, an
  outside definer, a wildcard), a module with no bounded includer set (an
  includer the registry cannot place, such as `include(*mods)`, a singleton
  class's `include`, a native or outside source that names the module, or a
  runtime `extend`, which closes the world), or a core ancestor such as `Object` or `Kernel`, whose core
  instances the program does not declare. It is also untyped when a receiver's
  chain is unknown (an unknown mixin or a cycle) or does not reach the owner,
  when a receiver or one of its ancestors is `prepend`ed, when a receiver runs
  a `method_missing`, or when a receiver lacks a declared contract for `name`.
- Removal: a name the program may undefine or remove has no self-call contract
  at all. The program contains `undef_method NAME`, `remove_method NAME`, the
  `undef` keyword, or the same through `send`, `__send__` or `public_send` with
  a literal name, and any of them with a name that is not a literal (or a
  computed target) marks every name. The scan does not attribute a removal to
  a class, so a removal in any class counts, which covers the owner and every
  subclass. This is `ClosedWorld#method_removed?`, applied by
  `RbsSignatures.ir_types` (`removed:`).

Explicit receivers do not use this rule, so the removal refusal does not reach
them. The rule is in `RbsSignatures.self_receivers`,
`RbsSignatures.module_receiver_classes` and `RbsSignatures.self_call_types`,
and the fixture is `scripts/bc2cpp/self_call_override_contracts_check.rb`.

Rest, keyword and block contracts in the body analysis, required parameters of
methods with optional ones, constants and nonlocal-return inference remain
follow-up work (the call-site joins for rest, keyword and block parameters are
described above). Inferred ivar candidates (`@ivar: T` in the type-check RBS,
and the `ivars` rows of the facts file) are the union of every traced store
across the ivar's numeric family: superclass, include and prepend links, since
all of them share the slot. The candidate gains `nil` when some read may run
before any store: a `@x = nil` store, or a reading owner that
`numeric_ivar_assured?` does not clear. That check needs a closed world with no
`allocate` and a #initialize that assigns on every path before `self` escapes;
where it cannot decide, `nil` is included. A store the analysis did not resolve,
or an ivar touched by code no class owns (a module body), leaves the candidate
unknown. The runtime layout is still the layout analysis's; only the candidate
that is written and compared changes. Inferred ivar types continue to come from
the existing whole-program layout analysis; observing one store does not
establish the complete type of an ivar.

Run the signature, type-check and RBS-export checks with a host `MRBC`. The
fixture suites compare guarded dispatch with `BC2CPP_STRICT_HINTS=0`.
See [ADR 0442](adr/0442-bc2cpp-ir-contract-feedback.md).

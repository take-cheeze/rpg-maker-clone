# IR type feedback and RBS suggestions

The type-check workflow now connects RBS contracts, bytecode IR facts and
reviewable RBS suggestions. It retains nominal contracts for required
arguments, ivars and method returns, including nullable and union types.
Ivar reads use the applicable owner/ancestor contract. An implicit call on
`self` joins the contracts of every receiver class the program bounds (see
**Implicit self-calls** below). An ordinary explicit receiver with known nominal bounds can also use its
return contracts, joined over the subclasses the program bounds (see
**Explicit receivers** below). An unknown receiver does not inherit a return contract
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

- each positional parameter, required (trace kind `req`) or optional (`opt`),
  matched by position, and each method return, except `initialize`;
- each keyword parameter, required (`kwreq`) or optional (`kwopt`), matched by
  name (the C parameter is `bc2cpp_kwarg_NAME`). A value is traced only where the
  caller gave it, so both kinds are real arguments;
- a rest parameter's extra arguments: the `rest` row is the Array the call built,
  and its elements (role `array`) are checked against the `T` of `*T`. A `rest`
  row whose class is not `Array` is counted as `rest row(s) not an Array` and not
  compared, since the index is then not that parameter;
- the elements of a parameter or return declared `Array[T]` or `Hash[K, V]`: the
  `PARAM_ELEM_*` and `RETURN_ELEM_*` rows, by role (`array`, `key`, `value`);
- singleton methods (`def self.x`), against the trace key `Owner.singleton#x`;
- the receiver of a singleton method (its `self`, a `self` PARAM_SITE row). The
  trace records the class object it ran on, so the receiver is compared with
  `Owner`: the class itself, or a subclass whose superclass chain `--hierarchy`
  reaches. A class outside that chain is a contradiction. A module owner, a
  receiver that is not a class or module (recorded as `(non-class)`), a class the
  hierarchy cannot place, or an overflowed receiver is counted in the summary
  (`singleton receiver(s) compared`, `receiver class(es) undecided`, `overflowed
  receiver(s) skipped`) and never a failure. A module method run through
  `extend` is compared with its extending class's singleton methods only, so
  its receiver is not compared;
- a module method, against the observations of each class that includes the module.
  The class must be known to include it through `--hierarchy`; without that file the
  observations are counted as undecided;
- a module method, against the singleton observations (`Owner.singleton#x`) of each
  class that extends the module. A method of an extended module is the extending
  class's singleton method, so its `self` return is not the module's. Without
  `--hierarchy` those observations are counted as cannot decide;
- an overloaded method whose definitions agree and whose trace shows one
  implementation (see [overloaded methods](#overloaded-methods));
- an ivar read, `@x`, against the `@x: T` the candidate declares in the class the
  read's method is defined in. A read is traced where the compiled code reads the
  ivar with a GETIV: the `IVAR_SITE` rows name the owner class and the ivar, and
  their classes are the values read. A module's ivar is never decided (it belongs to
  whichever class includes the module), and an ivar the candidate does not declare
  (`untyped`, or no declaration for that class) is counted as undeclared, not compared.

A site is skipped when it was not reached. An overflowed site (its class table was
full, so its classes are unknown) is not compared; the summary counts every
overflowed site, element slot and ivar read in the trace, declared or not.

Ivar reads come from the `IVAR_SITE` and `IVAR_CLASS` rows of a `BC2CPP_TRACE_TYPES=1`
build. The rows are written only for a GETIV of a class the compiler knows (a singleton
owner and an unknown `self` class get none). A dump without them (one recorded before
they were added) reads as before, with no ivar observations.

### Overloaded methods

A method key (`Owner#name`, or `Owner.singleton#name`) is overloaded when the
candidates give it more than one definition (a class reopened with the same method,
or an RBS method with several `|` overloads). The rule, stated once: a key is
compared as one method when both hold, and skipped otherwise.

1. Every candidate definition of the key declares the same RBS method type text.
   Then whichever definition ran, the declared type is the same. Two definitions
   that disagree fail this, and the key is skipped.
2. The dump shows at most one implementation under the key: the distinct `fn`
   values (the C `_impl` name) of its `PARAM_SITE` and `RETURN_SITE` rows that were
   called. Two implementations mean the trace cannot tell which definition ran (a
   `define_method` or `alias` installed a second one under the same key), so the key
   is skipped.

A module method's class keys (`Class#name`, `Class.singleton#name`) are decided the
same way, by the definitions of the module method and the implementations under the
class's key. A skip is counted in the summary as `overloaded comparison(s) skipped`
and is never a contradiction. The count is per key that the rule refuses, whether or
not the trace reached it. A definition the candidates do not list is invisible to
the rule, as it is to the rest of the check. Rule 2 can refuse a method that has one
definition when the dump records two `fn` names for it (for example two builds that
name the same method differently); that is a missed check, not a false failure.

A class is a contradiction only where the lookup order is complete: a core class
(from `CoreHierarchySigs`), or a program class whose superclass chain reaches a
core class through `--hierarchy`. A module is never a contradiction. A class that
includes a module the candidate declares is admitted, anything else is undecided.
A module method's observation on a class is accepted only when the lookup reaches
the module before any other definer of the name; a core class in front of the
module, or a native mixin, makes it undecided. Everything else is reported as
undecided in the summary. A passing run is evidence about one recorded run, not a
proof.

The singleton lookup of an extending class is read the way Ruby orders it: the
class's own singleton methods (`SDEF` rows) first, then the modules it extends, last
applied first, then its superclass's singleton lookup. A module method's observation
is accepted only when the module is reached before any other definer of the name.
An own `def self.x` in front of it makes the observation the class's own method, so
it is not compared. A dynamic extend (an `EXTEND` row whose module is `*`, from an
argument the sources cannot name or an `extend` inside a `def`) is an unknown entry
in front of the extended modules, so that class is cannot decide. An `EXTEND` row
with `*` as its owner (an `extend` inside a block, or on an explicit receiver) makes
every class's singleton lookup unknown.

`--hierarchy` takes the rows `class_hierarchy.rb` writes: `CLASS`/`MODULE`,
`SUPER`, `INCLUDE`/`PREPEND` (in application order), `EXTEND` (the `extend M` or
`extend self` of a class body, and `include M` in `class << self`; in application
order too), `DEF` (including `define_method`, `alias` and `attr_*` names, and `*`
for a computed name) and `SDEF` (the singleton methods a body defines: `def self.x`,
and the defs of a `class << self`). The mixin and extend rows come only from the
sources it is given. A mixin it does not see (a file left out, an `included` hook, a
`class_eval` string) leaves that class's module observations uncompared: a missed
check, never a false failure. An `extend` it does not see is the same kind of gap: a
module the rows miss cannot be attributed, so only the modules they do name are
compared. A top-level `extend` belongs to `main`, which is no class, so it has no row.

The trace cannot tell the check these things, so they are not compared:

- block parameters. The trace has `block_arg` rows, but they are the parameters of
  a block body, keyed by the body's own `_impl` (the method that yields to it is
  not in the row), and the emitter declares a block type only as
  `{ (*untyped) -> untyped }`, so there is no declared type to compare with. A
  method's `&blk` value is not traced either (`bc2cpp_blk` is not a parameter row).
  This stays a skip until the trace names the yielding method and the emitter
  declares block parameter types;
- ivar reads that are not GETIV reads: stores (SETIV), reads through a synthesized
  attr accessor, and `instance_variable_get`. The check sees only the values the
  compiled GETIV reads hand back, so a wrong value that reaches an ivar only through
  one of those is not seen;
- constant types. A constant read (GETCONST, GETMCNST) names the constant as written,
  not the scope that resolved it, so a candidate `NAME: T` cannot be matched to the
  observation (the same name can resolve to different constants in different scopes);
- overloaded methods the rule above refuses (definitions that disagree, or a trace
  that shows two implementations under one key). Overloads whose definitions agree
  and whose trace shows one implementation are compared;
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
- **Keyword** (`k:` or `k: default`): the join of the value passed for `k` at every
  reaching call. A call passing keywords through `**splat`, or any unknown call
  site, refuses the join. A required keyword (`k:`) also refuses a call that omits
  it, and RBS writes `k: T`.
- **Optional keyword** (`k: default`): a call that omits `k` binds the default, so
  the join is the passed values plus the default's class. The default must be one
  literal (`nil`, an Integer, a String, an array or hash literal); any other
  expression refuses the join and the keyword stays `untyped`. RBS writes `?k: T`.
- **Block** (`&blk`): the block is `Proc` only when every reaching call passes a
  literal block or lambda (`BLOCK`/`LAMBDA` producer in the block slot). A call with
  no block binds `nil`, and a Proc from a variable, a `proc` call or a `&` pass-through
  is not recognized, so each refuses. A block typed `Proc` is written as a required
  block (`{ (*untyped) -> untyped }`); otherwise the block stays optional. A declared
  block signature keeps its optional block.

The body analysis consumes the same joins, so a read of the parameter inside the method
sees the type the call sites prove:

- **Rest**: the rest register holds an `Array`, and an element read of it (`items[i]`)
  takes the element join. The join is withheld when the body could change the array: any
  read of it (or of a `MOVE` copy) other than an element read, a closure that captures
  it, a zero-argument `super` (which packs it), or a `binding`/`eval` call.
  Where the join is absent or withheld, a declared `*T` in the signature types the
  element read as `T` (with `nil` for an absent index, as for the join). That bound is
  a signature contract, so only the declared query (`fact_at`) sees it, not the
  undeclared one (`at`). The mutation and escape refusals withhold call-site facts only,
  so they do not withdraw it; as for a declared `Array[T]` argument, the body's own
  stores into the array are not checked against `T`. Only a positional-only rest (no
  post, keyword or keyword-rest parameter) whose optional count matches the signature
  declares it. With both the join and `*T`, the join is read, as it is for a required
  parameter, so a disagreeing `*T` does not widen the body; the trace check still
  compares `*T` with the observed elements.
- **Keyword**: the `KARG` register takes the join. An optional keyword's join already
  holds its default's class, so the register reads the join with no further check. A
  declared keyword type wins over the join.
- **Block**: the block register is `Proc` when the join proves it, in place of the nominal
  `Proc | nil`. A declared block signature withholds it, as the report row does.

`BC2CPP_IR_ARGUMENT_TYPES=0` restores `untyped` for all three, in the body and in the rows.
A declared `*T` is not a join, so the switch does not withdraw it.
These facts feed the report and the candidate RBS only; the generated code does not read them.

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
  runtime `extend`, which closes the world), or a core ancestor that has core
  subclasses (`Object`, `Numeric`) or is a module (`Kernel`), whose core instances
  the program does not declare. A core leaf is the exception (CORE_LEAF below). It
  is also untyped when a receiver's chain is unknown (an unknown mixin or a
  cycle) or does not reach the owner, when a receiver or one of its ancestors is
  `prepend`ed, when a receiver runs a `method_missing`, or when a receiver lacks a
  declared contract for `name`.
- Removal: a name the program may undefine or remove has no self-call contract
  at all. The program contains `undef_method NAME`, `remove_method NAME`, the
  `undef` keyword, or the same through `send`, `__send__` or `public_send` with
  a literal name, and any of them with a name that is not a literal (or a
  computed target) marks every name. The scan does not attribute a removal to
  a class, so a removal in any class counts, which covers the owner and every
  subclass. This is `ClosedWorld#method_removed?`, applied by
  `RbsSignatures.ir_types` (`removed:`) to the declared self-call contract.
- The same scan refuses the inferred call result (`BC2CPP_IR_CALL_RESULTS`,
  the default) of every send of a removed name, with an explicit receiver or
  an implicit self: `CodeGen#bytecode_ir_call_result_classes` answers unknown,
  and so does `IrContextResults#dispatch`. The body join of the target is not
  taken for that call, so the result is untyped. The call-graph argument seeds
  read the same results and inherit the refusal.

The return-class oracle the code generator's proofs read
(`CodeGen#return_class_send_mask`, keyed by name in `@rc_return`) refuses a send
of a removed name the same way: it answers unknown, the table holds no entry for
the name, and a method whose return is such a send takes no body join. The
declared contract of an explicit receiver (`call_resolver`) is refused too: a
removed name gets no contract on any explicit receiver, with cause
`call_removed:NAME`. The rule is in `RbsSignatures.self_receivers`,
`RbsSignatures.module_receiver_classes` and `RbsSignatures.self_call_types`, the
explicit-receiver resolver in `RbsSignatures.ir_types`, and in
`CodeGen#bytecode_ir_call_result_classes`, `CodeGen#return_class_send_mask` and
`IrContextResults#dispatch`. The fixtures are
`scripts/bc2cpp/self_call_override_contracts_check.rb`, sections (g) (the
inferred call result) and (h) (the return-class oracle), and
`scripts/bc2cpp/explicit_receiver_override_contracts_check.rb`, section (g).

**Explicit receivers.** A send on a receiver with declared nominal bounds (an
argument, ivar or element declared `Base`) dispatches on the runtime class,
which may be any program subclass of `Base`. So the resolver joins the same
receiver set as a self-call, per declared class: `self_receivers` for that
class, then `self_call_types` for `name`. With `def use(o); o.greet; end` and
`o: Base`, where `Child < Base` overrides `greet` to return `Integer`, the result
is `Symbol | Integer`; the owner-only answer (`Symbol`) is no longer reported.
With no override the owner's contract is kept. The send is untyped (refused as
`call_receiver_unbounded:CLASS#NAME`) when the receiver set is open by the same
rules as for self, including the absence of a closed world. A receiver class
with no closed-world bound is therefore untyped even when no subclass exists:
an outside subclass cannot be ruled out. Fixture:
`scripts/bc2cpp/explicit_receiver_override_contracts_check.rb`.

**Core roots (CORE_ROOT).** A declared core class with no core subclass in
`CoreHierarchySigs` (a leaf: `Array`, `Hash`, `String`, `Range`, ...) is a bounded
receiver. Its set is the class plus the program classes that name it as their
superclass, read from the program's `class X < Array` lines since no `class Array`
is needed. A core class with core subclasses (`Object`, `Numeric`) or a core module
(`Kernel`, `Enumerable`) stays refused, since its instances include core classes
the program does not list. The send keeps the core contract exactly when all four
hold:

- the receiver set is closed (the same checks as any bounded class: no outside
  subclass, no dynamic or native subclass, no `method_missing`);
- the program does not define the method name on the contract's owner
  (`ClosedWorld#program_may_define?`: a Ruby definition outside the core mrblib, a
  native or unknown definer, or a refusal); this covers a reopen of the core class
  and a module prepended to it;
- every class in the set dispatches to that same contract. A program subclass that
  overrides the name leaves the send untyped (the override rule), even when the
  override declares its own return. A subclass that does not override keeps the
  core result.

So `Array#size` is `Integer` with no program subclass, and with a subclass that
does not override `size`. It is untyped when a subclass overrides `size`, when the
program redefines `Array#size`, and when the set is open. The rule is
`RbsSignatures.self_receivers` (`core_leaf?`) and `RbsSignatures.self_call_types`
(`core_redefined:`). The bound is `ClosedWorld#known_receiver_subclasses`, which
the RBS resolver reads; the codegen keeps `known_subclasses`, so generated code
does not change. The fixtures are in
`scripts/bc2cpp/explicit_receiver_override_contracts_check.rb`.

The same rule applies to an implicit-self send whose owner is a core leaf (a
program method reopening `Array` that calls `size`). That is the one change to the
self-call path: such sends were untyped and are now typed under the same four
conditions. Other self-call results are unchanged.

Required parameters of methods with optional ones, constants and nonlocal-return
inference remain follow-up work. Inferred ivar candidates (`@ivar: T` in the type-check RBS,
and the `ivars` rows of the facts file) are the union of every traced store
across the ivar's numeric family: superclass, include and prepend links, since
all of them share the slot. The candidate gains `nil` when some read may run
before any store: a `@x = nil` store, or a read that is not store-first in an
owner that `numeric_ivar_assured?` does not clear. A read is store-first only
when it sits in its owner's method body and every path from the entry passes a
SETIV of the ivar before it (a must-store pass over that body's CFG, exception
edges included). A self-call never counts as a store, so a read after one keeps
`nil`; so does any read in a block. That check needs a closed world with no
`allocate` and a #initialize that assigns on every path before `self` escapes;
where it cannot decide, `nil` is included. A store the analysis did not resolve,
or an ivar touched by code no class owns (a module body), leaves the candidate
unknown. The runtime layout is still the layout analysis's; only the candidate
that is written and compared changes. Inferred ivar types continue to come from
the existing whole-program layout analysis; observing one store does not
establish the complete type of an ivar.

Reflection that reads an ivar without a GETIV is not visible to the scan, so it
turns the store-first proof off (the rule is `IvarCandidates.reflective_access`):

- for every ivar, when the program has an `instance_variable_set` or
  `remove_instance_variable` send (any name), a `LOADSYM` of a reflective name
  (`send`, `method`, `&:instance_variable_get`, ...), a string `eval` (no
  block), or an `instance_variable_get` / `attr*` / name-dispatch call (`send`,
  `__send__`, `public_send`, `method`, `define_method`, ...) whose name operand
  is not a literal Symbol or names a reflective method: no read is store-first
  and nil stays on every candidate;
- a literal `instance_variable_get(:@x)` or `attr_reader :x` does this for `@x`
  (or `x`) only;
- a name-dispatch call with a literal non-reflective name (`send(:greet)`)
  changes nothing: the method it runs has its own body in the scan.

`method_missing` adds no rule of its own: its body is a method the scan reads,
and a name it reads through `instance_variable_get` is covered above.

Run the signature, type-check and RBS-export checks with a host `MRBC`. The
fixture suites compare guarded dispatch with `BC2CPP_STRICT_HINTS=0`.
See [ADR 0442](adr/0442-bc2cpp-ir-contract-feedback.md).

# bc2cpp type check

A TypeScript-like gradual check built on bc2cpp's own whole-program inference (ADR 0412). It never changes generated
code. Its errors (exit status 1) fail the `bc2cpp-build` job's Type check step, and the constant ratchet below (TC1017)
is one of them.

## Run it

```
MRBC=path/to/mrbc ruby scripts/bc2cpp/type_check.rb                 # the engine, text report
MRBC=... ruby scripts/bc2cpp/type_check.rb --format json --out tc.json
MRBC=... ruby scripts/bc2cpp/type_check.rb --format tsv  --out tc.tsv
MRBC=... ruby scripts/bc2cpp/type_check.rb --files app.rb lib/*.rb   # your own program (closed world)
ruby scripts/bc2cpp/type_check.rb --facts kept/facts.json --rows kept/rows.tsv   # re-render, no analysis
```

`--keep DIR` keeps `facts.json`, `rows.tsv` and `bc2cpp.stderr`. `--all` adds one info line per untyped item,
`--no-sends` skips the send ranking, `--what-if` estimates removable lines (slow), `--top N`, `--scope all` includes
the mruby core mrblib. The analysis takes the time of a build's analysis phase (minutes for the engine).

The report runner keeps whole-program analysis, real method compilation, return-guard
validation and nilable-index collection. It skips the discarded C++ translation
unit and declaration sidecar; receiver-report writers still finish normally.
`--keep` therefore contains analysis diagnostics rather than final emission listings.
Repeated context class decoding is cached within one engine, with invalidation
when numeric class bits or private container shapes are registered. See [ADR 0517](adr/0517-type-check-report-cost.md).

Root context graphs retain their own admission and round budgets. Small leaf
contexts reuse immutable evaluations at their normal solver turn. Reuse stays within
one context engine and is bounded to 128 snapshots of at most 4096 state cells.
Set `BC2CPP_IR_LEAF_EVALUATIONS=0` for a comparison run. See
[ADR 0518](adr/0518-reuse-leaf-context-evaluations.md).

Within each root graph, an evaluated context is reused while every observed
callee revision stays unchanged. Revisions include flow states, call results,
literal shapes and return masks because transitive effect checks read callee
states. Numeric-class or private-shape registration forces reevaluation. Solver
order, graph admission, round limits and refusal behavior remain unchanged;
dependency records are released when the root finishes. Set
`BC2CPP_IR_CONTEXT_REEVALUATION=0` to compare full reevaluation. See
[ADR 0527](adr/0527-unchanged-context-evaluations.md).

Receiver union decoding indexes numeric class bits and visits only bits present
in a receiver. Decoded unions are cached within one CodeGen instance, with a
2048-entry limit. Lazy class registration and probe table replacement invalidate
the index; unknown/core/provenance bits and unions above eight classes remain
refused. Set `BC2CPP_CLASS_MEMBER_INDEX=0` for a full-table comparison. See
[ADR 0523](adr/0523-receiver-class-member-index.md).

Applied RBS contracts are indexed once per typing world. Methods and callbacks
share owner lookup, inherited ivar maps and named-return tables, while each method
keeps fresh inference and query state. A new signature or hierarchy world needs a
new index. Set `BC2CPP_IR_PREPARED_CONTRACTS=0` to compare the unprepared path. See
[ADR 0519](adr/0519-prepared-rbs-ir-contracts.md).

Context argument binding indexes immutable arity, keyword names and validated
optional-entry jumps per bytecode body. Every binding still checks its current
arguments and keywords and builds fresh masks and entry edges. Indexes live only
for one context engine; malformed layouts remain refused. Set
`BC2CPP_IR_BINDING_INDEX=0` to compare rebuilding layouts on each bind. See
[ADR 0520](adr/0520-context-binding-index.md).

Context call frames also index fixed receiver/argument registers and keyword-name
producers. This avoids repeated reaching-definition result copies and name decoding;
values are read from the current context on every call. Splat, ambiguous and
nonliteral keyword names keep their conservative refusals. Set
`BC2CPP_IR_CALL_INDEX=0` to rebuild layouts. See
[ADR 0521](adr/0521-context-call-layout-index.md).

Method resolution indexes ordered ancestor paths, simple class names and Ruby
instance owner sets within each `CallFacts::Answers` world. Hierarchy and registry
inputs must remain settled for that instance; changed inputs require a new world.
Unknown paths stay refused and inherited/native lookup order is preserved. Set
`BC2CPP_CALL_LOOKUP_INDEX=0` to compare the uncached path. See
[ADR 0522](adr/0522-call-lookup-allocation-index.md).

Compilation probes share immutable block-capture metadata within each CodeGen.
Captured upvar pairs and forwarded-block levels are indexed by bytecode body;
block levels also distinguish traversal depth and whether native `block_given?`
reads are modeled. This preserves the depth refusal and Ruby override checks.
Only structural metadata survives probe rollback; region eligibility, layout checks
and generated registrations still run normally. Set `BC2CPP_BLOCK_CAPTURE_INDEX=0`
to repeat the original walks. See [ADR 0528](adr/0528-block-capture-index.md).

## Output

Diagnostics are `file:line:col: severity: message [CODE]`, sorted errors first, so an editor problem matcher
(`gcc`-style) reads them. Exit status is 1 only when there is an error.

| Code | Severity | Meaning |
| --- | --- | --- |
| TC1001 | error | a declared type disagrees with the inferred one (fixnum/symbol argument or return, class argument, class return) |
| TC1002 | error | a signature file could not be used |
| TC1003 | error | a signature names a method or ivar class the program lacks (a stale signature) |
| TC1007 | error | an inferred IR return or ivar store is disjoint from its RBS nominal contract |
| TC1008 | warning | an inferred IR may-set partly overlaps its RBS contract; path refinement is unresolved |
| TC1013 | error | a caller's argument is not proven to be the class an RBS parameter declares (ADR 0456) |
| TC1014 | error | an RBS class parameter is refused: POLY, computed or outside-world name, splat caller (ADR 0456) |
| TC1016 | error | an RBS `class C < S` names a superclass the program does not give C (ADR 0453) |
| TC1017 | error | the constant ratchet (ADR 0491): an engine constant with no type and no `constant` review annotation on its line, or an annotation whose constant is now typed or gone |
| TC2004 | info | (`--all`) an IR query is unknown, with its refusal or producer reason |
| TC1005 | warning | an index (`x[i]`, `x[i] = v`) on a receiver that may be nil, with no nil check before it (ADR 0439) |
| TC1004 | error | an annotation token bc2cpp ignores (unknown class), a signature or annotation with more tokens than the method has parameters (fewer is fine: a prefix) |
| TC2001-3 | info (`--all`) | untyped parameter / return / ivar, with the reason |
| TC3001 | info | `suggestion #N`: a signature on this declaration would act on N by-name send lines |

The summary lists typed / untyped counts for parameters, returns, ivars and constants, the source of each type
(`annotation`, `inferred:call-sites`, `inferred:class-pool`, `inferred:return-analysis`, `inferred:ivar-layout`, ...) and
the reason buckets of what is untyped:

* parameters: `poly:N` (the name has N definitions), `dynamic-name`, `never-called`, `packed-caller`,
  `no_candidate:<rule>`, `dropped:<kinds>` (the receiver-proof reasons, ADR 0331);
* returns: the producers of the return sites no class could be named for, e.g. `send_result:foo(ruby)`,
  `send_result:to_s(native)`, `ivar:@x`, `param`, `element`, `unanalyzable:<why>`;
* ivars: `any` (stores disagree, inherent) or `opaque` plus the ADR 0382 bucket (`parameter`, `project_call`, ...), or
  `nil-or-unassigned`.

A constant typed `Array` by `inferred:array-sum` is `(A + B).freeze` (or `A + B`) whose operands both prove Array
(`DeclaredConstants.array_sum_names`). It is withheld when a Ruby `+` on Array can replace the core method, or when a
Ruby `freeze` sits on the owners of Array (Array, Enumerable, Object, Kernel, BasicObject and the modules mixed into
them; `DeclaredConstants.stock_method?`). A program's own `Graphics.freeze` does not withhold it. An operand may be
`(lo..hi).to_a` over two literal endpoints of one kind (both String or both Integer literals,
`DeclaredConstants.range_to_a_source?`). That proof is withheld unless `DeclaredConstants.range_to_a_safe?` holds: no
Ruby definition of `to_a`, `each`, `upto` or `__num_to_a` sits on Range, Enumerable or String (or a module mixed into
them), and none of those has a prepend or an unresolved mixin. A constant whose sum uses a non-literal endpoint, or a
Range literal that is not a sum operand (`X = ('a'..'z').to_a.freeze`), stays untyped. A declared `X: Array` (RBS,
TC1011) accepts the same sum under the same proof; the declared check keeps the program-wide `freeze` refusal, so the
report and the declared check can differ on such a sum.

A constant typed by `inferred:constructed` or `inferred:class-pool` whose value is `.freeze`d is typed `Array` or
`Hash` only while `freeze` is stock on that class (the same owner scope). `inferred:hash-merge` is `R.merge(H)` with
one argument, whose receiver proves exactly Hash (a Hash literal, or a constant that is one) and whose `merge` is stock
on Hash, with no singleton method on the receiver (the closed world's exact-instance check). The report-level proofs
never change generated code.

A constant typed `Integer` by `inferred:integer-range` is integer arithmetic (`+ - * /`, with `-7 / 2 == -4`, floored) on
literals and other constants, whose every definition has an interval inside the narrowest target Fixnum range
(`IntegerConstantRanges`, NUMERIC_CONSTANT_RANGES). It is typed only when no other producer types it first, so no existing
row changes. The proof is withheld when a Ruby definition of `+ - * / ==` sits on Integer or a module it includes, or a
module is prepended into Integer (the owner-scoped `IntegerConstantRanges.integer_ops_safe?`); the exact-value proof of
`IntegerConstants` takes the same gate. A divisor interval that contains 0 has no interval. `scripts/bc2cpp/constant_typing_check.rb`
covers these.

FREEZE_SELF: `R.freeze` answers its receiver (Object#freeze), so a `.freeze` send has the receiver's type while `freeze` is
stock on that class. The one proof is `DeclaredConstants.stock_method?('freeze', klass, ...)` (owners Integer, String,
Array, Hash with their ancestors; no Ruby `freeze`, prepend or unresolved mixin on them). It is used in two places:
* `inferred:freeze-self` (`TypeFacts#freeze_self_type`): a constant whose every assignment is `(literal).freeze` of the same
  class (Integer, String, Array or Hash literal) with stock `freeze` gets that class. Only a literal receiver is proven;
  a send, sum or ivar receiver keeps its own producer, so `(DIR_BIT[2] | DIR_BIT[4]).freeze` stays untyped.
* the `inferred:integer-range` walk reads through `.freeze` on an Integer expression (`freeze_safe:`), so
  `SLOT = (A - B).freeze` has the interval of `A - B`. Without the proof the freeze is a poison, as before.
On the engine today the `inferred:freeze-self` rule types no row, since the class-pool and constructed proofs already type
every frozen literal constant it covers; it is a fallback for names those proofs do not reach.

Four further constant producers come after the ones above, each consulted only when no earlier one typed the row:

* `inferred:integer-constant` also admits `a | b`, `a & b` and `a ^ b` (SEND with one argument; mruby 4 has no opcode for
  them) over exact Integer operands. The value is Ruby's result (two's complement for negatives) and must sit in the
  Fixnum margin, as for `+ - * /`. The gate is the same `integer_ops_safe?`, which now also names `| & ^`.
* `inferred:integer-class` types a name Integer whatever its value is, the bignum-capable Integer of the vocabulary (a
  bignum is an Integer class instance; `inferred:literal` already types an out-of-margin literal this way). It is
  `IntegerConstants.class_admitted`: the same fixpoint, before the Fixnum check, so `BRIGHTNESS_Z = TRANSITION_Z - 1`
  (TRANSITION_Z = 0x40000000, a bignum on the 32-bit targets) is Integer although its intermediate leaves the margin.
  A literal-only arithmetic definition (no constant operand) must still have an exact value inside the margin. mrbc folds
  such an expression (`1073741824 | 1` compiles to one LOADI32), so in practice a plain out-of-margin literal reaches the
  proofs, and the existing literal producers already type it. Report only; codegen reads only the Fixnum proof.
* `inferred:bool-compare` types `'literal'.length == <integer literal>` (EQ) as `bool`. The receiver proves Integer
  through SEND0 `length` on a STRING literal with String#length stock (`DeclaredConstants.stock_method?`, now answering
  for String, and every non-core native `length` definer is one read as not String's: `STRING_LENGTH_NOT_STRING_NATIVES`
  lists four, so a new definer refuses the proof), and Integer#== is stock (`integer_ops_safe?`). An `==` on Integer
  returns true or false, so the value is `bool`, not Integer.
* `inferred:io-open` types a constant whose every value is a blockless `IO.open(...)` (SEND or SEND0 named `open`, with
  the constant IO as receiver; a SENDB carries a block and is not this) as `IO`. mruby-io's IO.open (io.rb:
  `io = self.new(*args); return io unless block`) answers Class#new on IO when there is no block, so the value is an IO.
  With a block it returns the block's value, so such a call is not typed. The gates are `IO_OPEN_SAFE`
  (type_facts `io_open_safe?`): `ClosedWorld#native_class_unshadowed?('IO')`; no engine `open` defined on `IO.singleton`
  and no prepend or unknown mixin on it; no non-core native `open`; and `new` stock (`class_new_is_stock?`). The row is
  report-only: const_rows runs in the type check, and io_open_safe? is read there alone.

  Why `native_class_unshadowed?('IO')` was false, and what changed. Its outside write count was 2, not the 1 the model
  expects: mruby-io's io.c defines IO with `mrb_define_class_id(mrb, MRB_SYM(IO), mrb->object_class)` and mruby-stringio's
  stringio.c with `mrb_define_class(mrb, "IO", mrb->object_class)`. A define with the same superclass returns the class
  already bound, so these two bind one class; a different superclass raises at startup. The model also counted io.rb's
  root-level `class IO` (a CLASS op, no superclass) as a program class declaration, though it only reopens the native
  class. The count is now allowed when every outside write is a plain Object-superclass define (`@outside_plain_class_defines`),
  and a root-level no-superclass CLASS op is not a declaration (`root_reopen?`; mruby runs the root irep with the Object
  target class). A nested `class IO`, a `IO = ...` rebinding, a `const_set` or any second non-plain write still refuses.
  Codegen: the predicate change reaches codegen only through infer_constructed_constant_classes for NATIVE_CONSTRUCT_TARGETS
  names. Those are RGSS:: classes defined with mrb_define_class_under (not plain Object defines), with no top-level Ruby
  reopen in the engine's closed-world sources, so their answer is unchanged; the engine run changed no typed row.
  Checked by scripts/bc2cpp/io_open_check.rb (fixtures: blockless, block, redefined `open`, nested `class IO`, rebinding).
  Not investigated: io.rb's irep is labelled `mruby-rpg2k/mrblib_limited/map_tts_off.rb` in the rows (a pre-existing file label
  error), so the core-source filter does not drop it; the root-reopen rule is what keeps it harmless.

Two constant rows widen what the report can type. Both are report-only: codegen reads the value proof and the
`container_constants` map as before, except where noted below.

* The integer-class rows (`inferred:integer-class`) come from a second `BytecodeIR::ConstantFacts` run whose poison is
  `IntegerConstants.foreign_class_poison`. A foreign `NAME = <integer literal>` does not poison (it is an Integer
  definition; the class proof needs no value), and a foreign `NAME = A | B` over bare names does not poison when its file
  is one the IR already binds. Any other foreign definition, and every foreign class or module name, still poisons. The
  value run keeps `foreign_const_names`, so `fixnum_names` is unchanged. `StringIO::READWRITE` (`READABLE | WRITABLE`) is
  typed this way.
* HASH_LOOKUP (class run only, `hash_lookup_safe`) types a lookup `NAME[k]` as Integer, so the bit-operator rule above
  types `DIR_BIT[2] | DIR_BIT[4] | ...` and `Game::ChipSet::ALL_DIRS` (`inferred:integer-class`). The read is GETIDX
  (mrbc's `x[k]`); a SEND `[]` is not modelled. It is proven when every binding of the bare name N is a frozen Hash
  literal, `(literal).freeze`, with these properties:
  * the freeze's receiver is one HASH node, and nothing between the HASH and the freeze can run a method or copy the
    object (`Program#quiet_span?`, the container-literal proof), so the frozen table holds the literal's pairs;
  * every key is an exact Integer literal (no duplicate) and every value an Integer literal (`literal_hash_keys`);
  * k is one of the keys of every binding's table.
  The gates are `Hash#[]` stock (`DeclaredConstants.stock_method?`), no non-core native `[]` on a Hash ancestor (its
  owners read as CallFacts reads them: an unresolved owner refuses), no singleton method on an instance
  (`exact_instances_singleton_free?`), and no native or foreign definition of N (the value run's poison set). An
  Integer key needs no `eql?` / `hash` proof: mruby hashes and compares a fixnum key without dispatch
  (3rd/mruby/src/hash.c). Any other shape (a variable key, a block, a missing key, a non-literal value, an unfrozen or
  mutated literal, a non-Hash receiver) is not typed. The value run builds the nodes it built before (no HASH or GETIDX
  node), so the Fixnum facts, the folded values and `container_constants` are unchanged; codegen reads none of this.
  Checked by `scripts/bc2cpp/frozen_hash_lookup_check.rb`.
* The constructed-constant rows (`inferred:constructed`) judge each qualified name by its own sites: every site of that
  name must construct the same class (for example `Color.new`). `ClosedWorld#static_constant_writes?` must show the bare
  name is written only by the program's SETCONST sites, counted across every scope. The other sites of the same bare
  name (in any scope) must not be reachable from this one: `constant_scopes_unrelated?` (dispatch_targets.rb) requires
  that neither owner encloses the other, and neither is among the other's ancestors (superclasses, included and
  prepended modules, Object and its mixins). An ancestry it cannot model (an unresolved or reopened superclass, an
  unresolved mixin) counts as related. A bare read from a scope reaches only its lexical chain and its ancestors, so
  a related sibling could answer a read this site's hint covers, and the hint is then withheld. A single-site name is
  judged as before.

  Example: `TEXT_COLOR = Color.new(...)` in `ChipsetEditor` and `MapViewer`, plus `TEXT_COLOR = 0` in `EquipMenu` and
  `SaveLoad`. All four sit in sibling subclasses of `Scene::Base`, none encloses another, so the two `Color` sites are
  typed `RGSS::Color` and the two integer sites stay untyped. Because these hints feed `container_constants`, this does
  change codegen for multi-site names; the hints stay guarded at dispatch (CLOSED_WORLD_VALUE_CONSTANT).

## Constant ratchet (TC1017, ADR 0491)

The TC1017 gate that judged untyped engine constants by a review list (ADR 0491) and then by source annotations
(ADR 0522) has been removed. Untyped constants are reported by the type check but no longer fail a build; the
annotation gate and its check script are gone (ADR 0522).

## Workflow

1. Run the check; read the top suggestions.
2. Add a hint above the `def` (`# bc2cpp: (Game::Actor, fixnum) -> Game::Actor`, `-> Array<Klass>`).
3. Re-run: a hint that contradicts the inference is a TC1001 error at the comment's line; an ignored token is TC1004.
4. A correct hint makes the parameter `annotation`-typed and its sends take a direct arm. Hints stay guarded (a failed
   guard falls back to the by-name send); forcing them is the strict-hint tier.

Note: with guarded hints the by-name line stays as the else arm, so the count of `bc2cpp_send` lines does not fall;
the ranking is where a type fact acts, and it is exact only for the lines counted.

## Signature files (RBS)

Put `.rbs` files under `sig/bc2cpp/` (or point `BC2CPP_SIG_DIRS` / `--sig DIR` at other directories). They feed the same
hints as the comments and are checked the same way (ADR 0413). A declaration preceded by `# bc2cpp-native: <table>`
declares built-in or RGSS methods instead of the program's (ADR 0486); it is not a program hint. A member may carry its own
marker above its definition; a member with none takes its block's, and a member of an untagged block is a program hint
(ADR 0516).

```rbs
module Game
  class Actor
    @items: Array[Game::Item]          # ivar element class (guarded hint)
    @hp: Integer                       # checked against the inference, not forced
    def initialize: (Integer hp, Symbol kind) -> void
    def target: (Game::Actor other) -> Game::Actor
    def items: () -> Array[Game::Item]
  end
end
```

Supported: classes/modules; `def` with required positional parameters and one overload; `@ivar: T`; `attr_reader` /
`attr_accessor name: T`; types `Integer`, `Symbol`, `Array`, `Hash`, `Array[C]`, `Hash[K, C]` and program classes.
Accepted without a hint (TC1005 note): optional / rest / keyword / block parameters, `T?`, unions, `untyped`, `void`,
`bool`, `self`, singleton methods, constants, aliases, mixins, visibility, other generics, a class the program does not
define. Errors (TC1002): parse errors, overloaded `def`, other declaration kinds. A comment wins over a signature
(TC1006); an unknown method is TC1003; a wrong parameter count TC1004. Both are errors (see ADR 0436): a stale or mis-sized annotation fails the check and the build, the same as a contradiction.

Required argument declarations also retain nominal bounds for nullable types,
unions, `bool`, `nil` and literal classes. These appear in the report with source
`signature` and are available to [IR contract queries](bc2cpp-ir-types.md#rbs-argument-contracts).
They give no new optimization hint or exact-class proof; existing TC1005 notes
still describe that limitation. A union containing `untyped` stays unknown.
[IR feedback](bc2cpp-ir-feedback.md) also checks inferred returns and ivar stores
against these nominal bounds, distinguishing disjoint from partly overlapping sets.

Loop: write the signature, run `type_check.rb` (contradictions are reported at the signature's line), fix them, then
enable the strict tier when it is available so a wrong signature fails loudly at run time instead of falling back.

## IR feedback loop

`--emit-rbs-suggestions DIR` writes candidate RBS using independently inferred
IR returns at every modeled exit. It can replace a contradicted return in the
candidate copy; authored signature files stay separate. JSON includes
`ir_feedback` and `rbs_suggestions`; text summarizes provenance and unknown
reasons. Review the output, then pass it back with `--sig DIR`. See the
[feedback workflow and limitations](bc2cpp-ir-feedback.md).
[Call-result propagation](bc2cpp-ir-call-results.md) supplies audited result
proofs and typed-receiver RBS chains. Complete contract-assisted returns are
reported with source `derived:contracts` and their dependencies; independent
RBS suggestions continue to exclude them.

## RBS output and Steep

`type_check.rb --emit-rbs DIR` writes the inferred types as RBS (ADR 0414), one file per class or module. Unknown types are
`untyped`; optional / rest / keyword parameters are `untyped`; every method accepts an optional block; CRuby's core RBS is
the base environment (classes it declares are not redeclared). The directory is not read as hints unless named in
`BC2CPP_SIG_DIRS`; read back, it reports nothing, and a wrong edit is a located TC1001.

Steep on the CRuby-loadable part, measured (Steep 2.1.0 installed with `gem install steep`; run it with
`ruby $(gem contents steep | grep exe/steep) check`, rbenv does not shim it here). Steep checks only paths inside the
Steepfile's directory, so symlink the sources next to it:

```
# Steepfile
target :lcf do
  signature "sig"                         # the --emit-rbs output
  check "mruby-lcf/mrblib"                # symlink or copy of the gem
  configure_code_diagnostics(Steep::Diagnostic::Ruby.strict)
end
```

`mruby-lcf/mrblib` (7 files, 4657 lines) checks in about 7 seconds:

| Signatures | Steep errors |
| --- | --- |
| none | 1249 (668 methods in undeclared modules, 255 unknown constants, 948 no-method) |
| emitted by `type_check.rb --files mruby-lcf/mrblib/*.rb --emit-rbs sig` | 73 |

What remains: 47 `NoMethod` (mostly `LCF` module-level helpers and the native `cp932_to_utf8` / `utf8_to_cp932`, which
need native signatures; mruby core methods CRuby's RBS lacks need the same), 21 empty `[]` / `{}` literals that strict mode
wants annotated, 4 argument mismatches from `untyped`-vs-inferred unions, 1 overload. Getting this to zero needs
signatures for the engine's native classes and the mruby-only core methods (a hand-written or generated set per native
gem; not done here) and for the module-level helpers. Larger gems (mruby-rpg2k, mruby-rgss) additionally need the lcf and
rgss native classes declared, so they would stop at hundreds of `NoMethod` until then. Full mruby-core RBS is out of scope.

### Mask diagnostic allocations

Numeric mask names reuse an immutable primitive name table. Class mask names
reuse the existing registered-class snapshot and test integer bit positions,
avoiding temporary wide integer intersections while preserving registration
order. The snapshot follows numeric naming because a Symbol lookup can lazily
register its class. Snapshot identity and size continue to follow class growth
and probe rollback (ADR 0531). Negative masks, LCF kinds, private shape names and
the text and mutability of returned strings retain their existing behavior.
LCF kind and frozen-table membership also read their single bit positions,
including sign-extended negative masks and shapes registered after earlier queries.
No diagnostic result strings are cached. A warmed Ruby 4.0.5/YJIT full-engine
comparison of the private-mask extension reduced compiler allocations from
98,452,530 to 94,582,052 (3.9%); facts, receiver rows and report JSON were byte-identical.
One profiled timing pair was 53.459s versus 52.101s; it is not a repeated speed benchmark.

## Shared reaching definitions

Internal type, numeric and constant readers can request `shared: true` from the
reaching-definition query. Cached results are frozen snapshots; callers must treat
all results as read-only. Public calls still return independent mutable copies.
Queries with diagnostics, mutable opaque sets or a saturated cache keep their
existing fresh-result path. Query options, refusal causes and cache bounds are
unchanged. `BC2CPP_IR_SHARED_DEFINITIONS=0` retains the copying path for comparison.
See [ADR 0530](adr/0530-shared-reaching-definitions.md).

## Closed-world opacity queries

After construction finishes its source scans, each ClosedWorld caches the
outside-source touch predicate for declared owners. Declaration, boot/synthetic
owner, rebinding and dynamic-subclass guards still run on every query; only the
finalized touch result is cached. Native source-inclusive questions retain their
existing scan. A changed source universe requires a new world.
`BC2CPP_CLOSED_OPACITY_INDEX=0` disables this cache for comparison.
See [ADR 0534](adr/0534-bc2cpp-opacity-touch-cache.md).

## Unchanged load states

Numeric flow can share its incoming read-only state across repeated integer,
literal, pool, self, nil and string loads when the effective mask, element bound,
provenance and affected class tests are already unchanged. Oracle questions and
write-union collection still run. A per-Program MOVE-reader index narrows the
provenance checks; standalone transfer contexts retain their copying behavior.
`BC2CPP_NUMERIC_LOAD_COPY_ELISION=0` restores the copying load path.
See [ADR 0536](adr/0536-bc2cpp-unchanged-load-states.md).

### Ivar slot union fixed points

Each numeric-flow run retains the last widened mask for each tracked ivar slot.
When a call sees that same mask again, or the exact slot fact itself, its union
with the run's fixed slot fact is already known. Reuse the mask while still
invalidating provenance and class tests on every call. This retains one mask per
slot and never shares oracle answers between runs. Standalone transfer contexts
continue to read mutable slot facts without this cache.
`BC2CPP_NUMERIC_SLOT_UNIONS=0` restores unconditional slot unions for comparison.
See [ADR 0538](adr/0538-bc2cpp-slot-union-fixed-points.md).

### Embedding compile probe state

Embedding eligibility still compiles methods under isolated top-level state and
keeps clean-result caches local to each compiler instance. The state key list is
shared and restoration indexes saved values without temporary pairs. Nested
probes and exceptions restore the immediate caller's original state objects
(ADR 0202).

A warmed Ruby 4.0.5/YJIT full-engine comparison reduced compiler allocations
from 98,452,530 to 98,289,476 (163,054 fewer, 0.17%). Facts, receiver rows and
report JSON were byte-identical. Profiled elapsed time was essentially unchanged
(53.459s versus 53.405s). This reduces state-restoration overhead; the method
bodies are still compiled to determine eligibility.

Eligibility probes still emit each instruction, but skip register-copy propagation
and dead-write removal when no instruction text contains `#error`. Error-bearing
texts, entry-specialization runs and methods with runtime-installed names retain
the regular pass, preserving
cleanliness decisions and the emitted-text audit. Final C++ emission always runs
the regular pass. `BC2CPP_PROBE_REGISTER_FLOW=0` restores register optimization
inside probes. The scoped probe flag follows the same nested/exception restoration
as other method state. See [ADR 0537](adr/0537-bc2cpp-probe-register-text.md).

A warmed Ruby 4.0.5/YJIT full-engine comparison reduced compiler allocations
from 94,426,399 to 88,482,065 (5,944,334 fewer, 6.3%). Facts, receiver rows and
report JSON were byte-identical. Object-profiled elapsed time was 51.970s versus
50.382s in one pair; this is not a repeated timing benchmark.

### Reaching-definition query keys

Repeated IR proof queries reuse a bounded snapshot of opaque register names when
the input is an ordinary frozen Set containing only frozen Strings. Other frozen
containers and sets with mutable members still rebuild their snapshots, and
mutable containers and refusal diagnostics retain the uncached path. Register
strings are copied only when inserting a new query key, preserving caller
ownership and the existing canonical key order.

Both the query-result cache and the opaque snapshot identity memo retain at most
1024 entries per IR Program. Fresh result copies and shared immutable definitions
keep their existing APIs. `BC2CPP_IR_QUERY_KEYS=0` restores per-query key copying.
See [ADR 0542](adr/0542-bc2cpp-dataflow-query-keys.md).

A warmed Ruby 4.0.5/YJIT full-engine comparison on base `4ccd606d` reduced
allocations from 88,005,453 to 86,413,003 (1,592,450 fewer, 1.81%). Complete
facts JSON, receiver TSV and report JSON were byte-identical. One object-profiled
timing pair was 51.172s versus 50.805s; this does not establish a stable wall-time
speedup.

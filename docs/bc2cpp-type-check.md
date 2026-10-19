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
the mruby core mrblib, `--constants FILE` names the reviewed-constant list the TC1017 ratchet judges by (default: the
engine's `tools/bc2cpp/constant_reviewed_list.rb`; a `--files` program has no list unless one is given). The analysis takes the time of a build's analysis phase (minutes for the engine).

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
| TC1017 | error | the constant ratchet (ADR 0491): an engine constant with no type that `CONSTANT_REVIEWED` does not list, or a listed one that is now typed or gone |
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
`IO.open` is not typed (STDIN, STDOUT and STDERR stay untyped). mruby-io's `IO.open` (3rd/mruby/mrbgems/mruby-io/mrblib/io.rb)
is `io = self.new(*args); return io unless block`, so a blockless call returns Class#new on IO: an IO, never nil. That is
read from the source, not proven by a row. The proof stopped at `ClosedWorld#native_class_unshadowed?('IO')`, which is
false in the closed world (its write-count model counts IO as shadowed); the other gates (no closed-world `open` on
IO's singleton, `IO.new` stock, no non-core native `open`) hold. io.rb is a foreign Ruby source, so the registry has no
`IO.open` (`send_result:open(unregistered)`), and its `STDIN = ...` lines also poison the Fixnum proof by name. Typing
them needs that shadowing model reviewed; `IO` is not in `NATIVE_CONSTRUCT_TARGETS`, so `native_constructed_class` does not
reach it either.

## Constant ratchet (TC1017, ADR 0491)

An engine constant the analysis gives no type is untyped. The reviewed list `CONSTANT_REVIEWED` in
`tools/bc2cpp/constant_reviewed_list.rb` names the ones that were read and accepted as untyped, and the gate holds it to
two rules:

* an untyped engine constant that is not listed is a TC1017 error at its file:line;
* a listed constant that is now typed, or no longer an engine constant, is a TC1017 error at its line (or `-` when it
  is gone), so the list is pruned as constants get typed and it can only shrink.

With the list empty and every engine constant typed, the gate is a plain "no untyped constants" check. A `--files`
program is not judged unless `--constants FILE` names a list. The list is generated, not hand-edited:

```
MRBC=path/to/host/mrbc ruby scripts/bc2cpp/constant_reviewed_update.rb          # the diff, no write
MRBC=... ruby scripts/bc2cpp/constant_reviewed_update.rb --write                # after reading each added name
ruby scripts/bc2cpp/constant_reviewed_check.rb                                  # fixture + list format (needs MRBC)
```

The check runs in CI's `bc2cpp-build` job, after the closed-world build, with the host mrbc that build makes. The
type check step runs the gate on the real engine; the check fixes the gate's behaviour on small programs.

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
declares built-in or RGSS methods instead of the program's (ADR 0486); it is not a program hint.

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

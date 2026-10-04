# Core Ruby return classes

bc2cpp can prove the result of a zero-argument core Ruby collection method when
the receiver class and lookup are known. It analyzes the actual method bytecode
with that receiver and the supplied-block context. This lets later calls and
ivar pools retain an exact collection class across operations such as `map`,
`select`, `reject`, `partition`, `tally` and `Hash#to_h`.

For example, `[1, 2].map { |x| x + 1 }.size` proves the map result is an Array and
removes the size call's dynamic fallback. `[1, 2].map { break other }.size` keeps
dynamic lookup: the block can return `other` as the map result. Missing or
forwarded blocks also retain the original behavior.

The proof uses existing core lookup exclusions and analyzes changed source anew.
Overrides, aliases that replace lookup, prepends, unresolved mixins and dynamic
installers withdraw it. Descendant breaks in the caller block and nonlocal exits
in the callee also withdraw it. Splats, keyword calls, nonzero argument counts,
non-dominating block writers are not admitted by the receiver-specific proof.
Only exact Array/Hash/String results leave the specialized flow.
Interpreted-only core definitions, accessors, conditional/unmodelled aliases and
core Ruby installers retain lookup exclusions even after leaving the compiled
registry. Their effects also withdraw native helper facts inside this analysis.

Set `BC2CPP_CORE_RUBY_RESULTS=0` to measure the same source tree without these
facts. Use `MRBC=/path/to/mrbc ruby scripts/bc2cpp_coverage_report.rb` for the full
Wio census. The comparison must use the same tree: master gained additional
compiled block bodies after ADR 0337's 2,844-site measurement.

On the parent `a84d3b60` tree, the switch comparison reduces cached sites from
2,858 to 2,853 and all emitted by-name call lines from 2,919 to 2,914. Class ivar
pools increase from 190 to 191; argument/constant pools remain 136/796. Exact-index
arms increase from 1,026 to 1,032 and nil-receiver helper sites from 923 to 929.
These are static generated-code counts, not a runtime speed measurement; nil
helpers retain the existing nil error behavior.

Run the focused checks with:

```sh
MRBC=/path/to/mrbc BC2CPP_MRUBY_FULL=/path/to/full-core/build \
  ruby scripts/bc2cpp_core_ruby_results_check.rb
MRBC=/path/to/mrbc ruby scripts/bc2cpp_core_ruby_results_mutation_check.rb
```

The runtime check builds full-core mruby if one is not supplied. The mutation
check uses generated code and an unmutated control. See
[ADR 0338](adr/0338-bc2cpp-core-ruby-return-classes.md) for the oracle, width
validation and remaining proof boundaries.

## Results independent of the receiver class (ADR 0342)

For an unknown receiver, bc2cpp can join the actual return classes of every
compiled core definition of a name. Each body is analyzed with an unknown self
and the supplied-block context. The proof requires no linked native definition,
no project or outside Ruby replacement, no installer or alias of the name, and
no omitted or unmodelled core definition. A literal caller block must have no
descendant break. Missing and forwarded blocks keep their existing exclusions.

For example, `input.filter_map { |x| x }.size` can prove an Array result even
when `input` has no class fact. `input.reject { |x| false }` joins Array and Hash;
it never chooses one optimistically. An exhaustive native expression selection
can then implement `size` for that exact class set without a by-name fallback.
It requires an audited expression for every member, safe built-in lookup, and
no nil, unknown, subclass or other unrepresented class bit. Other sets retain
dispatch. Calls and their side effects still run normally.

`BC2CPP_CORE_RUBY_NAME_RESULTS=0` disables the new return proof;
`BC2CPP_NATIVE_EXPRESSION_UNIONS=0` disables exhaustive native selections.
Both switches preserve the receiver-specific proofs from ADR 0338.

On `7cad57bf` with the current native submodules, both proofs together remove
five cached sends (2,781 to 2,776). All five are RPG2k ordinary sends (1,569 to
1,564); block and helper counts do not change. Both switches off reproduce the
parent generated C++ byte for byte. These are static counts, not measured speed.

## Nested core collection results (ADR 0343)

The specialized core oracle can follow another zero-argument core Ruby call
with a dominating literal block and a known exact receiver class. For example,
Array's actual `sort_by` body ends in `ary.collect! { |e, i| self[i] }`. Analyzing
the selected `collect!` body proves that it returns its Array receiver, which
preserves the class of the outer `sort_by` result.

Every nested call retains the lookup, captured-write and block-exit exclusions
of the outer proof. Forwarded blocks and unknown receiver classes remain
unmodelled. A repeated specialization of the same bytecode, receiver class and
block context returns unknown, terminating recursive and mutually recursive
helper analysis. This analysis reads no growing class pools or return tables.

Set `BC2CPP_CORE_RUBY_NESTED_RESULTS=0` to retain the previous core oracle.
The existing result and mutation checks cover nested results, replacements,
caller breaks, recursion and the switch; runtime parity includes `sort_by`.

The same oracle analyzes argument-free `super` calls without a supplied block
along the known core receiver chain, refusing extra included modules. A pinned
Array-or-nil contract for Range's native `__num_to_a` helper lets the actual Ruby
`Range#to_a` body join its numeric path with the inherited Enumerable fallback.
Integer and String ranges therefore both prove Array results. The native range
body and its Array allocator must match the audited sources, and
`BC2CPP_NATIVE_CLASS_RESULTS=0` withdraws that helper fact.
Aliased super calls retain unknown results when the invoked method name differs
from the selected definition's name.

## Exhaustive core receiver results (ADR 0348)

The specialized core oracle analyzes every class in an exhaustive core receiver
set and joins their results. Array and Hash `map` both return Array, so a
following `compact` or `size` can retain that proof even when the original
receiver can be either collection. Every member must resolve through its audited
core lookup chain and produce a modelled result. Unknown receivers, unmodelled
members, method replacements and caller block exits withdraw the proof.

Complete core receiver flow sets also take precedence over collection inlining
hints. In particular, an Array-or-Hash `reject` result cannot justify an
Array-only `map` inline region.

Set `BC2CPP_CORE_RUBY_RECEIVER_UNIONS=0` to disable these specialized union
results while retaining the existing receiver-independent proofs. Generated-code,
mutation and interpreter parity checks cover both receiver paths, replacements,
unknown members, caller breaks and the switch.

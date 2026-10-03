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
subclass/unknown receivers and non-dominating block writers are not admitted.
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

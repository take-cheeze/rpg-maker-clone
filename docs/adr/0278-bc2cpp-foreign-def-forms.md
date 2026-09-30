# 0278. bc2cpp reads outside-Ruby definers from the syntax tree

Date: 2026-09-30

## Status

Accepted

## Context

`foreign_method_names` (tools/bc2cpp/native_names.rb) lists every method name that Ruby
outside the compiled world defines: mruby's own `mrblib` and the mrblib of every non-compiled
gem. It feeds `ClosedWorld` (`@outside_ruby_names`, `@outside_names`) and so the ADR 0210 /
0226 proofs (a guard chain that lists every definer ends in `bc2cpp_nomethod`, the guard of
an exact-class fallback is dropped), and the FIXNUM/ARRAY/class return proofs and MONO
decisions (ADR 0257 and older).

It matched `def` with a line-start regex. Any definition that does not begin a line was
invisible: `private def loop` (mruby's `Kernel#loop`), `protected def`, `public def`,
`module_function def`, `private_class_method def self.x`, `class Foo; def x; end; end`,
`class << self; def x; end; end` on one line, `x = (def y; end)`, `private attr_reader :x`,
`; attr_accessor :x`, `; alias a b`. A name defined only that way looked undefined outside
the closed world, so a complete-looking chain dropped its fallback although a Ruby
definition can answer the receiver.

## Decision

`foreign_method_names` also walks the Prism syntax tree of each outside file
(`ForeignDefNames`): every `DefNode` whatever its receiver or position, `alias`, and the
literal symbol/string arguments of `alias_method`, `define_method` and `attr*` (plus the
`=` writer for `attr*`). The former regexes stay, so the result is a superset of what it was
and only ever loses an optimisation, never soundness. A file that does not parse is reported
on stderr (the tree still recovers around the error).

`scripts/bc2cpp_foreign_def_forms_check.rb` (bc2cpp-checks `fast` shard) puts each form in a
fixture gem's mrblib and requires both that the name is collected and that the generated
guard chain keeps its dispatch instead of ending in `bc2cpp_nomethod`.

## Consequences

More names count as defined outside, which can keep a dispatch or refuse a return-type proof
where the old scan let it through; the wio numbers are in the pull request. Non-literal
installers stay covered by `RUBY_DYNAMIC` as before, and `# def x` in comments or strings is
still not a definition (Prism) though the retained regexes may over-collect it.

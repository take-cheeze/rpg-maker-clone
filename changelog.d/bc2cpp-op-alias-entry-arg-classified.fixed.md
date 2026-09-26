bc2cpp: classify OP_ALIAS in the entry-arg call-site proof

`ENTRY_ARG_CLASSIFIED_OPS` refuses any opcode that can carry a `:name` operand
but is not classified, rather than guessing whether it names a call site.
`ALIAS` was missing, so any closed world containing a Ruby-level `alias`
aborted the whole rpg2k codegen:

  ENTRY_ARG_CALLSITE_PROOF: opcode ALIAS names :append (":append\tpush") but is
  not classified -- refusing to guess whether that is a call site

`OP_ALIAS` is a definition opcode, not a call (vm.c:3597
`mrb_alias_method(mrb, target, irep->syms[a], irep->syms[b])`), so it belongs in
the same category as `DEF`/`SDEF`/`TDEF` and poisons its name under rule 7. It
is not reachable from the current world -- no compiled gem uses `alias` -- but
mruby-enum-ext's `enum.rb` does (`alias append push`), so any change that widens
the closed world to core mrblib hits it immediately.

Verified inert on today's world: the generated mruby-lcf-compiled.cpp,
mruby-rgss-compiled.cpp and mruby-rpg2k-compiled.cpp are byte-identical before
and after, apart from the output path recorded in the cross-gem include lines.

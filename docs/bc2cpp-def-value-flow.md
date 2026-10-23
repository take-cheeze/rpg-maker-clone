# Legacy definition value flow

The closed-world scanner resolves legacy `DEF` method bodies using the bytecode
IR's reaching definitions. mruby reads the body from `R[a+1]`; an unrelated
nearby `METHOD` cannot establish which body is installed.

The query follows moves, branches, loops and exception-handler predecessors.
Every reaching writer must be a `METHOD` naming the same existing child body,
and that body must be registered. Different bodies at a join, entry values,
clobbers, missing children and analysis refusals keep the definition unknown.
Registration of multiple bodies elsewhere does not prove their attribution to
this installation. Existing lexical scope tracking for unknown definitions is
preserved. Direct `TDEF` and `SDEF` handling is unchanged.

`scripts/bc2cpp/def_value_flow_check.rb` checks these cases with hand-built legacy
instructions and a binary compiler fixture for current direct definitions.

- **bc2cpp** compiles class-body initializers containing zero-argument lambdas
  that return literal data. Values remain lazy, with fresh containers and
  captured lexical constant lookup; the engine class-body planner now leaves
  no residual statements.

- **bc2cpp** class narrowing (ADR 0375): a runtime class test (`is_a?`, `kind_of?`, `instance_of?`, `C === x` and
  `case/when`, `nil?`, `!x`, `respond_to?(:m)`, `x.class == C`) narrows the tested variable's class set inside the
  region it dominates, through early `return`/`raise`/`next` and `&&`, `||` and `?:` joins, so receivers there lose
  their guard arms or by-name else (wio closed world: 35 fewer `bc2cpp_nomethod`, 33 fewer polymorphic chains, 4 fewer
  `bc2cpp_send`). Each narrowed test checks its claim at run time (`bc2cpp_guard_violation`, family `CLASS_NARROWING`).
  `BC2CPP_CLASS_NARROWING=0` restores the earlier output byte for byte; `scripts/bc2cpp_class_narrowing_check.rb` and its
  mutation check cover the forms, the negative worlds and the run against real mruby.

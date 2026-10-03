- Prove exact collection results from selected core Ruby bytecode, including
  literal-block calls without break, so downstream calls and ivar pools can
  eliminate more dynamic dispatch while preserving override and block-exit behavior.

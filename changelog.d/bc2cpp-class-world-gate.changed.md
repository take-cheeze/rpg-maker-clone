- **bc2cpp** (class graph gate): code generation now reads the class graph. `tools/bc2cpp/class_world_gate.rb` derives
  ClassWorld from the closed build's mrblib sources. `CodeGen#class_world_exact_target` calls the one public Ruby
  definition an exact receiver's ancestor chain reaches, behind the TYPED runtime class guard (`CLASS_WORLD_TYPED`),
  for a receiver whose class the flow names. `CodeGen#class_world_self_target` does the same for an implicit-self send
  in an instance method of a final, exact class (no subclass, body not shared by another owner), and runs only where no
  existing path gave a target. Native, module, unknown-mixin, prepended and installed names keep the owner call. On the
  closed build the output is unchanged: no owner-call site gains a direct form (the remaining self owner calls sit on
  native or non-final holders). `BC2CPP_CLASS_WORLD_DIRECT=0` turns both off. Check
  `scripts/bc2cpp/class_world_gate_check.rb`. See `docs/bc2cpp-class-bodies.md`.

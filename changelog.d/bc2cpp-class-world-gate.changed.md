- **bc2cpp** (class graph gate): code generation now reads the class graph. `tools/bc2cpp/class_world_gate.rb` derives
  ClassWorld from the closed build's mrblib sources, and `CodeGen#class_world_exact_target` calls the one public Ruby
  definition an exact receiver's ancestor chain reaches, behind the TYPED runtime class guard (`CLASS_WORLD_TYPED`),
  only when the receiver class and every ancestor are exact and nothing on the chain is native, a module, a prepend, an
  unknown mixin or an installed name. Other receivers keep the owner call. On the closed build the output is unchanged
  (no owner-call site has a receiver class the gate accepts). `BC2CPP_CLASS_WORLD_DIRECT=0` turns it off. Check
  `scripts/bc2cpp/class_world_gate_check.rb`. See `docs/bc2cpp-class-bodies.md`.

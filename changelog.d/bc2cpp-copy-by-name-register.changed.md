- **bc2cpp** installs compiled methods before local class-body statements copy
  them by name, allowing their residual bytecode to be removed. Methods remain
  interpreted when any required copy site cannot install the compiled entry.

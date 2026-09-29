- bc2cpp resolves bare self-calls inside compiled `module_function` bodies to
  emitted singleton copies when the module and method lookup are closed-world
  stable.

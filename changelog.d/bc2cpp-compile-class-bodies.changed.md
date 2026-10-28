- **bc2cpp** (LOAD_COMPILE): the engine gems' class and module bodies -- nesting, `include`/`extend`/`prepend`,
  `attr_*`, visibility, `alias`, literal and pure constants, class ivars -- run as generated C++ instead of mruby
  bytecode, and the defs the stub proof lets go are dropped from the residual mrblib instead of being emptied.
  `BC2CPP_LOAD_COMPILE=off|defs|all` (default `defs`: only the dropped defs leave the bytecode, no load code;
  `all` also compiles the statements, behind a residual marker so a build that loads the full mrblib is unchanged).
  Every body keeps a bytecode fallback statement by statement. New `tools/bc2cpp/class_world.rb` writes the class
  graph facts (superclass, ancestors, singleton chain, final, reopened, evaluated vs bytecode bodies); nothing
  consumes it yet. Check `scripts/bc2cpp/class_body_check.rb` compares the interpreted and the compiled load, and
  the facts with the interpreted graph; report `scripts/bc2cpp/class_body_report.rb`. See
  `docs/bc2cpp-class-bodies.md`.

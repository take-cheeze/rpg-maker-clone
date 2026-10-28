- **bc2cpp** (LOAD_COMPILE): `BC2CPP_LOAD_COMPILE` now defaults to `all`: the engine gems' class and module bodies run as
  generated C++ at boot, and 35 fewer bytecode bodies start at boot (420 to 385). `all` did not pass the host sweep before:
  an `alias_method` above a redefinition of the same name (`Array#sort!`, `RGSS::Window#initialize`) held the override,
  not the original, and the first sort recursed until a `SystemStackError`. A compiled send or alias that a later def of
  the same owner redefines now stays in the residual mrblib, and a def that a compiled attr or alias overrides is kept.
  Runs of data constants are one byte table and one decoder call (the load code is 107 KB at `-Os`, not 123 KB); an Integer outside 32 bits stays bytecode. The
  statements that stay bytecode are a checked list in `scripts/bc2cpp/class_body_check.rb`. Statement compilation costs
  about 58 KB of text against 49 KB of irep at `-Os`; see `docs/bc2cpp-class-bodies.md` for the measurement.

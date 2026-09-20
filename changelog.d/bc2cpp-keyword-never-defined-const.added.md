- **bc2cpp** closes the optcarrot scoping probe's last open keyword site, a
  general bc2cpp gap (KEYWORD_NEVER_DEFINED_CONST_RECEIVER_SUPPORT). When
  every keyword-free proof declines a keyword `SEND` whose receiver is the
  value of a `GETCONST` for a constant defined *nowhere* in the closed world
  (no SETCONST/SETMCNST, no CLASS/MODULE, no native
  `mrb_define_const`/`const_set`/`define_class`/`define_module`, no
  foreign-source assignment), the path proves the send dynamically
  unreachable instead -- that GETCONST's own scope chain raises NameError
  before the send can execute, with no jump or handler entry landing between
  the two -- and emits the faithful OP_SEND shape anyway. The optcarrot
  probe goes 99.7%→100.0% (382→383; `NES#run`'s `StackProf.start(mode:, out:,
  raw:)` now compiles, zero `#error` markers remain); the real project's
  whole-program diagnostic -- stats report, raw output and shipped method
  set -- is byte-identical with and without the change.

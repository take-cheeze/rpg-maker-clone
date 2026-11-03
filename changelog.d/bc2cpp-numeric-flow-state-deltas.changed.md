- **bc2cpp** compiler: NumericFlow writes each transfer into one of two scratch buffers and keeps a straight-line
  instruction's state as the entries its predecessor changed, built into an Array only when a reader asks for it.
  The worklist, joins and oracle questions are unchanged, and the generated C++ is byte-identical. The sealed
  Optcarrot compile allocates about 2.5% fewer host objects, runs three fewer GCs and peaks about 12 MB lower. Set
  `BC2CPP_NUMERIC_STATE_DELTAS=0` to restore the copied states. See
  [NumericFlow state deltas](docs/bc2cpp-numeric-flow-state.md).

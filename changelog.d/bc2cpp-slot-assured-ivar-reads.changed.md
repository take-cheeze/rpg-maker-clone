- **bc2cpp**: a compiled read of an embedded ivar now skips its unset-slot (`undef`) test when every
  constructor of the family assigns the ivar and the read cannot run while an instance is built
  ([SLOT_ASSURED](docs/bc2cpp-slot-assured.md)). A literal argument of a construction-time self-call
  (`reset(mapping: false)`) leaves the arm it switches off out of that reach. In the optcarrot probe the
  frame loop drops from 42.72M to 38.53M instructions per frame (callgrind). `BC2CPP_SLOT_ASSURED=0` restores
  the test, and `BC2CPP_SLOT_ASSURED_REPORT=1` prints the per-family proof. New check
  `scripts/bc2cpp/slot_assured_check.rb`.

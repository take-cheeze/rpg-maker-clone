- **bc2cpp**: a resumable (Fiber-yielding) method's step function keeps its registers in C++ locals between
  yields and stores them back into the frame at each yield, instead of reading and writing the frame on every
  access ([RESUMABLE_LOCAL_REGISTERS](docs/bc2cpp-resumable-locals.md)). A body that takes a register's
  address keeps the frame references. In the optcarrot probe the frame loop drops from 36.00M to 33.73M
  instructions per frame (callgrind). `BC2CPP_RESUMABLE_LOCALS=0` restores the references. New check
  `scripts/bc2cpp/resumable_locals_check.rb`.

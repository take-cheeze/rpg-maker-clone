- **bc2cpp**: a `freeze` of a core iterator's result on a builtin literal (`(0..n).map { }.freeze`) no longer
  stops the closed world from proving that user objects are never frozen, so embedded ivar stores keep
  dropping their frozen test ([FRESH_BUILTIN_FREEZE](docs/bc2cpp-fresh-freeze.md)). In the optcarrot probe
  this removes all 830 frozen tests, and the frame loop drops from 42.72M to 40.83M instructions per frame
  (callgrind). `BC2CPP_FRESH_FREEZE=0` restores the refusal. New check `scripts/bc2cpp/fresh_freeze_check.rb`.

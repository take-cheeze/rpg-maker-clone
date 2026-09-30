- **bc2cpp compiles `blk.call(...)` on a core method's own `&blk` without a
  send.** The receiver is proven to be the block the method was entered with
  (nil or a Proc), so the site is a Proc call plus a NoMethodError arm for nil.
  `BytecodeIR` now gives OP_ENTER its optional-argument jump table as
  successors, so dataflow through methods such as `Integer#step` and
  `Array#find` no longer refuses.

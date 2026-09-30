- **bc2cpp proves blocks yield-free and keeps compiled iterators under Fibers**
  (`tools/bc2cpp/yield_reach.rb`, `docs/adr/0283-bc2cpp-yield-free-blocks.md`): a
  whole-program by-name analysis of the closed world decides which compiled blocks
  and which core iterator bodies can never reach a `Fiber.yield`. Such a block is
  flagged in its env; `Array#each`, `Integer#times`, `Enumerable#map` and the rest
  of the guarded core iterators stay compiled while a Fiber runs when they run one,
  and the BLOCK_CORE_DIRECT arms of such a block drop the root-context test. The
  set of methods refused because a `Fiber.new` body can reach them and they may
  yield now follows every call edge (explicit receivers, other classes, blocks),
  closing the gap that left a compiled frame between a Fiber and its yield. The
  build prints the proof counts; covered by `scripts/bc2cpp_yield_reach_check.rb`
  and `scripts/bc2cpp_yield_free_check.rb`.

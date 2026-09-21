- **bc2cpp** lowers guarded exact-Array pushes and clears, reuses the Optcarrot
  PPU frame buffer's backing storage, and lowers Fixnum arithmetic,
  comparisons and right shifts in the closed-world probe. ROM loading and PPU
  frame setup compile at their pre-Fiber boundaries, and the base Video#tick
  hook compiles after PPU Fiber work returns.

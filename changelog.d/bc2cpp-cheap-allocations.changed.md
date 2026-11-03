- **bc2cpp** compiler: the ENTER field predicates index the field list instead of slicing it, the native
  BasicObject scan splits only files that spell `BasicObject` into lines, op lists built from Sets are frozen
  constants instead of per-irep splats, reaching definitions reuse a scratch Set, and the resumable step function
  collects registers in its existing `gsub` pass. The sealed Optcarrot compile allocates about 2.4% fewer host
  objects; the generated C++ is unchanged. See [cheap allocations](docs/bc2cpp-cheap-allocations.md).

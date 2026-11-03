- **bc2cpp** analyses stop building Arrays and Sets only to iterate or test
  them: fixpoint meets use `all?` over the predecessor list, `case ... when
  *SET` matches the Set directly, and the native-core audit, method-resolution
  walk and register-flow edges reuse their lists. The sealed Optcarrot compile
  allocates about 5.8% fewer host objects; the generated C++ is unchanged. See
  [collection allocations](docs/bc2cpp-collection-allocations.md).

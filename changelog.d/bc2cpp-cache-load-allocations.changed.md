- **bc2cpp** compiler: the outside-world token Set is read from the scan cache once per compile instead of
  three times. The sealed Optcarrot compile allocates 0.58% fewer objects warm (0.45% cold), and its C++ is
  byte-identical. `docs/bc2cpp-cache-load-allocations.md` also records why the `NumericFlow` state copies
  keep using `Array#dup`.

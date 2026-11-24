- **bc2cpp**: the Wio Terminal firmware is 20.4 KB smaller (FLASH 1543812 -> 1523432 B, RAM -424 B).
  - The blocks of a core method the closed build leaves out no longer stay in the image through their
    `Proc#arity` spec (`Enumerable#chunk`, `#chunk_while`, `#zip`, `#minmax`, ...).
  - The core entries the closed build leaves out are now decided from the generated code's lookups rather than
    every engine symbol, and an owner call counts only for the classes it lists (`Comparable#clamp`,
    `Array#fetch`, `#to_h`, `#uniq`, `Hash#compact`, ...).
  - New verify mode, `BC2CPP_CLASS_REACH_VERIFY=1` (also in the `bc2cpp-sweep` verify build).

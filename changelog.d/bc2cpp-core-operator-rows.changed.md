- **bc2cpp**: operator methods of mruby's core classes (`Array#<<`, `Integer#**`, `String#+@`, …) leave the closed
  build's method table when nothing looks them up by name. Closed host table 642 → 629 entries.

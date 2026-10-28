- **`Proc#call`, `Proc#[]` and `BasicObject#!=` are C functions in the mruby
  fork.** They were static bytecode procs (`OP_CALL`; `OP_EQ` + a jump), so
  each stayed an entry the closed build's VM had to run. The fork now defines
  them as cfunc methods with the same behaviour (`Proc#call` replaces its frame
  with the proc's, as `OP_CALL` did; `!=` negates a sent `==`, so a user-defined
  `==` still counts). Removes two of the bytecode method-table entries listed in
  `docs/bc2cpp-vm-entries.md`.

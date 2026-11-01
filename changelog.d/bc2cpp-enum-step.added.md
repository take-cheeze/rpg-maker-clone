- **bc2cpp** `BC2CPP_ENUM_STEP=1` (off by default) compiles the `Array#each` a
  fiber runs in step form: a compiled step returns one element at a time to a
  shared Ruby driver that makes the block call, so `Enumerator#next` over an
  Array suspends through VM frames only. Prototype for one method; see
  `docs/bc2cpp-enum-step.md`.

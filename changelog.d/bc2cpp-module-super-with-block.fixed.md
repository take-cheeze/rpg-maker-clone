- **bc2cpp** compiles `super` that resolves through an included module, carrying
  the current frame's block to the module body (ADR 0329). This clears five of
  the whole program's `#error` markers — `Range#max`, `Range#min` and
  `Range#to_a`, whose `super` reaches `Enumerable` — taking the total from 21
  to 16. `BC2CPP_MODULE_SUPER=0` restores the previous behaviour.

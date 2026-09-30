- **bc2cpp**: a compiled block that neither breaks nor returns gets a direct entry
  (`*_direct`), its proc is built over one shared thunk, and yields from compiled
  code (`yield`, the core `block.call`, keyword-splat calls, `Proc#call` on a cfunc
  proc) call the entry without pushing a VM frame (ADR 0271). A `map` or `select`
  over a small Array measured about 27 percent faster on a closed-world fixture;
  `BC2CPP_BLOCK_DIRECT_ENTRY=0` keeps the cfunc wrapper.

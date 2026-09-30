- **bc2cpp**: a compiled `rescue` (and `ensure`) now sets `$!` like the VM's
  `OP_EXCEPT`, so a bare `raise` inside a handler re-raises the rescued
  exception instead of a fresh `RuntimeError ""`, and `$!` reads the rescued
  exception inside the handler and is dropped when the compiled frame returns.

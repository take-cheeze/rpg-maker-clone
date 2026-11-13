- **bc2cpp:** a core method's resumable copy (the one a Fiber runs) reads
  `self[i]` through the shared index helper instead of a by-name `[]` send. A
  subclass's own `[]` still runs. All 32 by-name `[]` sends in the compiled core
  library go away.

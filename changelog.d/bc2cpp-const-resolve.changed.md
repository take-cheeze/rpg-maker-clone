- **bc2cpp**: every constant read in a class body (`GETCONST`, `GETMCNST`) must name a constant the build binds before the
  body runs. The names come from the bytecode IR's constant table and the native sources; unresolved reads are collected
  during the class-body compile phase, and the build fails once at the end of that phase with the full list.

- The closed build's compiled class-body load (`BC2CPP_LOAD_COMPILE=all`) now runs the class structure from a byte
  program and one small decoder per gem instead of a C++ call sequence per statement: nesting and creation, superclass,
  `include`/`extend`/`prepend`, `attr_*`, visibility, `alias`/`alias_method`, class ivars and every constant (any pure
  call is a value the bytes can spell now, not only data). Same calls, same order, same arena handling as before. At
  `-Os` the three engine gems' load drops from 103,165 to 59,757 bytes of text and loses its 3,920 bytes of relocated
  data. A world that defines `inherited`, `included`, `extended`, `method_added` or the like keeps the statements the
  hook observes as C++ of their own and never drops the hook defs. `docs/bc2cpp-class-bodies.md`.

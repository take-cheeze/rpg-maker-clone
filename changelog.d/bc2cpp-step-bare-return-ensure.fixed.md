- **bc2cpp** C++ Fiber: a bare `return`, `next` (`RETNIL`, `RETTRUE`, `RETFALSE`, `RETSELF`) inside a `begin ... ensure` region of a
  step skipped the ensure body; only `RETURN`, `RETURN_BLK` and `BREAK` were refused. All of them now run the ensure first.

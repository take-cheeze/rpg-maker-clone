- **bc2cpp** compiles `blk.call(*args)` on a core method's own `&blk` (the 28 splatted
  `Enumerable` block calls) to a Proc yield with a NoMethodError else arm, removing the last
  by-name `"call"` dispatch from generated core bodies (ADR 0372).

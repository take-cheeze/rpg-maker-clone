- **Compiled blocks:** `block.call(...)` on a compiled block now runs the block's
  direct entry whenever `Proc#call` is the builtin, whichever gem built the
  block; a Ruby-level `Proc#call` override is honoured (a compiled call used to
  skip it) and the VM entries for block calls in a headless sweep fell from
  13,163 to 5,227.

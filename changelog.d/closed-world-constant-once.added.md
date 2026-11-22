- **Closed-world lint:** `Dynamic/ConstantReassignment` rejects a constant in
  the bc2cpp-compiled engine Ruby that is written at more than one site, inside
  a block or loop, or with `||=`/`&&=`/`op=`, so every constant has exactly one
  definition that runs once.

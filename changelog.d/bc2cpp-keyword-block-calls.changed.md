- **bc2cpp compiles a call with keywords and a literal block, and a `break`/`return`
  out of a block with an `ensure`.** Both left the whole surrounding method
  interpreted before; they now compile in plain methods and Fiber steps, with
  interpreter-equal results. See `docs/bc2cpp-cxx-fiber.md`.

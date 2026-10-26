- **bc2cpp**: static owner dispatch accepts boxed Integer, boolean and nil
  arguments, allowing more calls to compiled Ruby bodies behind exact-class
  guards while retaining the original fallback for other receivers.

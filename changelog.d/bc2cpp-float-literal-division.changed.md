- bc2cpp resolves `/` directly for Float literal receivers when the native
  Float implementation is proven safe, while preserving Complex dispatch.

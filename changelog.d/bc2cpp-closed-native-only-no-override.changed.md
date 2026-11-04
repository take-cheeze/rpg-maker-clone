- **bc2cpp:** the closed build is native-only with no override. `BC2CPP_NATIVE_ONLY=0` no longer keeps mixed
  native/bytecode dispatch, so bytecode is refused in the closed runtime's root context and in Fibers.

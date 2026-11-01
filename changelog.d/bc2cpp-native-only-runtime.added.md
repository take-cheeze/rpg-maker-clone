- **bc2cpp** makes the closed RPG2k target native-only: bytecode decoding,
  source compilation, and binary loading/dumping are omitted. Native
  continuations retain Ruby frames and Fibers; injected bytecode fails in
  both root and Fiber contexts. Bootstrap compilers remain ordinary builds.

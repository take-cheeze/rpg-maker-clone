- Factor Optcarrot bytecode IR dispatch guards by arity, include direct storage
  method arms, and shorten common instruction/addressing guard paths while
  preserving the original computed-send fallback.

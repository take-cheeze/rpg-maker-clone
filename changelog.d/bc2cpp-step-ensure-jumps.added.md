- **bc2cpp** C++ Fiber: a step may `return`, `break` and `next` out of a `begin ... ensure` region (the ensure body runs, may
  suspend, then the jump continues, through nested ensures and past an exception raised by an ensure body), as vm.c does with a
  break object; before, the method stayed interpreted. `retry` in a rescue clause of a step is covered by scenarios with a
  yield in the region, in a CALLed frame that raises, in a block step and under an ensure.

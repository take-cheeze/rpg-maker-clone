- **bc2cpp**: a method with optional positional parameters now gets argument
  class pools for its mandatory parameters (they were refused outright), so
  an argument every caller passes as one class reaches the method, and the
  methods it is passed on to, without a class-test chain.
  `BC2CPP_OPTIONAL_ARG_POOLS=0` restores the old admission.

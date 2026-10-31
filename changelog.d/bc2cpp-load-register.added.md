- The bc2cpp load planner can install a compiled method from the class program
  itself, just before the class-body statement that runs it at load
  (`EARLY_REGISTER`). `LoadCompile.plan` takes a `register:` map of use sites
  and emits the step through the existing `BC2CPP_LD_FNS` side table; an owner
  the program does not create is resolved by its absolute path
  (`bc2cpp_ld_owner`). `MrblibStubs.stubbable` now returns that map beside the
  drop set, and `StaticDispatchRegistrations.load_phase` returns the call-site
  edges it walks (`BC2CPP_LOAD_TRACE=<regexp>` prints them). No def is dropped
  yet: a use site the planner does not compile keeps its def, so the emitted
  output is unchanged.

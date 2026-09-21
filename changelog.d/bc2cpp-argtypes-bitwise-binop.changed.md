- **bc2cpp**'s call-site argument-type inference (`ArgTypes.analyze`) now
  passes the whole-program registry into its own `IvarLayout.trace_type`
  call, so a MONO method's Fixnum-typed argument can also be proven through
  a `%`/`&`/`|`/`^` call-site expression, the same way `IvarLayout.analyze`
  itself already can. Verified byte-identical for the real project and the
  Optcarrot probe; no current call site fits the shape yet.

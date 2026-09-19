- **bc2cpp** now compiles a bare `super` (zsuper) that forwards the current
  method's own arguments to a *compiled Ruby superclass* method (zsuper general
  support). The `ARGARY m1:0:0:0 (0)` + `SUPER n=*` pair is recognized per site
  from the bytecode (mrbc's own `codegen_zsuper`; vm.c's `OP_ARGARY` `lv==0`
  proves the forwarded args are literally `r1..m1`) and emitted as a direct
  `Super#name_impl(M, self, r1, …)` with the dead argument array suppressed — no
  allowlist, no hand-vetted facts: requiring the superclass method to compile
  clean makes any forwarded block unobservable, and ADR 0158's mixin scan proves
  no `include`d module intervenes. The optcarrot probe goes 94.5%→96.3% (7 APU
  sites); the real project is byte-identical (ADR 0159). Covered by
  `scripts/bc2cpp_include_ancestor_check.rb`.

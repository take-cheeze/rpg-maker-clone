# Generated lexical constant lookup

Bare constants in compiled methods search the owner's lexical scopes from
innermost to outermost, then Object. The generator shares one C++ helper per
owner path rather than repeating the path reconstruction and search at every
GETCONST instruction. Different constant names pass their interned symbol to
the same helper. Top-level Object lookups remain direct calls.

The helper reconstructs the complete scope path before searching it, preserving
errors for missing enclosing scopes. It uses the existing non-raising probes
for intermediate scopes and the ordinary raising lookup for the Object
fallback. Constant values are not cached: reassignment remains visible, and
mruby's arena continues to protect values allocated while resolving the path.
The existing proven class-constant cache uses this helper on its slow path.

`ruby scripts/bc2cpp/const_lookup_check.rb` checks helper sharing, lexical
shadowing, outer and Object fallbacks, reassignment, missing constants and GC
against a real mruby library. Set `BC2CPP_MRUBY_CORE` to a built mrbc directory
containing `include/` and `lib/libmruby_core.a` to run the behavioral checks.

A full RPG2k source sample decreased from 19,695,404 to 17,099,986 bytes
(13.2%), and from 386,389 to 336,973 lines (12.8%). It contains 4,874
lookup calls sharing 92 owner helpers. This is a source-size measurement;
optimized binary size and runtime performance depend on the C++ compiler's
inlining decisions.

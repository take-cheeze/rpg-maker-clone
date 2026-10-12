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
GCC 15.2 at `-O0` also reduced the object from 12,834,984 to 10,416,752
bytes (18.8%), with its text section decreasing from 9,583,112 to 7,576,386
bytes (20.9%). Optimized binary size and runtime performance depend on the
C++ compiler's inlining decisions.

## Constant definitions in the numeric and class pools

The numeric proof and the class pools (ADR 0276, 0296, 0301) read a constant's class set from the definitions it
reaches. Those are keyed by the definition's qualified name, resolved lexically by `tools/bc2cpp/lexical_consts.rb`
(ADR 0423): a bare read takes the first scope of its lexical chain that defines the name, and is refused (falls back
to the integer-constant proof or OTHER) when another definition reachable from that lookup could be read instead.
`Game::Character::TURN_LEFT` and `Game::MoveRoute::TURN_LEFT` therefore keep their own pools. `BC2CPP_LEXICAL_CONST=0`
keys by bare name again.

`ruby scripts/bc2cpp/lexical_const_check.rb` checks the resolution and each refusal against compiled fixtures (it needs
`MRBC`).

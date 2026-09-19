# 0159: bc2cpp general zsuper — `super` forwards its own args to a compiled superclass

Date: 2026-09-19

## Status

Accepted.

## Context

ADR 0158 made `super`'s "no intervening `include`d module" fact re-derivable and
wired the guard into the fixed-count `SUPER_TARGETS` path. That still leaves the
bare `super` (zsuper) that forwards the CURRENT method's own arguments to a
**compiled Ruby superclass method** on `#error`: the `SUPER_TARGETS` fixed path
only handles explicit `super x, y` (`SUPER ... n=N`), and `ZSUPER_NATIVE_*` only
handles `super` reaching a native mruby C method. The optcarrot scoping probe
(`tools/optcarrot_probe`) hit exactly this on seven APU sites (`Pulse/Triangle/
Noise#initialize`, `Pulse/Triangle#poke_0`, `Pulse/Triangle#poke_3`) — a clean
zsuper forwarding to `Oscillator`'s same-named compiled method, otherwise
uncompilable.

## Decision

Add `CodeGen#zsuper_forward_plan` (+ `compile_zsuper_forward`) recognizing
mrbc's own `codegen_zsuper` pair (`vm.c` `OP_ARGARY`/`OP_SUPER`, all re-checked
per site from the bytecode, no name list):

```
ARGARY R(a+1)  m1:0:0:0 (0)   # lv==0 => packs THIS frame's regs[1..m1]
SUPER  R(a)    n=*            # superes ci->mid, reading that array
```

`OP_ARGARY` with `lv==0` copies `regs + 1`, so the forwarded positional arguments
literally ARE the current method's parameter registers `r1..rm1` — reproduced
directly as `r{a} = Super#name_impl(M, self, r1, ..., rm1)` with the ARGARY's
array build suppressed. `plan` accepts an index naming either half of the pair,
so the `ARGARY` and `SUPER` arms can never emit half a translation.

The plan fires only when every gate holds:

- adjacent `ARGARY`/`SUPER` at the `SUPER R(a)`/`ARGARY R(a+1)` register relation;
- the SUPER is exactly `n=*` (not fixed `n=N`, not the `nk=`/keyword form);
- the ARGARY operand is `m1:0:0:0 (0)` (no rest `r`, no post-mandatory `m2`, no
  keyword dict `kd`, `lv==0`) — so the forwarded set is exactly `r1..m1`;
- the CURRENT method's `ENTER` (`REQ:OPT:REST:POST:KEY:KDICT:BLOCK:NOBLOCK`) is
  `REQ==m1` with `OPT/REST/POST/KEY/KDICT/BLOCK` all 0 — parameters ARE `r1..m`
  and there is **no block parameter** for zsuper to forward;
- the superclass's same-named method exists, is bytecode-defined and
  `compiles_clean?`, and `super_reaches_superclass?` (ADR 0158) proves no
  `include`d module sits between the class and that superclass.

Crucially, requiring the **target compiles clean** replaces the caller-site block
grep the allowlisted `SUPER_TARGETS` fixed path leans on: a clean `_impl` has no
block parameter and never yields, so whether a caller passed a block into the
current method is unobservable here — so this path needs no allowlist and no
hand-vetted facts at all.

## Consequences

- optcarrot probe: 362→369 bytecode methods compiled, `94.5%`→`96.3%`; the seven
  APU sites compile with `Super#name_impl(M, self, r1, ..)` emitted and the ARGARY
  suppressed.
- Real project unchanged (byte-identically): `docs/bc2cpp_coverage.txt` has zero
  `#error`s, so no real method had an unhandled `SUPER n=*`+`ARGARY` pair — the
  new path fires nowhere in the real gems, and cannot change a `super` already
  compiled by the fixed or native path (those branches are checked first).
- A method whose superclass method is NOT clean, that has a block parameter, or
  whose class includes a module still falls through to the same honest `#error`.
- Covered by the extended `scripts/bc2cpp_include_ancestor_check.rb` (synthetic
  world: clean shape fires and agrees from either pair half; block-param and
  include-guard owners decline; emitted `_impl` forwards `self, r1, r2`).

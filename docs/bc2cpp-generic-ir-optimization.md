# General bytecode IR optimization

Optcarrot is a workload for measuring the compiler, rather than a source of
compiler rules. The probe now concatenates upstream Ruby with compatibility
shims and the benchmark runner. It does not rewrite opcode dispatch, replace
the Fiber PPU, factor the tile initializer, or install an exact-IREP LUT helper.
The CPU-specific IR pass and its fixed-core contract are removed.

General method inlining (`BC2CPP_IR_INLINE=1`) and yield-free helper inlining
inside resumable methods (`BC2CPP_IR_RESUMABLE_INLINE=1`) remain available.
Their eligibility comes from decoded instructions, call graphs, register
liveness, and control-flow/suspension proofs, rather than workload names.
Compatibility shims, the sealed-host manifest, and configurable GC stack size
remain benchmark infrastructure.

## Recovering performance through general proofs

| Idea | IR evidence required | Performance opportunity |
| --- | --- | --- |
| Bounded computed-send specialization | Finite Symbol value set propagated through constant arrays, branches, arguments and call summaries; builtin send identity guard; normal dynamic fallback | Expose indirect opcode/helper calls to existing direct dispatch and inlining without listing method names |
| Splat scalar replacement | Fresh Array creation, known shape and element values, no escape or alias observation; preserve coercion, evaluation order, dispatch and exception behavior | Remove a temporary Array per indirect call instead of merely adding guards after allocation |
| Loop invariant motion and CSE | Dominance, integer interval/width facts, stable builtin identities, no observable effects between reads | Avoid repeated table/address arithmetic and bit extraction |
| Compiled initializer execution | General class/module-body IREP entry support and identical constant/method installation ordering | Reach startup loops before class-body constant assignment without source extraction |
| Pure map/transpose fusion | Proven pure block, finite bounds, target-width arithmetic, array freshness and independent mutable rows | Lower table construction to native loops and improve traversal order without matching one initializer |
| Resumable region fusion | Exact continuation identity, no suspension or escaping Fiber in the fused region; live register and GC root proof | Reduce Fiber/helper overhead while preserving every observable yield boundary |

Existing computed-send name analysis is the first tier: extend its proven value
sets rather than introducing registry guesses without runtime send identity
guards. Guards must use compiler intrinsics with explicit effects, preserve
argument capture, and keep ordinary Ruby lookup and missing-method behavior.

Prioritize computed-send value sets and splat escape proofs, then initializer
reachability and pure loops. Add bounded expansion budgets and fallback paths;
rebuild the registry and effects analyses after graph changes. Class/method
names, source-text fingerprints, ROMs, and fixed table bounds must not be
optimization eligibility conditions. Profile allocations and GC separately
before attributing long-run regressions to either.

## Measurement limits

The earlier fastest workload-specific preset measured 212.32 wall FPS for
180 cold frames and 254.37 for 1,800 frames on the local Ryzen AI MAX+ 395.
Those figures included source-generated CPU/synchronous PPU and native LUT
startup and are **historical**, not the generic path's current performance.
The native LUT saved about 103 ms per process; this did not establish a
steady-emulation improvement. The general resumable-helper inliner showed
no measurable speedup in its previous paired comparison.

Compare the general path with upstream CPU dispatch, Fiber PPU, and initializer
unchanged in both sides. Require pixels/audio/RAM/register equivalence and
checksum agreement, alternate repeated runs, and report startup separately
from longer workloads. Do not promise performance parity before measurement.

```sh
BC2CPP_IR_INLINE=1 BC2CPP_IR_RESUMABLE_INLINE=1 \
  ruby tools/optcarrot_probe/compiled_run.rb 180
```

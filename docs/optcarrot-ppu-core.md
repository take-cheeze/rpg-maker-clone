# Optcarrot synchronous PPU core

`OPTCARROT_STATIC_PPU=1` generates upstream's synchronous PPU core on the host
with clock specialization, fast paths and batched pixels. An ordinary
`PPU#run` replaces the Fiber entry, giving bc2cpp the full loop as compiler
input. The same replacement appears in the executed bundle.

```sh
OPTCARROT_STATIC_DISPATCH=1 OPTCARROT_STATIC_PPU=1 ruby tools/optcarrot_probe/compiled_run.rb 180
```

This is an opt-in choice for the ordinary compiled host. Interpreted mruby is
slower with this core. The original Fiber path remains the default, and the
upstream submodule is untouched. The console and summary identify the core
and report whether PPU#run compiled; its unused main_loop may still compile.

Prism selects only the instance method inside `Optcarrot::PPU`; singleton
methods, other classes, nested classes and code-looking strings are ignored.
The rewrite preserves all source outside the AST byte range and rejects
changes to its upstream source/entry contract. Upstream produces the body;
this is not a general AST compiler. See [ADR 0405](adr/0405-optcarrot-synchronous-ppu.md).

Strict sealed-world mode currently rejects this combination: without the
Fiber roots, its registry exposes unmodeled computed Config accessors and
unreviewed NoMethodError fallbacks. The benchmark does not bypass that gate.

Further compiler-only checks found that replacing the computed Config readers
with literal declarations still leaves 57 unreviewed fallback sites, including
PPU-to-CPU clock calls and NES-to-PPU frame calls. These are live methods with
unresolved receiver proofs; adding them to a dead-branch allowlist would not
establish that proof. The sealed host's unused socket Ruby also disables
`POOL_SELF_CLASS` by spelling `bind`. Removing that gem re-enables the analysis
but exposes 101 sites instead of clearing the gate. Constructor inference is
independently refused because `Optcarrot::CodeOptimizationHelper`, a module
used by upstream's host-side generators, defines `initialize`. The constructor
diagnostic now names such owners. These checks make no native FPS claim, and
neither experimental rewrite is enabled.

Validation compares full pixel and audio arrays, RAM and captured CPU/PPU
registers at 1, 2, 30, 60, 180, 181 and 360 frames. AST checks cover Unicode
byte offsets, neighboring definitions, duplicate entries and source drift.
Run `ruby scripts/optcarrot/ppu_core_check.rb`. CI also runs the compiled mode.

The check also accepts a ROM path followed by positive frame counts, allowing
longer runs and additional games without changing the default CI workload:

```sh
ruby scripts/optcarrot/ppu_core_check.rb path/to/game.nes 2 180 1800
```

Broader validation passed for all six bundled games: Alter Ego, Lan Master,
Lawn Mower, Zooming Secretary, DABG and Thwaite. At 2, 180 and 1,800 frames,
all 18 full-state comparisons matched. All 36 native Fiber/synchronous
executions also matched those checksums. These were correctness runs rather
than performance measurements; the preset remains opt-in.

Three alternating release pairs per workload, static CPU dispatch and a
16,384-pointer GC stack in both builds:

| Workload | Fiber core | Synchronous core | Ratio |
| --- | ---: | ---: | ---: |
| 180 frames, cold | 1.107 s | 0.891 s | 1.242× |
| 10 × 180 frames, fresh NES each | 10.115 s | 7.921 s | 1.277× |
| 1,800 continuous frames | 9.383 s | 6.879 s | 1.364× |

The continuous run improves from 191.8 to 261.7 wall FPS; cold FPS improves
from 162.7 to 202.1. All 72 checksums matched (`59662` per 180-frame batch,
`60838` for 1,800 frames). Native builds installed 355/356 compiled methods;
the generated PPU#run was installed. Interpreted mruby slowed in the first
180-frame comparison (about 20 seconds with Fiber versus 56 seconds with
the generated core), reinforcing the opt-in scope.

Further upstream specializations are not admitted by this preset. Method
inlining expands the generated entry from 37,945 to 125,750 bytes; adding
ivar localization expands it to 146,876 bytes and requires inlining. Both
variants preserve the captured state at the seven default frame counts under
CRuby, but mrbc rejects them with `too big jump offset` before native
compilation. They need a smaller generated control-flow structure before
their native performance can be measured.

The original Fiber PPU can also use bc2cpp's resumable compiler. Yielding
helpers now lower through decoded `BytecodeIR::ResumableRegion` control-flow
graphs, with helper registers retained in the persistent caller frame. The
compiler refuses unresolved branches, nonlocal exits, handler-bearing or
block-building helpers, and branches back into argument entry. This does not
replace the synchronous source generator or specialize clock branches. Run
`ruby scripts/bc2cpp/bytecode_ir_check.rb` and
`ruby scripts/bc2cpp/resumable_check.rb` for region refusals and native
yield/resume comparisons, including GC pressure. See ADR 0421.

An independent bytecode IR optimization applies to the original Fiber PPU:

```bash
OPTCARROT_STATIC_DISPATCH=1 BC2CPP_IR_INLINE=1 BC2CPP_IR_RESUMABLE_INLINE=1 ruby tools/optcarrot_probe/compiled_run.rb 180
```

Yield-free same-owner helper bodies lower into separate local scopes inside
the resumable step function, including calls inside flat step loops. The caller
retains its persistent frame; proved non-suspending helpers use C++ locals.
Explicit helper exits preserve each call's return value, and the normal per-yield states
remain unchanged. Bodies that can suspend, have exception handlers or nested
blocks, exceed the bounded expansion budget, or use unsupported instructions
retain their ordinary call boundaries. The probe reports how many helper IR
regions were expanded and gives this build a separate binary target. Set
`BC2CPP_IR_RESUMABLE_INLINE=0` for a paired baseline; both modes retain the
original Fiber PPU and must produce identical checksums.

Run `scripts/bc2cpp/resumable_check.rb` with both IR flags enabled for native
comparisons covering arguments, nested helpers, GC inside a helper, caller
values retained across later yields, indirect suspension and Fiber reentry.
The default run verifies the opt-out. This optimization does not replace the
synchronous source generator. See ADR 0435.

Three alternating release pairs used matching compiler revisions, the original
Fiber PPU, static CPU dispatch, ordinary IR inlining and the 16,384-pointer gray
stack. The optimized build expanded 27 PPU helper regions; both installed 355
methods. Full pixels, audio, RAM and CPU/PPU register snapshots matched at 2,
180 and 1,800 frames. All twelve timing checksums also matched.

| Workload | Ordinary helper calls | Transient IR helper regions |
| --- | ---: | ---: |
| 180 frames, cold | 1.1510 s (156.39 FPS) | 1.1535 s (156.05 FPS) |
| 1,800 continuous frames | 9.6371 s (186.78 FPS) | 9.5811 s (187.87 FPS) |

The 0.6% continuous difference is within run-to-run noise; no runtime speedup
is claimed, and the mode remains opt-in. The existing synchronous source preset
remains the faster PPU experiment. A first version retained helper temporaries
in the heap frame and regressed; non-suspension proofs now allow those values
in local scopes without extending their lifetime across yields.

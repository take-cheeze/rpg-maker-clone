# Optcarrot native-host GC

The benchmark retains 262,144 PPU lookup-table rows. mruby's default gray
stack holds 1,024 pointers; overflow causes the collector to rescan the heap
for gray objects. A fresh instrumented static-dispatch profile attributed
21.82% of sampled self time to `gc_gray_rescan`. Instrumentation disables
C++ inlining, so this is a profiling direction, not a predicted release gain.

The native probe now defaults to 16,384 pointers. On a 64-bit host the stack
grows from 8 KiB to 128 KiB: 120 KiB additional storage per mruby state. The
collector algorithm and collection scheduling are unchanged. The engine's
regular builds and constrained targets retain upstream settings.

Set `OPTCARROT_GRAY_STACK_SIZE=1024` for the upstream-capacity control, or
another decimal capacity from 1024 through 262144. The runner applies the
define to every VM/gem C and C++ translation unit and includes the capacity
in both host target names. Because `mrb_gc` embeds the stack, objects built
with different capacities cannot be mixed. The console and CI summary label
the selected capacity.

```sh
OPTCARROT_GRAY_STACK_SIZE=1024 OPTCARROT_STATIC_DISPATCH=1 ruby tools/optcarrot_probe/compiled_run.rb 180
OPTCARROT_GRAY_STACK_SIZE=16384 OPTCARROT_STATIC_DISPATCH=1 ruby tools/optcarrot_probe/compiled_run.rb 180
```

Release measurements use the factored PPU table from the startup optimization
in both builds. They alternate identical workloads without profiling, explicit
GC calls, or disabling collection. Total wall times include all collection
costs; peak RSS comes from `/usr/bin/time`.

Three alternating pairs per workload, same source and compiler, 355 installed
compiled methods, CPU/PPU hot methods compiled. The 20-batch workload creates
a new NES instance per batch; the continuous workload creates one instance.

| Workload | 1,024 pointers | 16,384 pointers | Ratio | Median peak RSS, control / larger |
| --- | ---: | ---: | ---: | ---: |
| 180 frames, cold | 1.298 s | 1.167 s | 1.112× | 86.42 / 86.27 MiB |
| 20 × 180 frames, fresh NES each | 26.617 s | 20.983 s | 1.269× | 162.84 / 162.57 MiB |
| 1,800 continuous frames | 9.767 s | 9.704 s | 1.006× | 86.71 / 86.85 MiB |

Cold whole-process FPS improved from 138.70 to 154.23. The repeated-instance
workload improved 1.269× including collection. The 0.6% continuous difference
is within run-to-run noise: no faster steady emulation is claimed. Peak RSS
differences were small relative to allocator/run variation; the structural
per-state storage cost remains 120 KiB.

All 132 checksums matched: `59662` for each 180-frame run/batch, and `60838`
for each 1,800-frame run. The continuous reference checksum was independently
verified using Ruby 4.0.7 with YJIT.

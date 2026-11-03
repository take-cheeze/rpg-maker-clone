# Compiler data allocation profile

`scripts/bc2cpp/compiler_profile.rb` measures the host Ruby compiler, including
analysis and C++ emission. It does not measure the generated game's runtime.
It writes `<prefix>.metrics.json` and, in sampling modes,
`<prefix>.stackprof`. Compiler stdout and stderr remain available for normal
redirection. A failed compiler invocation still writes metrics with
`completed: false` and retains its failing exit status.

Use the same mrbc, Ruby, source inputs, environment and machine for both
versions. Initialize the pinned submodules before preparing the sealed
Optcarrot workload. For example:

```sh
MRBC=/path/to/mrbc ruby scripts/bc2cpp/compiler_profile.rb \
  --mode object --out /tmp/compiler-object --optcarrot > /tmp/compiler-object.cpp 2>/tmp/compiler-object.log
ruby -rstackprof -e 'StackProf::Report.new(Marshal.load(File.binread(ARGV[0]))).print_text(false, 40)' \
  /tmp/compiler-object.stackprof
```

Sampling requires the optional `stackprof` Ruby gem. `--mode object` samples
one in 100 allocations; `cpu` and `wall` sample at 1 ms. The default `none`
uses only Ruby's GC counters and clocks. To profile another closed world,
provide its normal environment and pass compiler arguments after `--`:

```sh
ruby scripts/bc2cpp/compiler_profile.rb --out /tmp/compiler -- --annotated source.rb
```

The timer, CPU time, allocation count and GC counters start after workload
preparation and optional profiler loading, and include compiler loading.
CPU time covers the Ruby process, excluding subprocesses such as mrbc.
On Linux, `process_peak_rss_kib` is the whole process high-water mark,
including preparation and any sampler overhead. Compare timing and RSS in
`none` mode; sampled runs are for attribution. RSS is omitted on other hosts.

The scan cache includes a digest of all `tools/bc2cpp` sources, so changing
compiler code invalidates it. Warm **each version** before comparing, or use
consistently cold caches. Alternate at least three unsampled runs per version;
report the individual results and avoid claiming a speedup from small timing
changes. `--optcarrot` creates a temporary world per run, so its generated C++
contains different source paths and some source-scan cache keys change between
runs. These convenience runs do not provide a fully warmed comparison. For
matched warm-cache runs and byte-for-byte output comparison, prepare
one world at a fixed path and pass the same compiler arguments and environment
using the generic invocation above.

## Data structure decisions

A warm-cache allocation profile of the sealed Optcarrot compilation on Ruby
4.0.5 attributed 2,300 of 114,933 allocation samples directly to
`NumericFlow.worklist_rank` (2.0%). Its DFS allocated `[node, finished]`
pairs on entry and exit, plus successor concatenations for handler edges.
Instruction indices are nonnegative, so a negative bitwise complement can
encode an exit marker in one Integer. Handler edges are pushed before normal
edges, each in reverse order, preserving the old concatenation's stack order.
The change retains the rank vector, queued flags and analysis state format.

The other proposed candidates were smaller or already compact in this workload:

- `Types#compute_exact`: 107 direct samples (0.09%). Flattening its queue and
  visited pairs remains possible, but the larger DFS traversal comes first.
- `Types#exact_at`: 145 direct samples (0.13%), including 124 on its query-key
  array. General reaching-definition queries accounted for 845 direct samples
  (0.74%); any key change must preserve every context dimension and cache cap.
- NumericFlow already converts register membership into a frozen boolean Array
  (`Ctx#initialize`), providing indexed checks without per-check objects.
  Integer masks would need separate timing evidence to justify replacing it.

The existing speed check compares the integer DFS against the former pair-stack
algorithm on all 512 directed three-node graphs, 200 seeded random graphs with
handler and context edges, and a 2,000-node chain. It also checks the zero-index
exit marker and unreachable ranks. These comparisons preserve exact order,
which matters because it determines later oracle calls.

## Repeated unsampled compilation

Three alternating warm runs per version used the same fixed-path sealed world,
mrbc built from pinned mruby `93f276a8f`, and Ruby 4.0.5. The baseline was
`6651c6300`; only the DFS representation differed. Generated C++ was
byte-for-byte identical within every pair. Metrics cover compiler loading,
analysis, emission and mrbc waiting, excluding world preparation.

| Run | Allocations before | Allocations after | Seconds before | Seconds after | Peak RSS KiB before | Peak RSS KiB after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 11,515,588 | 11,289,259 | 6.934 | 6.988 | 326,088 | 320,848 |
| 2 | 11,515,620 | 11,289,244 | 7.092 | 6.961 | 324,752 | 325,936 |
| 3 | 11,515,761 | 11,289,290 | 7.046 | 7.024 | 320,536 | 327,632 |

This consistently removes about 226,000 allocations per compilation (1.97%).
Timing and peak RSS vary; these runs do **not** establish a compiler speedup
or lower peak memory. The allocation reduction is the demonstrated result.

## Native brace bodies

`NativeExpressionDevirt.brace_body` finds the closing brace of a native C/C++
block, skipping comments and literals. It compared one-character Strings from
`scanned[index]`, and an object-mode profile of the sealed Optcarrot
compilation attributed 5.2% of allocation samples to it. `ascii_view` already
maps the source to an ASCII-only string whose character and byte offsets agree,
so the walk now compares bytes from `getbyte` and allocates nothing per
character. Old and new returned the same body and closing index for up to 200
opening braces of every C/C++ source under `3rd/mruby`, `src`, `mruby-*` and the
vendored mruby gems (read both as UTF-8 and as binary), plus edge cases.

Three alternating unsampled `--optcarrot` runs per version, baseline
`21e93f701`; generated C++ differed only in the per-run temporary world path:

| Run | Allocations before | Allocations after | Seconds before | Seconds after |
| --- | ---: | ---: | ---: | ---: |
| 1 | 15,292,845 | 14,541,259 | 7.818 | 7.784 |
| 2 | 15,292,936 | 14,540,803 | 7.780 | 7.837 |
| 3 | 15,292,779 | 14,541,342 | 7.765 | 8.094 |

This removes about 751,000 allocations per compilation (4.9%). Timing does not
show a speedup.

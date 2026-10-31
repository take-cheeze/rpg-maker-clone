# Startup and gameplay lookup survey

The startup-aware hook measured the 1,071-entry closed RPG2k build against
Nepheshel: New Game (6,000 frames), battle (4,000), menu (1,400), three save
scenarios and Continue (900 each), plus all 543 maps (150 frames each).
All 550 game processes passed. The dependency absence check also passed.
The instrumented build's registration proof retained the same fixed point:
1,143 open keys, 3,589 closed keys, 169 core ROM exclusions and 196 core
runtime removals. No additional entries were omitted by this survey.

The measurement combines root merge `ab23c36b8` with the survey changes and
mruby fork commit `0c0f6cf1e`. Both lookup and VM-start instrumentation were
enabled. The observer was installed before core and gem initialization;
metadata snapshotting ran with observation disabled. The snapshot consistently
contained 581 native callables, 483 compiled callables and seven undefined
markers, with no bytecode method entries.

## Which installed entries were looked up?

| Implementation | Installed | Gameplay observed | Startup only | Never observed |
| --- | ---: | ---: | ---: | ---: |
| Native | 581 | 92 | 46 | 443 |
| Compiled C++ | 483 | 44 | 84 | 355 |
| Undefined markers | 7 | 0 | 0 | 7 |
| **Total** | **1,071** | **136** | **130** | **805** |

The union is **266 observed entries**. Of these, 21 were observed in both
startup and gameplay, 115 only during gameplay and 130 only during startup.
The **798 unobserved callables** are an audit pool for stronger static proofs;
[the complete list](bc2cpp-lookup-unobserved.txt) excludes undefined markers.
They are not 798 confirmed removals. For example, unobserved entries include
Array mutation methods and String operators whose implementations can remain
live through direct generated calls. Registration liveness and function
liveness are different questions.

The largest unobserved owner groups include String (47), Array (38), Hash
(35), Kernel (27), Integer (26), Float (22), StringIO (20), Time (18) and IO
(16). RPG2k3 battle methods are unobserved because this workload is an RPG2000
game; they must not be removed on that evidence. Other games, error paths,
subclasses and reflection can also exercise entries this workload never uses.

## VM execution

Every one of the 550 game processes had exactly the initialization-only
baseline's VM-start counts:

| Counter site | Per-process starts |
| --- | ---: |
| C entry | 20 |
| EXEC | 53 |
| BLKCALL | 62 |
| SEND | 12 |
| CALL | 0 |
| **Total** | **147** |

There were **zero additional VM starts after initialization** in every tested
run. Gameplay in this workload already avoids bytecode execution, while still
using by-name lookup. Removing the VM from the whole program still requires
eliminating the 147 initialization starts and proving all possible runtime
paths, rather than subtracting the VM solely on these traces.

## Dominant lookup targets

There were 37,654,267 gameplay lookups, including misses and probes.
36,329,055 matched installed slots. Four entries account for **81.9%** of all
gameplay lookup traffic:

| Installed entry | Gameplay lookups | Sampled path |
| --- | ---: | --- |
| `Array#<=>` | 17,071,756 | `Map#draw_events` generated `sort_by` comparison → native `mrb_cmp` → by-name comparison |
| `Hash#default` | 6,214,809 | `Game::Switches#[]` / common-event gates → `mrb_hash_get` → `mrb_func_basic_p` probe |
| `StringIO#initialize` | 4,551,644 | LCF row decoding / conversion → `mrb_obj_new`, including builtin-identity probes |
| `String#initialize` | 2,998,200 | String construction via `mrb_obj_new`, including builtin-identity probes |

These are lookup counts, not timings or executed-call counts. Stack samples
include the first lookup and every 4,096th lookup per table/name/phase; they
locate callers but are not unbiased per-site hit estimates. The map renderer
sorts events by `[y, x, id]`; its generated insertion-sort loop repeatedly
calls `mrb_cmp` on array keys. Specializing this proven tuple comparison, and
improving that sorting lowering, is the clearest measured next performance
target. Native builtin-identity checks and LCF object construction follow.
Each optimization still needs its own semantic proof and timing measurement.

Missing lookups are recorded separately and can be legitimate probes or
compiled-method phantom checks. Frequent examples are `call`, `rpg2003?` and
`revision`; they do not imply the successful sweep raised NoMethodError.
Startup lookups of definitions absent from the final installed table are
also separate. A startup hit against an installed owner/name does not imply
its final wrapper was already installed at the time.

## Reproduction and artifacts

See [the hook and survey commands](bc2cpp-method-lookup-hook.md#startup-and-gameplay-survey).
The reporter writes `entries.tsv`, `summary.json` and `sampled-callers.tsv`.
It checks that every process has the same installed inventory and executable
addresses, and reports how many runs exactly match the VM startup baseline.
The original local artifacts are under
`build/bc2cpp-lookup-survey-20261101/report/`; raw per-process files are under
`/tmp/bc2cpp-lookup-survey-sweep/`. The binary is
`/tmp/bc2cpp-lookup-survey-build/trace-host/trace_host`.

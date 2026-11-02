# RPG2k host/preprocessed profile validation

Validated on 2026-11-02 against master `01765f674489`, with the build fixes
in this change. The target was the complete native-only `closed` RPG2k build,
with Clang 21.1.8 on x86-64 Linux and Nepheshel 2.06 R beta. This measures the
headless host profile, not a Wio firmware image or the SDL desktop entry point.

## Inputs and scope

The build enabled both `BC2CPP_MAIN_AST` and `BC2CPP_NATIVE_INVENTORY` and
generated reports through `BC2CPP_MAIN_REPORT`. The AST exporter used Clang
preprocessing (`BC2CPP_HOST_CXX=clang++`) for `scripts/bc2cpp/trace_host.cxx`
and the linked RGSS `lib`, input, PSP input, Wio input and terminal bridges,
with `--lookup-names-only`. It resolved 27 lookup names without refusals.

The rake exporter selected 76 native units from the same closed build, with
zero compiler units. Compiled registration wrappers and generated shards are
represented by Ruby IR and excluded from that native scan. The entire closed
target was compiled with `CC=clang CXX=clang++`, and the sweep used
`CXX=clang++ JOBS=4`.

GCC 15/glibc preprocessing cannot be parsed by the installed Clang because of
its `_Float32` declarations; this run does not validate that host-AST path.
The local Nix shell also exposed an older libc at runtime; the sweep used
`LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu` to match the system Clang libraries.

After generation changed presym IDs, the host manifest was exported again.
Its roots were identical. Rebuilding with that refreshed manifest verifies
that the profile can be consumed after bootstrap has settled.

## Generated C++

Both runs use the same Ruby program and omission sets: 1,154 open exclusions,
3,633 closed exclusions, 189 core ROM exclusions and 210 core runtime removals.
The baseline has no host/preprocessed emission profile. Bytes count the four
main `*_gen.cpp` files, without counting the shard include wrappers twice.

| Unit | Baseline bytes | Profile bytes | Removed bytes |
| --- | ---: | ---: | ---: |
| Core | 990,682 | 799,196 | 191,486 |
| LCF | 879,417 | 766,110 | 113,307 |
| RGSS | 546,335 | 521,302 | 25,033 |
| RPG2k | 5,565,554 | 5,528,709 | 36,845 |
| Total | 7,981,988 | 7,615,317 | 366,671 (4.59%) |

Reachability retains 3,753 of 4,245 instruction sequences, omitting 492
(11.59%). There are no retain-all refusals. Enumerator's stored-method
forwarding and Enumerable's reduction forwarding still protect named roots.

## Named tables and retention reasons

The generated reports contain 428 retained named slots, including 37
initializers. The whole runtime has 1,000 method-table entries after gem init;
that broader count includes native methods and other runtime registrations.

| Generated unit | Retained named slots | Initializers |
| --- | ---: | ---: |
| Core | 132 | 3 |
| LCF | 35 | 6 |
| RGSS | 56 | 6 |
| RPG2k | 205 | 22 |
| Total | 428 | 37 |

The independent bounded-name closure reports these reason memberships.
Reasons overlap: a slot can have Ruby, native and host callers simultaneously.
They describe name reachability, not permission to delete a registration.

| Reason | Retained slots with this reason |
| --- | ---: |
| Ruby call | 395 |
| Preprocessed native name | 182 |
| Host AST lookup | 71 |
| VM/reflection protocol | 62 |
| Literal/forwarded lookup | 51 |
| Direct native implementation | 43 |

Twenty-six retained slots have no bounded-name witness. Conservative core
forwarding and the independent omission proof still protect them.

## Runtime checks

`scripts/bc2cpp/host_sweep.bash` passed all 543 maps at 150 frames each, plus
new game (6,000 frames), battle (4,000), menu (1,400), three save paths and
Continue/load (900 frames each). Omitted dependencies were absent, and the
method-table count was below the existing 1,061-entry limit. No scenario
reported an unregistered method, failed lookup, proof/hint guard violation,
missing native continuation or bytecode execution. All 543 map logs were
retained. This bounded sweep does not prove every event path in the game.

The main-root suite passed 53 checks, shared generation matched separate
generation, CTest passed 10/10 tests, and pre-commit passed. Regression checks
cover the Rake dependency cycle, exclusion of compiled registration wrappers
and shards, and restoration of preprocessing options after export.

The profile remains opt-in. See [host-rooted generation](bc2cpp-main-roots.md)
for export, stale-input checks and per-target configuration requirements.

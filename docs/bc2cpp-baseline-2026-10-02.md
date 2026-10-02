# bc2cpp baseline after ADRs 0307-0317 (2026-10-02)

Work in progress: this page is filled in as each measurement run finishes.

Tree: `origin/master` `cd86085f` (PR #1991 merged), wio closed world, `3rd/*` populated, host `mrbc` prebuilt,
`LANG=C.UTF-8`. Commands are those in `docs/bc2cpp-dynamic-site-census.md` (`## Method`).

## 1. Totals (shipped pass, default switches)

| Measure | all gems | non-core (rpg2k + lcf + rgss) | rpg2k + Game only |
| --- | ---: | ---: | ---: |
| `bc2cpp_send` call sites | 2,603 | 2,159 | 1,800 |
| `mrb_funcall*` | 28 | 2 | 0 |
| `mrb_funcall_with_block` | 401 | 303 | 277 |
| `bc2cpp_nomethod` | 4,380 | 4,312 | 4,274 |
| `bc2cpp_nil_receiver` | 890 | 868 | 837 |
| `bc2cpp_guard_violation(` callers | 310 | 309 | 238 |
| `bc2cpp_slow_*` callers | 3,314 | 3,106 | 2,852 |
| `bc2cpp_getidx`/`getidx0` callers | 2,069 | 2,012 | 1,955 |
| `bc2cpp_setidx` callers | 209 | 191 | 184 |
| lines that can reach by-name dispatch ("reach sites": send, funcall, funcall_with_block, slow_*, getidx, setidx, eqq) | 14,314 | 13,366 | 12,521 |

"non-core" is the function-name prefix `RPG2k_|Game_|RGSS_|LCF_`; "rpg2k" is `RPG2k_|Game_`.

## 5. CI shard timing (last green master runs)

Job wall time in minutes (`started_at` to `completed_at`, queueing excluded), from the Actions API.
`bc2cpp-checks` and `bc2cpp-width` have `timeout-minutes: 45`.

| Shard | 56b14771 | 147fe7e6 | 420c7252 | cd86085f |
| --- | ---: | ---: | ---: | ---: |
| core-tables | 29.0 | 28.9 | 29.8 | **29.7** |
| fast | 20.0 | 16.0 | 17.5 | 21.9 |
| core-exact-direct | - | 16.1 | 18.8 | 19.8 |
| core-mrbtest | 15.4 | 23.2 | 17.6 | 17.8 |
| bc2cpp-width (int32) | 7.4 | 14.2 | 18.8 | 16.2 |
| call-results | - | 10.6 | 15.2 | 15.2 |
| block-arm-reach | 11.3 | 13.4 | 14.4 | 14.7 |
| core-flow | 9.5 | 14.7 | 9.6 | 13.3 |
| call-facts | - | - | - | 11.9 |

`core-tables` is about 29-30 minutes (the "Run core-tables checks" step is 27.8 of the 29.7), not 24.5, and has
been flat since `56b14771`; it is the only shard above 25 minutes and has about 15 minutes to the 45 minute
timeout. The per-check timing table could not be read: the job log is served from a host the sandbox proxy does
not reach and the log tool returned only the tail.

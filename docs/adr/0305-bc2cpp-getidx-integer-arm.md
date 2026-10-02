# 0305. The GETIDX helper's Integer arm comes from a visible `Integer#[]`, not from invented semantics

Date: 2026-10-01

## Status

Accepted

## Context

ADR 0298's optcarrot profile put 2,667,211 of 7,818,761 executed by-name dispatches (34.1%) on the `[]` tail of
the shared helper `bc2cpp_getidx`, guessed to be `Integer#[]`. A receiver histogram taken at that tail
(temporary instrumentation, not committed) attributed it exactly:

| Receiver at the tail | Hits |
| --- | ---: |
| Integer (non-negative Integer key) | 2,552,721 |
| `IdentityHashShim` (probe shim, user class) | 105,005 |
| `Method` | 9,485 |

`bc2cpp_getidx0` added 1,498 more, all Integer. `bc2cpp_setidx` reached its tail twice.

mruby core (4.0 here) defines no `Integer#[]`; `5[0]` raises NoMethodError unless the program defines one.
optcarrot's probe defines it in `tools/optcarrot_probe` as `(self >> i) & 1`. An Integer arm in the helper that
implemented bit reference itself would therefore change behaviour (NoMethodError becomes a value) and has no core
implementation to match. The helper already has the sound mechanism: POLY_SMALL_N's exact-class chain over the
program's own compiled `#[]` definers. It was empty because the probe fed bc2cpp only optcarrot's files, so the
shim was invisible to the closed world.

## Decision

- No generator change. With `Integer#[]` visible, the helper gets `if (<Integer class> == mrb_obj_class(M, recv))
  Integer_$5b$5d_impl(...)` after the Array/Hash/String arms, and keeps the by-name tail for every other receiver.
  The arm calls the program's compiled body, so bignum, negative, Float and nil keys behave as the shim does
  through the numeric helpers of ADR 0292.
- `tools/optcarrot_probe/compiled_run.rb` passes the Integer shim to bc2cpp. It moved out of `shims.rb` into
  `shim_integer_aref.rb` because the other shim classes embed and cannot be registered by that runner.
- `scripts/bc2cpp_getidx_integer_arm_check.rb` runs the real shim compiled and interpreted over receivers x keys
  (Fixnum edges, heap Integer, bigint, Float, NaN, nil, String, Array, Hash, Proc, user class) on full-core,
  core-only, 32-bit `mrb_int` and no-bigint builds. Answers (value, Float bits, `Integer#hash`, exception class and
  message) must match, an Integer receiver with a key in 0..199 makes no by-name call, and with `GIA_MUTANTS=1` a
  dropped class guard and a wrong class must fail it. Without a definer the helper must hold no Integer arm.

## Consequences

- Measured on optcarrot, 180 frames, checksum 59662 both ways: executed by-name dispatches 7,818,761 to
  5,266,040 (-2,552,721, -32.6%); the helper tail 2,667,211 to 114,490 (the `IdentityHashShim` and `Method`
  rows above). The static census is unchanged: the same 1,083 instrumented sites. Wall time was not measured
  reliably (shared, loaded machine), so no speedup is claimed.
- The arm trusts the closed world's definer like every POLY arm. If a future mruby gains a core `Integer#[]`, the
  shim's `unless 0.respond_to?(:[])` would skip defining it while the arm still calls the shim body; the check
  would then flag the difference.
- The arm exists only when the definer set has at least two entries (native definers count), as in ADR 0261.
- Not done: `bc2cpp_getidx0` and `bc2cpp_setidx` have no exact-class arm (1,498 and 2 hits); `Method#[]`
  (9,485) is `Method#call`, with nothing to gain without a call path; user classes stay by name.

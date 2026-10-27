# Branch hints on bc2cpp's own guards

Most guards bc2cpp emits have a fast arm that runs almost every time and a
fallback that runs when a proof did not hold or an operand has a rare type. A
typical one is `if (mrb_fixnum_p(a) && mrb_fixnum_p(b)) { fast } else {
generic send }`. Raises already go through `[[noreturn, gnu::cold]]` helpers,
and GCC treats those as cold. A guard's fallback, by contrast, is an ordinary
call or a Float chain, so GCC predicts it only weakly. It then lays the
fallback out inline and leaves the hot path split around it.

`tools/bc2cpp/branch_hints.rb` (BRANCH_HINTS) supplies the hints.
`BranchHints.likely` / `.unlikely` wrap a condition in mruby's own
`mrb_likely` / `mrb_unlikely` (`include/mruby/common.h`, valid C++).
`BranchHints.cold_arm` is used where no single condition can carry the hint.
It prefixes the arm with `BC2CPP_COLD_ARM`, a GCC cold label that is unique per
use through `__COUNTER__`. Clang gets an empty macro. `BranchHints.text` covers
the file-scope helper templates that are kept as constants.

## What is hinted

| Emitter | Hint |
| --- | --- |
| `ADD`/`SUB`/`MUL`/`DIV`, `ADDI`/`SUBI`, `ADDILV`/`SUBILV` (codegen_insn.rb) | Fixnum tag test likely; the GUARDED_GAME_VARIABLE_RANGE test likely |
| `fixnum_exact_tier` (codegen_numeric_proof.rb) | overflow / `!FIXABLE` tier unlikely |
| `compile_cmp` `<` `<=` `>` `>=` | Integer pair likely |
| FIXNUM_BINARY, FIXNUM_SHIFT, FIXNUM_COMPARE, a lone INTEGER_LSHIFT (codegen_send.rb) | Fixnum pair likely; FIXNUM_SHIFT's `bc2cpp_shift_fast` likely |
| ARRAY_PUSH `push` and `<<` arms | exact-Array test likely |
| TYPED / ELEMENT, MONO_EMBED_GUARD, IVAR_ACCESSOR | the owner-class guard likely |
| POLY_SMALL_N chain | final else (`bc2cpp_nomethod` / send) is a cold arm |
| `bc2cpp_getidx` inline arm, ARY_WRITE_INLINE helpers | exact-Array / in-place store test likely |
| `bc2cpp_ary_entry` | out-of-range test unlikely |

The rule is this: hint only a guard the compiler itself adds. Its failure means
that a proof did not hold or that the operand has a rare type. A branch whose
direction is the program's data is never hinted, so a user `if`, a loop test
and the value a comparison computes stay bare. For the same reason some guards
of the compiler's own are left bare too:

- `==` / `!=`, because every type meets `==` and a non-Integer operand is not
  rare there.
- The arms of a POLY_SMALL_N chain, because which receiver class arrives is
  the program's data. Only the chain's last else is cold.
- `<<` when both the ARRAY_PUSH and the INTEGER_LSHIFT arm are live, because
  either one can be the common case.
- The Array / Hash / String arms of the outlined index chains.

In the optcarrot probe's generated C++ this adds 1,785 `mrb_likely`,
566 `mrb_unlikely` and 103 cold arms. 1,318 of the likely hints are Integer
pairs, 200 are single Integer operands, 167 are class guards, 57 are shift
results, 19 are exact-Array tests, 16 are `%`, 5 are range guards and 3 are
ARY_WRITE helpers. 565 of the unlikely hints are overflow tiers and 1 is the
`bc2cpp_ary_entry` bounds test. The guards that were already
`mrb_unlikely` (frozen checks, declared-return guards, the core-body
interpreted fallback) are unchanged.

## Measurements (optcarrot probe, Lan_Master.nes)

The binaries come from `tools/optcarrot_probe/compiled_run.rb` at `-O3`. A is
`BC2CPP_BRANCH_HINTS=0`; its generated C++ is byte-identical to master. B has
the hints on. The checksum is 59662 at 180 frames and 60838 at 1800 frames for
both binaries.

Callgrind (`--branch-sim=yes --cache-sim=yes`) cost per frame, computed as
(N=21 − N=1) / 20:

| | Ir | Bc | Bcm | Bim | I1mr |
| --- | ---: | ---: | ---: | ---: | ---: |
| A (no hints) | 35.997M | 7.013M | 93.6K | 8.9K | 181.3K |
| B (hints) | 35.101M (−2.5%) | 6.962M (−0.7%) | 77.5K (−17.2%) | 9.0K (+1.4%) | 123.0K (−32.2%) |
| A + GCC PGO (reference) | 32.934M (−8.5%) | 6.699M (−4.5%) | 103.9K (+11.0%) | 9.4K (+5.3%) | 131.9K (−27.3%) |

The startup run (N=1 totals) costs 1,506.8M Ir for A and 1,502.6M for B
(−0.3%). Its I1mr rises from 144K to 183K.

Wall time for 1800 frames, `taskset -c 3`, A and B interleaved. Two rounds of
9 runs each were made on a 4-core machine that another agent's builds kept at
a load average of about 1.2 to 2.2:

| | round 1 median (min) | round 2 median (min) |
| --- | ---: | ---: |
| A (no hints) | 7.737 s (7.588) | 8.042 s (7.588) |
| B (hints) | 6.250 s (6.044), −19.2% | 6.515 s (6.107), −19.0% |
| A + GCC PGO | | 5.804 s (5.668), −27.8% |

Within one binary, the spread from min to max was 6 to 11% of the median. The
gap between A and B is about 19%, and in every round the slowest B run was
faster than the fastest A run. The simulated instruction count falls by only
2.5%. Most of the wall-time gain is therefore front-end work: the cold
fallbacks leave the hot loop bodies (`PPU#main_loop_step`, `render_pixel`,
`CPU#run`), so the I-cache and fetch path run straight-line code. The 32%
drop in simulated I1 misses points the same way. GCC PGO trained on 180
frames, which is the same probe, is a further 11% faster than B, so the hints
recover about two thirds of what profile feedback gets.

To repeat the PGO reference, set `OPTCARROT_COMPILED_FLAGS` on the probe. It
appends to the compiled binary's compiler and linker flags and builds the
binary in its own `...sealedxflags` directory:

```sh
OPTCARROT_COMPILED_FLAGS="-fprofile-generate=$DIR -fprofile-update=single" ruby tools/optcarrot_probe/compiled_run.rb 180
rm -rf 3rd/mruby/build/optcarrotcompiledreleasegray16384sealedxflags
OPTCARROT_COMPILED_FLAGS="-fprofile-use=$DIR -fprofile-partial-training -Wno-missing-profile -Wno-coverage-mismatch" \
  ruby tools/optcarrot_probe/compiled_run.rb 180
```

`-Wno-coverage-mismatch` is needed because the probe copies the sealed gems'
sources to a fresh temporary directory for each run.

## Checks

`MRBC=path/to/mrbc ruby scripts/bc2cpp/branch_hints_check.rb` checks the
following:

- the hinted shapes listed above;
- that `==`, user `if` / `while` tests, chain arms and a two-arm `<<` stay
  bare;
- that `BC2CPP_BRANCH_HINTS=0` output equals the hinted output with the hints
  unwrapped;
- that interpreted and compiled runs agree on every fallback arm.

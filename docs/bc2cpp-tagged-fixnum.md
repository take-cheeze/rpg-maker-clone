# Fixnum arithmetic and compares on the tagged word (TAGGED_FIXNUM)

Under word boxing, a Fixnum `n` is the machine word `(n << 1) | 1`
(`3rd/mruby/include/mruby/boxing_word.h`). The generic Fixnum arm of an
operator used to unbox both operands, do the `mrb_int` operation with an
overflow check, test `FIXABLE` and box the result again. The arms now do the
operation on the boxed words when the build makes that exact, and keep the
old form everywhere else. The code is in `tools/bc2cpp/tagged_fixnum.rb`:
a prelude printed once per translation unit and the helpers that the
operator emitters call (`codegen_insn.rb` for the opcodes, `codegen_send.rb`
for `& | ^` and the compare sends, and `codegen_native_send.rb` for `!=`).

## What the arms compute

With `A = 2a + 1` and `B = 2b + 1` the boxed words of two Fixnums:

| Operation | Word form | Why it is exact |
|---|---|---|
| pair test | `A & B & 1` | the Fixnum tag is the low bit alone (`WORDBOX_FIXNUM_MASK == 1`) |
| `a + b` | `A + (B - 1)` = `2(a+b) + 1` | signed word overflow ⇔ `a + b` outside the Fixnum range |
| `a - b` | `A - (B - 1)` = `2(a-b) + 1` | same |
| `a * b` | `((A - 1) * (B >> 1)) \| 1` = `2ab + 1` | `2ab` overflows ⇔ `ab` outside the Fixnum range; `2ab` is even, so the `\| 1` is the `+ 1` and cannot overflow |
| `a + k`, `a - k` | as `+`/`-` with `B = mrb_fixnum_value(k)` | a constant, so `B - 1 = 2k` folds |
| `<, <=, >, >=, ==, !=` | the same compare on `(intptr_t)A`, `(intptr_t)B` | `x ↦ 2x + 1` is strictly increasing |
| `a & b`, `a \| b` | `A & B`, `A \| B` | both tag bits are 1, and the operation keeps the 1 |
| `a ^ b` | `(A ^ B) \| 1` | the tag bits cancel, so the tag is set again |

The overflow test is one `__builtin_{add,sub,mul}_overflow` on `intptr_t`.
It replaces both the `mrb_int` overflow test and `FIXABLE`. This works because
the Fixnum range is exactly the word range shifted right by one bit
(`MRB_FIXNUM_MAX == INTPTR_MAX >> 1`, checked by a `static_assert`). When the
word operation overflows, the register still holds the left operand, and
`mrb_num_add` / `_sub` / `_mul` produces the heap Integer or bigint the
interpreter would, as before.

### The tag bit of a result (FIXNUM_TAG_BIT)

The word `A + (B - 1)` is already odd, but GCC does not carry that through
`__builtin_add_overflow`. Without it, the immediate test that
`mrb_field_write_barrier_value` makes on a stored result (`(w & 7) != 0`)
stays in the code as a branch, one per `@ivar += n`. So the `+` and `-`
helpers store `w | 1`, which leaves the value unchanged and lets the
compiler fold that test, and `*` writes its `+ 1` as `| 1` for the same
reason.

On the optcarrot probe this removes about 175K conditional branches and
146K instructions per frame (−0.6%); the tile LUT initializer at startup
gains 4.7M instructions (+0.4% of startup), where the extra `or` has no
test to fold.

## Where the word form is used

The prelude defines `BC2CPP_TAGGED_FIXNUM` as 1 only when all of these hold:
`MRB_WORD_BOXING`, a GNU-compatible compiler (for the overflow builtins),
`MRB_FIXNUM_SHIFT == 1`, `WORDBOX_FIXNUM_FLAG == WORDBOX_FIXNUM_MASK == 1`,
and `MRB_INT_MIN`/`MRB_INT_MAX` equal to `INTPTR_MIN`/`INTPTR_MAX`.

| Target | Boxing, `mrb_int` | Word form |
|---|---|---|
| native (x86-64, aarch64) | word, 64-bit | on |
| Emscripten, PSP, Wio | word, 32-bit word with `MRB_INT32` | on; the same argument holds one size down |
| 64-bit word with `MRB_INT32` | word, `MRB_FIXNUM_SHIFT == 0` | off; the word range is not the Fixnum range |
| `MRB_NAN_BOXING`, `MRB_NO_BOXING` | — | off |

When it is off, the helpers keep the unbox/rebox form behind the same names,
so the generated text is the same for every target. Building with
`-DBC2CPP_TAGGED_FIXNUM=0` turns the word form off for comparison.

## What stays the same

Each arm keeps its other branches: the Float arms, the by-name fallback, and
the redefinition gates on the sends (`& | ^` and the compare sends are only
compiled when `native_only_mono?` holds, so a reopened `Integer#&` keeps its
send). The opcodes `ADD`/`SUB`/`MUL`/`ADDI`/`SUBI`/`LT`/…/`EQ` do not dispatch
for Integers in the VM whatever `Integer#+` is, and neither do their arms.

These arms now also have a heap-Integer arm (HEAP_INTEGER_PAIR). `OP_MATH` and
`OP_MATHI` compute any Integer pair in place, including Integers between the
Fixnum range and `2**63`. The compiled arm used to send `+` for those, which
was visible in a world that reopens `Integer#+`. Now it calls `mrb_num_add`
(and `_sub`, `_mul`), which does not dispatch.

## Effect

Measured on the optcarrot probe (Lan_Master, callgrind) against the master
build this change started from:

- **Per frame (frames 2–21):** 26.07M → 23.96M instructions (−2.12M, −8.1%).
  `PPU#main_loop_step` accounts for −1.12M of that, from its `@hclk += n` /
  `@hclk_target <= @hclk` steps. The CPU, APU and sprite-evaluation loops
  account for the rest.
- **Startup (one-frame run):** −13.1M instructions, mostly in the tile LUT
  initializer.
- **Checksum:** 59662 at 180 frames, unchanged.

## Check

`scripts/bc2cpp/tagged_fixnum_check.rb` covers three things:

- **Prelude.** It compiles the prelude for each boxing and width, and asserts
  the value `BC2CPP_TAGGED_FIXNUM` takes in each.
- **Generated text.** It asserts the generated forms of every arm above.
- **Behaviour.** It compares interpreted and compiled runs over values that
  include `FIXNUM_MAX`/`MIN ± 1`, heap Integers up to `±2**63`, bigints,
  Floats (NaN, `-0.0`), `nil` and a Symbol. It also checks that results that
  overflow to bigint come back to Fixnum. The runs cover the default world
  and a world that reopens `Integer#+`, `#<` and `#&` and counts their calls,
  each with the word form on and forced off.

The check skips one case. The pinned interpreter answers `2**70 == 0` (and
`== -0.0`) true, while the compiled `mrb_equal` answers false. This
difference comes from mruby's bigint `==` and is the same on master.

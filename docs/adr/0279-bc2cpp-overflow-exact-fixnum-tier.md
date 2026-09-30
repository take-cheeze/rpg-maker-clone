# 0279. bc2cpp: an overflow-exact Fixnum tier, and proofs that see computed-name sends

Date: 2026-09-30

## Status

Accepted

## Context

ADR 0276 made the arms whose operands are proven numeric overflow-exact and listed three
defects it left alone. All three are pre-existing and all three make the compiled program
disagree with the interpreter without any diagnostic.

1. **The plain Fixnum tier wraps.** `+ - *` (ADD, SUB, MUL, ADDI, SUBI, ADDILV, SUBILV) stored
   `mrb_fixnum_value(a op b)` whenever both operands were Fixnums, and `>>` with a negative
   count stored `mrb_fixnum_value(v << n)`. A result outside the C type wrapped (`fact(25)`
   compiled answers a number, the interpreter a bignum), and a result inside `mrb_int` but
   outside the Fixnum range was mis-tagged: under word boxing a Fixnum has one bit less than
   `mrb_int`, so `2**62` on the 64-bit build and `2**30` on the 32-bit targets
   (Emscripten, Wio, PSP) became a negative number. The ADDI family also guarded with
   `mrb_integer_p`, which accepts the heap `RInteger` a value between the Fixnum and `mrb_int`
   ranges lives in, and then read it with `mrb_fixnum()`.
   The same wrap fed the *proofs*: FIXNUM_OPERAND_PROOF source 4 ("an ADD/SUB/MUL result of
   proven Fixnums is a proven Fixnum") and IvarLayout (`@x = @x + 1` types the field
   `:fixnum`) took the wrapped value for a Fixnum.
2. **ENTRY_ARG_CALLSITE_PROOF and FIXNUM_RETURN_PROOF ignore computed-name sends.** Their
   header claimed the closed world has no `send`/`define_method`; it has both
   (`target.send("#{field}=", v)`, `define_method(name)`). A method whose visible sites all
   pass Integers can be called with a String, and a name with one Fixnum-returning
   definition can get another body installed at run time, so an unchecked `mrb_fixnum()` reads
   garbage. ArgTypes, which types `:fixnum` embedded fields from the same sites, had the same gap.
3. **A typed embedded ivar raises TypeError for a write the compiler did not type.** A
   `:fixnum` slot is an `mrb_int` field; the synthesized attr_writer and the runtime's
   `rdata_ivar_store` (patches/mruby-rdata-ivar-slots.patch) refuse anything else where the
   interpreter stores it: `obj.count = "x"` through an attr_accessor,
   `instance_variable_set(:@count, "x")`, `send("#{field}=", v)`.

## Decision

**The Fixnum tier is exact everywhere** (`fixnum_exact_tier`): both operands are immediates
(`mrb_fixnum_p`), `mrb_int_{add,sub,mul}_overflow` computes the result and `FIXABLE` checks it
fits a Fixnum; otherwise `mrb_num_{add,sub,mul}` runs Integer's own body and builds the
bignum. The fast path stays inline (no out-of-line `mrb_int_value` call). `>>` boxes through
`FIXABLE(x) ? mrb_fixnum_value(x) : mrb_int_value(M, x)`. Range#each boxes its counter the
same way and steps with `if (i >= end) break; ++i`, so an end at `MRB_INT_MAX` cannot wrap.
`%`, `&`, `|`, `^`, unary minus, `<<`, `times` and the array iterators were already exact
(the result is bounded by an operand, `mrb_int_value` boxes, or the counter is bounded by a
length).

**An arithmetic result is no longer a proven Fixnum.** FIXNUM_OPERAND_PROOF source 4 is
retired and IvarLayout types no ADD/SUB/MUL/ADDI/SUBI write `:fixnum`. Both facts were the
only way an operand became "Fixnum" without a literal, constant, argument or embedded field, so
they cannot survive a result that may be a bignum. The class-set proof of ADR 0276 already
covers these operands ("Integer and/or Float"), so the sends stay removed; what is lost is the
elision of the tag test on chained arithmetic, and the `mrb_int` slot of a counter.

**Computed-name sends are a name universe** (`DynamicNames`, extracted from ADR 0276's
`numeric_dynamically_named?`): every Symbol literal and identifier-like String literal, plus
`stem=` of each once any `send`/`__send__`/`public_send`/`method`/`define_method`/`alias_method`/
`attr_*` gets a name that is not a Symbol literal. ENTRY_ARG_CALLSITE_PROOF (rule 7b),
FIXNUM_RETURN_PROOF (also names an alias/`define_method` gives another body) and ArgTypes
refuse those names.

**A typed slot needs writers the compiler types** (`demote_typed_ivars_foreign_writable`, part
of the embedding pipeline): a `:fixnum`, `:symbol`, `:bool` or `:fixnum_nil` slot becomes a
boxed slot when a native or foreign source spells `@name`, bytecode names `'@name'` as a
Symbol/String literal or runs a block under another `self`, any `instance_variable_set` has a
computed name, or an attr_writer exists whose call sites are not all visible, non-computed
and argument-typed like the slot. A typed slot's check is
`mrb_fixnum_p`/`mrb_fixnum`, the inverse of the `mrb_fixnum_value` box, so a heap Integer can
no longer be truncated into it. The demotion needs the closed-world scans; unit fixtures
compiled without them keep the layout the analysis declared, as before.

## Consequences

- Compiled `+ - *` agree with the interpreter on every input; the new
  `scripts/bc2cpp_fixnum_overflow_check.rb` compares them over a boundary matrix
  (Fixnum and `mrb_int` extremes, `fact(25)`, negative shift counts, `-MIN`, `%`/`<<` edges,
  Range#each at the top of both ranges) against a 64-bit and a 32-bit-`mrb_int` build, and pins the
  generated tier. `-DMRB_32BIT -DMRB_INT32` on a 64-bit host has the 32-bit targets' arithmetic
  (31-bit Fixnums, 32-bit `mrb_int`); pass such a build through `BC2CPP_MRUBY_FULL32`,
  `BC2CPP_MRBC32` and (via `BC2CPP_CXXFLAGS`, set by the script) its flags. `MRB_INT32` alone
  keeps 32-bit Fixnums, a different regime.
- Cost, measured on the wio closed world with `scripts/bc2cpp_coverage_report.rb`: proven
  Fixnum-returning methods 78 to 31 (source 4 retired, computed names refused); guarded arithmetic
  and compare arms that keep a dynamic send 2,862 to 2,919 (the arms the Fixnum proof used to cover
  now go to the numeric proof: 170 to 353 arms lost their send that way); typed slots `mrb_int`
  87 to 20, `mrb_bool` 50 to 14, `mrb_sym` 3 to 1. 94 typed slots were boxed for foreign writers:
  87 are attr_writers that `target.send("#{field}=", v)` in `game/battle.rb` could reach (every
  Symbol/String literal of the program counts once any name is computed), 7 are names a native
  source spells. A micro benchmark of `while` loops with `+= 1`, `& 7`, `*` and an ivar counter
  (200M iterations, `-O2`, a loaded host) is within noise (0.72/1.02/0.60 s before, 0.78/0.79/0.67 s
  after for the three loops).
- `scripts/bc2cpp_computed_send_proof_check.rb` and `scripts/bc2cpp_foreign_ivar_write_check.rb`
  fail on the pre-change tree (garbage instead of `"abab"`, TypeError instead of the stored
  String). The diagnostic prints `== typed slots demoted to boxed slots ==` and the coverage report
  counts them.
- Not covered: a typed slot's runtime store still uses `mrb_integer_p` in the RData patch (a slot
  whose every writer is typed never sees a heap Integer); `Marshal.load` of bytes that name a
  class with typed slots stays outside the closed world, as in ADR 0276; a computed name built
  from data the program never spells (a `define_method(name)` fed from a file) is outside the name
  universe, as in ADR 0276; the compiler still devirtualizes a single-definition method past a
  runtime `define_method`; the Integer#step/upto/downto inline of ADR 0273 keeps `long long`
  counters and needs the same FIXABLE boxing when it lands.

# bc2cpp typed immediate operands

`BytecodeIR::OperandModel.imm_operand` and `Insn#imm_operand` return the decoded
Integer after a leading register, or `nil` when that operand is absent or is not
an integer. Zero and negative values remain Integers. LOADI slot opcodes carry
their values in the opcode and continue to have no separate immediate operand.

Constant analysis, range proofs and arithmetic emission consume that Integer
directly. They no longer format the decoded Integer into a temporary String only
to parse it back. Fixnum range admission remains target-independent, and the
emitted overflow tiers keep the same checks and fallback behavior.

Printed operand APIs such as `paren_value` remain textual. The literal-receiver
emission descriptor also retains its String spelling, so an equal literal from a
LOADI slot and a wide immediate still agrees at a join. C++ interpolation formats
numeric operands only when producing output.

A warmed LOADI16 instruction read 100,000 times through the direct operand-model
API allocated 100,001 objects with the previous String-returning expression,
including measurement overhead, and zero objects with the Integer-returning API.
The warmed memoized `Insn#imm_operand` path also allocated zero objects. This is
a microbenchmark of repeated reads, not a whole-compiler time or peak-memory
measurement. The old memoized path already avoided repeated allocations after
its first read; the direct operand-model callers did not.

`scripts/bc2cpp/typed_immediates_check.rb` checks synthetic and binary operands,
zero/negative/absent immediates, width-sensitive proof refusals, and unchanged
numeric overflow-tier output. Its host phase runs under coverage; its optional
MRBC phase runs in the compiler CI job, with requirements recorded in
`scripts/ci/bc2cpp_check_policy.yml`.

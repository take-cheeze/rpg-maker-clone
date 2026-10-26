# Typed call argument counts

Compiler analysis and dispatch consume Integer positional/keyword counts directly
from the decoded `:argc` operand. `Insn#argc` and `#keyword_argc` provide the
counts; `#positional_splat?`, `#keyword_arguments?` and `#keyword_splat?` retain
calling-convention information that a nil count alone cannot express.

`SEND0` has no count operand and is treated as zero positional arguments where
appropriate. A positional splat occupies one argument register, a keyword splat
occupies one hash register, and fixed keyword arguments occupy two registers per
pair. Explicit `nk=0` retains keyword presence. It is not equivalent to an absent
keyword operand.

`BytecodeIR::OperandModel.argc_spec` carries numeric counts with these flags.
`Insn#n_spec`/`#nk_spec` remain available for textual compatibility, and
`#argc_text` formats disassembly/diagnostics; compiler consumers no longer call
the textual count accessors. This change preserves the existing register API and
is independent of the Integer-register migration.

`scripts/bc2cpp/typed_argc_check.rb` covers absent, zero, fixed and packed counts,
argument-register spans, conservative call-site arities, and formatting. It makes
the legacy count readers raise to ensure analysis does not format counts. With
`MRBC` set it also checks binary-decoded fixed and packed call shapes. CI runs
host cases in the Ruby job and binary cases in the compiler job.

## Allocation measurement

On Ruby 4.0.5, 100,000 reads of a warmed `n=3|nk=2` instruction through the old
`ArgcSpec.new(insn.n_spec, insn.nk_spec)` path allocated 300,002 objects. The typed
`OperandModel.argc_spec` path allocated 100,002: one result object per query, with
the two temporary count Strings eliminated. This is an accessor microbenchmark,
not a whole-compiler peak-memory or timing measurement.

## Primitive argument-register spans

`Insn#positional_slots` and `#keyword_slots` return Integer register counts
without constructing an `ArgcSpec`. Escape analysis, block operand lookup and
block-self analysis use these readers directly. Absent counts consume no slots,
packed splats consume one slot, and fixed keyword pairs consume two slots each.
`OperandModel.argc_spec` remains available when callers need the full shape.

A host Ruby probe reading both slot counts 100,000 times allocated 100,023 objects
through the `ArgcSpec` path and 9 through the primitive readers, including cold
method overhead. This removes one temporary Struct per escape-analysis span
query; the resulting pair returned by `argument_slots` still allocates an Array.

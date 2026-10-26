# bc2cpp name storage

Typed `:sym`, `:name` and the name component of `:mcnst` operands use shared,
frozen Strings. `OperandSchema::Operand` canonicalizes these values on construction
using Ruby's deduplicated frozen Strings (`String#-@`). Equal names with matching
encoding can therefore share an object across instructions and opcode kinds.
The caller's original String is left mutable and unchanged.

Method, variable and constant-name APIs still return Strings. Literal text,
disassembly, diagnostic operands and numeric/register operands keep their existing
representation. This change is separate from the opcode Symbol and register
Integer migrations.

Ruby manages the deduplicated String storage; the compiler adds no permanent
name-retention table. The decoded-tree cache restores operand name sharing after
Marshal loading, which does not preserve frozen String canonicalization. Changes
to the operand schema already invalidate the decoded-cache fingerprint.

`scripts/bc2cpp/name_strings_check.rb` verifies sharing, caller ownership, encoding,
non-name operands, synthetic instructions and cache restoration. With `MRBC` set,
it also checks repeated names produced by binary decoding. CI runs the host checks
in the Ruby job and the binary checks in the compiler job; both phases are
classified in `scripts/ci/bc2cpp_check_policy.yml`.

## Retained heap measurement

For the closed-world Ruby source set, measured immediately after decoding and a
full GC, 49,053 typed name operands had 6,305 distinct name values. Sharing reduced
their retained String objects from 49,053 to 6,305 and their `ObjectSpace.memsize_of`
total from 2,166,320 to 324,120 bytes (about 85% less). All retained String bytes in
the measured process fell from 23,128,955 to 21,283,915 (about 8%).

The baseline used the same compiler with only operand canonicalization bypassed;
both runs decoded the same source list. These figures describe retained Strings
at the decoded-IREP stage, rather than peak RSS or the complete compiler's heap.
They exclude potential additional sharing of derived ivar names, registry keys,
source paths and diagnostic text.

## Operand lookup indexes

Instructions share frozen kind-to-position indexes by operand schema instead of
allocating a kind-to-operand Hash for every instruction. Each lookup still reads
that instruction's own operand values. Custom operand lists that do not match
the opcode schema use an allocation-free scan; duplicate kinds return the first
operand, and missing kinds return nil. Cache restoration rebuilds the shared
index through the normal operand installation path.

A host Ruby probe parsing and installing 100,000 synthetic SEND instructions
reduced allocations from 2,900,045 to 2,800,047 (about 3.4%). This measures operand
parsing and installation, not the complete compiler or runtime game heap.

# Lazy instruction disassembly

The binary loader builds each instruction's typed operands directly from the
RITE byte stream. It defers `Insn#args` and `Insn#raw` until a diagnostic,
content digest or generated-code comment requests them. IR queries never need
to build, scrub, split, strip or copy the codedump text.

An instruction retains its decoder, original opcode, decoded numeric operands
and next byte address as a rendering recipe. The recipe contains no Proc and
survives the decoded-tree cache's Marshal round trip. The first text read
renders and retains both strings, then releases the recipe references.
Assigning either text field materializes the other first; freezing an instruction
also materializes its text before making the object immutable. Synthetic
instructions keep their existing eager strings.

Typed decoding and diagnostic rendering are separate opcode cases. Changes to
an opcode must keep both consistent. Pool-slot validation still runs during
decoding; ERR's free-form text is a typed operand and is decoded immediately.
ARRAY2 keeps its normalized ARRAY name in diagnostics, while FSTRING retains
its original spelling and persistent-frozen marker. Pool comments retain
codedump's NUL/newline truncation and invalid-UTF-8 replacement behavior.

`scripts/bc2cpp/ir_binary_operands_check.rb` checks binary-only IR queries,
rendering edge cases, field updates, freezing and cached-tree rendering. It
runs in the existing bc2cpp checks job. Decoder cache fingerprints cover both
`irep.rb` and `insn_decoder.rb`, so older snapshots cannot bypass this behavior.

## Allocation evidence

A matched warm-source-cache compilation of the sealed Optcarrot world used Ruby
4.0.5 and mrbc built from pinned mruby `93f276a8f`. Counting every Ruby NEWOBJ
event with GC enabled gave the following results against baseline `db3ef7aef`:

| Allocated kind | Eager text | Lazy text | Reduction |
| --- | ---: | ---: | ---: |
| Array | 4,267,197 | 4,185,330 | 81,867 |
| String | 3,728,692 | 3,368,215 | 360,477 |
| All heap allocation events, including VM internals | 11,267,770 | 10,847,437 | 420,333 (3.73%) |

Both versions used the same fixed-path source world and warmed their own scan
cache before measurement. Their generated C++ was byte-for-byte identical.
This measures allocation counts, including objects later collected; it does
not establish lower peak RSS or faster compilation. See
[compiler profiling](bc2cpp-compiler-data-profile.md) for workload preparation
and cache-comparison rules.

Decoding the saved 13,564-instruction Optcarrot RITE alone, without requesting
text, allocated 480,991 objects before and 231,788 after (51.8% fewer).
Requesting every instruction's `args`, `raw` and typed operands reproduced the
baseline snapshot exactly. End-to-end savings are smaller because diagnostics
and generated comments still need some of that text.

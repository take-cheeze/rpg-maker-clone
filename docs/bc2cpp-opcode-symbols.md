# bc2cpp opcode names

`Insn#op` and decoded IR opcode fields use Symbols. Binary decoding, synthetic
instructions and opcode assignment all normalize at the instruction boundary.
Opcode sets, dispatch tables, branch classifications and analysis queries use
Symbol keys consistently. This avoids repeated opcode String comparisons.

Method names, constant names and other name operands remain Strings. Diagnostic
text, disassembly text, TSV records and report tags also remain Strings; readers
of those formats compare their textual fields as before. Prefix and suffix
operations on opcode names explicitly read their String spelling.

`scripts/bc2cpp/ir_binary_operands_check.rb` checks both decoded and synthetic
instructions, opcode reassignment, and the distinction between opcode and name
operands. Numeric-flow, class-body and compiler fixture checks cover downstream
consumers of the Symbol vocabulary.

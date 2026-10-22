- **bc2cpp** keeps a short-lived literal Array of one to eight immediates (fixnums, `nil`, `true`, `false`,
  symbols) in a C++ buffer on the frame instead of a heap Array, when the escape verdict (ADR 0316) and the
  element and use checks prove that the array never leaves the method and is read only by literal-index `[]`,
  `[]=` and `size`/`length`. Every refusal keeps the Array; `BC2CPP_STACK_TUPLES=0` gives the earlier output
  byte for byte. See [ADR 0545](docs/adr/0545-bc2cpp-stack-tuple-arrays.md). Covered by
  `scripts/bc2cpp/stack_tuples_check.rb` (placement, refusals and interpreted-against-compiled parity).

# Call-context positional argument binding

Receiver-result analysis can bind required, optional, rest, and trailing required
positional arguments using the exact caller argument count. Optional initializer
paths are selected from the method's ENTER jump table. Omitted optional slots
remain unknown until initialized, and rest arguments have Array class without
element assumptions.

Keyword and block parameters remain unsupported. Invalid arity produces no
result proof; runtime argument errors remain unchanged. Set
`BC2CPP_CONTEXT_ARGUMENT_SHAPES=0` to disable expanded signature binding.

Run `ruby scripts/bc2cpp_context_arguments_check.rb` for the binding checks.
See ADR 0355 for the soundness boundary.

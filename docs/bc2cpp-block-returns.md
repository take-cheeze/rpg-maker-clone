# Block return declarations

bc2cpp can keep the class of a call that returns its block's value, or its receiver, when an RBS declaration says
so and the build checks that the declaration is true (BLOCK_RETURNS,
[ADR 0475](adr/0475-bc2cpp-generic-block-returns.md)). It replaces the Profiler-only proof of
[ADR 0344](adr/0344-bc2cpp-profiler-block-results.md).

```rbs
module RGSS
  module Profiler
    def self.section: [T] (String name) { () -> T } -> T   # the call returns the block's value
  end
end
module Kernel
  def tap: () { (self) -> void } -> self                    # the call returns its receiver
end
```

Native methods and program methods are both declared in `sig/bc2cpp`. A file of native declarations
(`rgss_block_returns.rbs`, `core_block_returns.rbs`, and the other fact tables) starts with the marker line
`# bc2cpp-native:`; `tools/bc2cpp/native_sigs.rb` reads that marker, so the file's place does not decide its kind.

How a declaration is checked:

* Ruby. Every definition must be a plain yielder whose yields pass the declared arguments. Every return path taken
  with a block must return a yield's value (`-> T`) or self (`-> self`).
* Native. Each registered C function is scanned: its block may only be read by `mrb_get_args`, `mrb_nil_p` and
  `mrb_yield`/`mrb_yield_argv`, and every `return` must return a yield's value. A function the scan cannot read
  must be reviewed into `tools/bc2cpp/native_block_returns_reviewed.rb` with its file's SHA-256.

A declaration that fails its check is a TC1010 error, and the build stops. The `== declared returns ... ==` listing
shows each declaration as a `BLOCK_RET` line.

At a call with a literal block, the call's result is the class of the block's returns, or of the receiver. The block
runs under the caller's self. This holds only when every method the call can reach is a checked declaration of one
shape. For a native singleton the receiver must be the constant itself. The block must not `break` or `return`.

```sh
MRBC=/path/to/mrbc ruby scripts/bc2cpp/generic_block_return_check.rb
```

Without MRBC the check runs only its host half: the declaration shapes, the native scan and its profiler.cxx mutants,
and the reviewed list.

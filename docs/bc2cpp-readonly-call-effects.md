# Readonly Ruby call effects

Receiver flow retains exact ivar stores across a proven readonly Ruby call:

```ruby
@value = ExactReceiver.new
read_an_ivar
@value.next_method
```

The call must have zero positional arguments and stable closed-world lookup.
Each possible exact receiver must select a Ruby body consisting only of reads,
register operations, literal primitive loads, branches, and returns. Methods
with arguments, blocks, handlers, calls, allocations, or writes remain unknown.
Native methods remain unknown to this effect analysis.

Normal returns clear register provenance. Exceptions retain the existing ivar
widening. Set `BC2CPP_READONLY_CALL_EFFECTS=0` to disable the extension. Run
`scripts/bc2cpp_readonly_call_effects_check.rb` with `MRBC` and a full-core mruby
build for generated-code checks and interpreter parity; its mutation check
covers thirteen conditions plus an unchanged control. See ADR 0356.

## Measured world

On base `0b0e9e9e`, the identical Wio input set emits byte-identical C++ with
this extension enabled or disabled: 2,785 cached dispatch sites and 911 POLY
markers. The fixture's five exact chains demonstrate the new proof path; this
measurement shows no additional eliminated fallback in the shipped world.

# Generated interface tables

`BC2CPP_INTERFACE_TABLES=1` enables automatically generated, shared dispatch
tables for blockless calls in bc2cpp's closed-world builds. Export the flag
when regenerating compiled Ruby; unset it or set it to `0` for the existing
chains. Cached generated C++ must be regenerated when changing the flag.

The compiler discovers implementations without interface declarations. A
method with five to sixty-four eligible classes gets a shared table, keyed by
method name, argument count and implementation rows. A class lookup selects
an adapter for a compiled Ruby method, inherited method, accessor or audited
native entry. Calls with different arities use different adapters; sites with
the same rows share a table and lookup memo.

Short chains and block calls retain their existing dispatch. A table miss
uses the existing checked fallback, including its closed-world error proofs.
Methods that need native argument coercion or a call frame remain outside the
table. Generating a table does not itself prove that every receiver implements
a method.

The initial measured benefit is smaller generated source and faster late-row
or mixed-receiver lookup. First-row hits can be slower; target runtime and
firmware-size benefits have not been measured. See
[ADR 0328](adr/0328-bc2cpp-generated-interface-tables.md) for the paired census,
benchmark results and safety conditions.

To validate and benchmark with a patched host mruby build:

```sh
MRBC=<host-mrbc> BC2CPP_MRUBY_CORE=<core-build> ruby scripts/bc2cpp_interface_tables_check.rb
MRBC=<host-mrbc> BC2CPP_MRUBY_CORE=<core-build> ruby scripts/bc2cpp_interface_tables_bench.rb
```

The check requires `lib/libmruby_core.a` and matching headers. For a 32-bit
`mrb_int` build, supply its compiler/header configuration through
`BC2CPP_CXXFLAGS`, as with the other bc2cpp fixture checks. CI runs the check
alongside the existing POLY_TABLE check in the `fast` shard.

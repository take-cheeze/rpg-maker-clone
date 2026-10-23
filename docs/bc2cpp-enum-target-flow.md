# Enumerator target flow

`CallSiteIndex` treats `to_enum(:name, args...)` and `enum_for(:name, args...)`
as callers of the named method. It resolves every reaching definition of the
name register through the shared bytecode IR, including moves, branches, loops
and exception-handler predecessors. All writers must produce literal Symbols
(`LOADSYM` or a pooled `SYMBOL`).

A branch choosing between `:first` and `:second` adds the forwarded call to both
methods. Agreeing alternatives add only one call. If any alternative is unknown,
the site stays under `UNKNOWN_TARGET`, which every method's caller query includes.
This prevents a known arm from hiding a possible call on another path. The
forwarded argument register and count remain unchanged; keywords retain unknown
arity, and a call without arguments still targets `each`.

`enum_targets` returns the complete finite name set or nil. The existing
`enum_target` API returns a name only for singleton sets. Its consumer in
`ConstantArgumentSites` therefore continues to refuse multi-name dynamic calls.

Packed argument arrays retain a target only when reaching definitions find one
fresh, nonempty literal prefix followed by head-preserving `ARYCAT`/`ARYPUSH`
operations. The allocation-to-call corridor must have no alternate entry,
including handler entries. Other instructions in it must be quiet and cannot
read or write the packed register. This rejects aliases, stores, calls and
replacement of the prefix. Nested reads and writes of that register also refuse
the proof: `ARYCAT` can invoke a source object's `to_a`, which could otherwise
access the array through a closure. The target comes from the first element's
own reaching Symbol definitions at allocation time.

This covers core `to_enum(:gsub, *args)` without making that call a caller of
every method, which would invalidate unrelated sealed parameter contracts.
Unproven packed sites still conservatively reach every method with unknown
arity. Mutable String names remain unknown.

The separate `enclosing_def_names` legacy `METHOD`/`DEF` association still uses
adjacency. Migrating it requires representing a body installed under multiple
names and indexing `SUPER` under every possible enclosing name; resolving the
method register alone would not satisfy that contract.

`scripts/bc2cpp/enum_target_flow_check.rb` covers flow and refusal cases, including
a binary compiler fixture. `class_arg_types_check.rb` verifies that the caller
index continues to protect argument-class inference.

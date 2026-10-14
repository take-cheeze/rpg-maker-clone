# Inferred instance-variable unions

The type report can fill previously untyped instance-variable rows from the
compiler's settled class pools. `inferred:ivar-class-pool` identifies these
independent facts. Existing signatures and previously reported types retain
their sources.

A pool joins every visible writer in the connected inheritance and mixin
family. Reporting never promotes a single `SETIV` observation into a field
declaration. If any writer is unknown, the compiler drops the pool and the
field remains untyped. Foreign writers, reflection, uncontrolled method
installation, and structurally poisoned groups cannot supply these facts.
Checked annotation/native-store pools are also excluded: their runtime guards
do not establish an independent declaration.

The inferred bound includes `nil` unless the existing constructor proof
establishes assignment before the object can escape. Reads inside an
initializer or its nested blocks preserve `nil` even when that assignment
proof succeeds. Multiple proven classes become a union, for example
`Integer | String | nil`.

This affects reports and exported signature candidates only. Generated C++
does not consume the reporting helper. Set `BC2CPP_IR_IVAR_TYPES=0` to compare
against the previous ivar report, or `BC2CPP_CLASS_POOLS=0` to disable the
underlying compiler pools. The compiler's strict Marshal setting and exact
instance/singleton checks still apply.

Run `MRBC=path/to/mrbc ruby scripts/bc2cpp/ir_ivar_types_check.rb` to check
union propagation, nullable fields, constructor reads, opaque and reflective
writers, and admission gates.

The measured engine report gains 40 previously untyped fields (485 to 525).
Independent union/boolean field bounds are recorded in
`sig/bc2cpp/ir_nominal.rbs`; fields needing scalar/container compiler hints
remain available in report/export output.

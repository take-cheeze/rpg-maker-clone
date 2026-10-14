# Receiver-specific parameter facts

The type report can infer required parameter unions for methods whose names
have multiple definitions. It partitions the exhaustive entry-call index by
proven exact receiver classes and the compiler's existing stable method lookup.
For each definition, it joins the independently proven argument types of every
call that can reach that body. For example, `Left#accept` receiving an Integer
and a Float is reported as `Integer | Float`, even if unrelated `Right#accept`
receives a String.

A call can be excluded only when every receiver class has a proven target.
Unknown receivers, unknown reaching arguments, unresolved dispatch, and wrong
reaching arities refuse the entire parameter fact. The existing entry admission
continues to refuse computed names, aliases or reflective symbol mentions,
outside/native callers, constructors, and optional/rest/keyword signatures.
Stable lookup also refuses unknown mixins and method installation. Facts need
at least one reaching caller and complete unguarded read-point class masks.

These bounds use source `inferred:receiver-call-sites`. They are reporting-only:
they do not seed optimizer entry pools, alter runtime dispatch, or recursively
propagate inferred parameters into other method bodies. Existing parameter
proofs take precedence. Set `BC2CPP_IR_ARGUMENT_TYPES=0` to disable the extension.

Run `ruby scripts/bc2cpp/ir_argument_types_check.rb` for the exhaustive partition
and refusal checks.

The measured engine report gains nine required parameter annotations (546 to
555). The independent nullable/union subset is recorded in
`sig/bc2cpp/ir_nominal.rbs`; other proven argument classes remain available
in the report and RBS export.

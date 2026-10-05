# ADR 0355: Positional argument binding in receiver result contexts

## Status

Accepted

## Context

An exact call's argument masks cannot be used as method registers when its
signature has optional, rest, or trailing required parameters. OP_ENTER binds
these registers and chooses one optional initializer jump-table slot.

## Decision

Model strict method positional binding in `CallContextArguments`. Reject
insufficient required arguments, excess arguments without rest, keyword fields,
and block parameters. Keep omitted optionals unknown until their initializer writes them; bind rest to
Array and trailing
required arguments from the end of the caller's argument list. Admit an optional
signature only when its complete initializer table consists of JMP instructions.

OP_ENTER can leave moved trailing values in omitted optional slots; no nil
assumption is made before their initializer executes.

NumericFlow may consume a context's selected ENTER successor instead of joining
all optional initializer paths. Context masks stay local to that call; shared
method argument pools do not change. Rest element classes are not inferred.
`BC2CPP_CONTEXT_ARGUMENT_SHAPES=0` retains mandatory-only binding.

## Consequences

Result chains can retain exact receiver classes through positional defaults and
rest signatures without changing runtime dispatch or argument error handling.
The binding checker covers each optional slot, trailing and rest placement,
arity rejection, unsupported fields, malformed tables, and the disable switch.

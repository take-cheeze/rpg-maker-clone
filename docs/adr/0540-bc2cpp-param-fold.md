# 0540. bc2cpp: decide a parameter's branch from its pooled call-site mask, for complete methods

Date: 2026-10-21

## Status

Accepted. Off by default: it is on only with `BC2CPP_PARAM_FOLD=1`. The engine count with the gate on is not measured
here (it needs the closed-world build).

## Context

The decided-branch folds (ADR 0532) refuse any jump whose tested value reaches the method's entry. A method installed
by `define_method`, `alias_method`, a computed-name send or a `method_missing` hook can be called with an argument no
call site shows, so the entry value is not known from the callers the flow sees. The pooled entry mask (ADR 0276) is the
join of every call site the flow enumerates, so it proves a parameter only when those call sites are the only way in.

## Decision

`CodeGen#param_fold_proves_entry?` (tools/bc2cpp/codegen_param_fold.rb) lets an entry value decide a jump only when all of
these hold:

- the gate `BC2CPP_PARAM_FOLD=1` is set;
- the register is a pooled candidate (its key is still in `@entry_arg_numeric`, so the call sites were enumerated and
  none passed an unmodelled class);
- the closed world is whole: no global refusal and no `method_missing` class;
- the method's name is not installed by `define_method` or `alias_method` (`symbol_installed_names`) and no computed-name
  send can reach it (`numeric_dynamically_named?`);
- the registry holds exactly one definition of that name, owned by the method's owner.

The guard in `decided_branch_outcome` checks each entry definition of the tested value. The flow follows a `MOVE` back
to the parameter, so the entry definition names the parameter's own register. Every entry definition must pass the gate.

## Consequences

- Off by default: the C++ is unchanged unless the variable is set. The gate's fixtures show the fold on a complete method
  and the test kept when a define_method, a computed-name send or a method_missing reaches it.
- Trust is in the call-site enumeration. A computed-name send counts only through a name the program spells as a literal
  (`DynamicNames`), so the gate is exactly as sound as that analysis.
- The define_method fixture keeps its test because the name has two definitions. The gate's own `symbol_installed_names`
  check is not what decides that fixture. A define_method installer on a name with one `def` is refused by that check
  alone, but no fixture isolates it yet.
- Not measured: the engine count of folds the gate adds, and the effect on compile time. Turning the gate on by default
  needs the closed-world CI build and the differential runs first.

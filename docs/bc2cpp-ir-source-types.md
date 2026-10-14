# IR receiver source types

IR feedback consumes complete independent class proofs for instance-variable
reads, constants (`GETCONST` / `GETMCNST`) and incoming arguments from the
compiler's settled exact-class flow. It queries the register at the read point,
so ivar stores, uninitialized nil, intervening calls and joins are included.
These facts may also establish receivers for nominal RBS call-result bounds.

Shared reaching-definition refusals still apply, including handler guards,
closure writes and callee-frame clobbers. The bridge rejects guarded, unknown,
exception, empty and unmodelled masks and requires the existing closed-world
and singleton-free conditions. Unknown sources retain their previous fallback
or refusal; an RBS contract is never promoted to an independent proof.

Independent results appear as `inferred` and may produce inferred return RBS
suggestions. Contract-assisted call chains retain `declared` provenance.
Use `BC2CPP_IR_SOURCE_TYPES=0` for a reporting comparison. Generated C++ and
direct-call lowering are unchanged. See [ADR 0444](adr/0444-bc2cpp-ir-source-types.md).

The measured engine report resolves 1,654 previously unknown IR observations
(unknown: 12,250 to 10,596), with the original signatures held fixed. These
are repeated register queries, not newly typed declarations; the overall typed
return count stays at 891 because older return analysis already covers them.
The existing `sig/bc2cpp/trace_params.rbs` now replaces 27 `untyped` returns
with independently inferred bounds. Parameter contracts are retained; generic
container elements remain `untyped` and constructor returns remain unchanged.

# Call-result types in bytecode IR

IR value queries now consume complete call-result proofs from the compiler's
settled exact-class return oracle. This makes existing audited method, native
and builtin result facts available through shared reaching definitions, MOVE
chains and joins. It does not create a second method-identity analysis or
change generated dispatch.

`CodeGen#bytecode_ir_call_result_classes(irep, index)` returns a frozen class
set or nil. The bridge requires an authoritative foreign-method census, a
singleton-free closed world and settled result analyses. It rejects OTHER,
CHECKED, exception and unmodelled object-kind bits rather than returning a
partial set. Primitive builtin fallback uses the existing per-class identity
checks and requires complete receiver and operand evidence. Block calls use
the audited block oracle without an ordinary-call fallback. Integer results
still include big integers and do not establish machine width.

The reporting path passes these proofs as `inferred_calls:` to
`BytecodeIR::Types`. They are available to both `#at` and `#fact_at` and retain
inferred provenance. An unknown receiver may have a known result when the
existing compiler proves a complete summary across every possible target;
a matching method name alone is insufficient.

## RBS receivers and chains

For ordinary explicit-receiver calls, `RbsSignatures.ir_types` can also resolve
return contracts from the receiver's nominal class bounds. For example:

```rbs
class Root
  def child: () -> Leaf
end
class Leaf
  def finish: () -> Symbol
end
class Use
  def run: (Root root) -> untyped
end
```

`root.child.finish` has a Symbol bound conditional on the argument and both
return contracts. Its fact records all three dependencies. Every receiver
union member must have a matching contract; one missing member keeps the
whole result unknown. Ancestor lookup uses the same program hierarchy as
implicit self-call contracts. This does not prove an exact receiver or method
identity and cannot justify unguarded native dispatch.

Block-call results do not borrow normal RBS return contracts: `break` can
replace the call's result without being a normal return from its callee.
Independent block results remain available when the compiler's block oracle
proves them. Module mixin lookup (include, prepend, nested include, a superclass's include)
is described in [IR feedback](bc2cpp-ir-feedback.md#boundaries); a module reached
twice in the chain is refused. Explicit `self` without an independent receiver
proof, packed-receiver refinements and argument-dependent RBS return expressions
remain follow-up work.

## Bounds and reporting

Recursive receiver queries have a depth limit of 24, an expansion limit of
2,048 and a bounded memo table. RBS receiver unions have a 16-class limit; existing
reaching-definition budgets and clobber/handler/closure refusals still apply.
Cycles refuse rather than guessing a fixed point. Context-dependent cycle or
budget refusals do not poison later root queries.

Complete contract-assisted returns can now appear in method facts with source
`derived:contracts` and a dependency list. They remain excluded from
independently inferred RBS suggestions. `BC2CPP_IR_CALL_RESULTS=0` disables
automatically supplied compiler call facts and explicit receiver contract
resolution for comparison; ordinary literal and implicit block-free self-call
facts remain available.

See [IR feedback](bc2cpp-ir-feedback.md) for the report and RBS export workflow,
and [ADR 0443](adr/0443-bc2cpp-ir-call-results.md) for the decision.

## Engine coverage measurement

A comparison over the same closed-world engine sources and existing signatures,
with host mrbc and `BC2CPP_STRICT_HINTS=0`, found:

| Metric | Before this extension | With the extension |
| --- | ---: | ---: |
| Unknown IR queries | 13,393 | 12,250 |
| Independently inferred IR queries | 2,987 | 4,128 |
| Contract-assisted IR queries | 193 | 195 |
| Typed method returns | 889 / 2,941 | 891 / 2,941 |

The 1,143 newly answered queries were all previously stopped at call results:
1,141 now have independent proofs and two use contracts. This resolves 25.7%
of the 4,441 such baseline queries. Query reasons also become more specific,
so merely counting fewer `unknown:SEND*` reasons would overstate the gain.

One new independent return is `RPG2k::Scene::Battle#refresh_battle_status`
(`nil | RPG2k::Window`). The other newly reported return is the existing
contract-assisted Integer bound of `Game::Party#insert_item_in_bag`.
Required parameter and ivar coverage stays at 546 / 2,497 and 485 / 1,066.
Most compiler result facts were already represented in the older declaration
report; exposing them to IR queries does not mean discovering equally many
new method signatures. The comparison switch disables call-fact propagation,
but retains contract-derived return reporting, so its typed-return count is
890 rather than the pre-change 889. No runtime speedup was measured.

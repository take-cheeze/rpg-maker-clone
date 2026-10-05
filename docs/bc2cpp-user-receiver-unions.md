# User receiver unions

Closed-world return analysis can join results from two to eight exact user
receiver classes. Every selected method must prove the same single result
class through stable Ruby lookup. Different overrides, missing methods, nil
and unknown receivers withdraw the proof.

An inherited method's self can also be modeled as its declaring class plus all
known descendants. The bytecode must have one owner, and the entire class
hierarchy must be enumerable and contain at most eight classes. An outside
reopening or unresolved superclass prevents this assumption.

Constructor flow reads the class constant before the `new` instruction. It
requires the existing audits for stable constant identity and standard
`new`/`allocate` lookup, then joins the result with other CFG paths. Constructor
overrides keep existing analysis.

If all exact receiver classes select the same compiled Ruby body, the call can
also use that body directly. It passes the actual receiver as self and retains
the existing arity and emitted-owner checks. Differing compiled bodies use
exhaustive class cases without dynamic fallback. An uncertain, wrong-arity or
unemitted member keeps dispatch.

Set `BC2CPP_USER_RECEIVER_UNIONS=0` to disable the extension. Run
`scripts/bc2cpp_user_receiver_unions_check.rb` for generated-code and runtime
parity checks, and its mutation check for ten rejected changes plus a control.
See [ADR 0352](adr/0352-bc2cpp-user-receiver-unions.md).

## Measured output

The same-tree Wio comparison against base `ba3a3ef0` changes cached sites from
2,786 to 2,785, with POLY unchanged at 911. The removed site is `to_h` in
`RPG2k::Scene::DebugMenu#max_id`: its receiver is exactly `Game::Switches` or
`Game::Variables`, so both compiled bodies have direct arms. The fixture has
15 by-name send sites with the extension disabled and 11 with it enabled.
These static counts include cold fallback paths and do not measure speedup.

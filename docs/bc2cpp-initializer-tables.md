# Tableless compiled initializers

Closed builds can omit a class's named `initialize` entry when every route to
it is proven to use the compiled implementation. The implementation remains
available; this removes the method-table registration, not the constructor.
Other builds retain their current constructor interface.

The proof enumerates every Ruby `new`, including zero-argument, wrong-arity,
inherited and class-parameter calls. It also accounts for `super`. An unknown
receiver refuses the proof; argument counts cannot excuse an unknown route,
because even a failing call can look up the initializer. The class hierarchy
must be closed, ordinary constructor lookup must hold, and native or foreign
access to the class, initializer aliases, introspection and unbounded Ruby
reflection retain its registration.

The emitter marks a direct constructor only when its class and ordinary
constructor lookup are stable. Evidence is read from the final compiled
method, not from a speculative cleanliness probe. Its caller must be eligible
for residual-body stubbing and must not use a resumable variant, bytecode Proc
creation or a saved interpreted guard. Calls in class/load bodies and unproven `super`,
keyword or block routes therefore keep the slot. All compiled gem units must
provide evidence, and every enumerated route must be covered. Missing evidence
keeps the registration.

`INITIALIZER_TABLE_EVIDENCE` in generator diagnostics records candidate sites,
final direct routes and refusal reasons. The existing static-dispatch proof
combines the units and settles its omission lists to a fixed point. A proven
initializer still executes only as compiled C++ after its named slot is
removed; the proof does not mistake that removal for a new bytecode entry.
The open list remains unchanged.

The source/class analysis runs once before shared generation forks. Per-unit
work checks only that unit's final emitted methods. Existing `respond_to?`
phantom handling preserves the closed build's supported name probes.

Run `scripts/bc2cpp/main_roots_check.rb` with the full-core fixture runtime to
check physical table removal, retained constructor results, inheritance,
wrong-arity calls, reflection and missing proof inputs. Refresh and verify the
static omission lists before building a real closed engine.

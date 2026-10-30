# Sharing unchanged numeric-flow read states

`GETIV` writes the tracked slot's class mask and slot provenance to its destination.
`RESCUE` writes the unknown match-result mask to its second register. Numeric flow
can reuse an incoming state when these writes leave every state entry unchanged.
The existing `copy_reg_write` check now accepts the intended provenance, so an
ivar read can retain its slot provenance instead of forcing a new Array.

Sharing requires the resulting destination mask and provenance to match, unknown
element facts, no destination class test, and no register aliases or class tests
that overwriting the destination would invalidate. Opaque captured destinations
still get the unknown mask and no slot provenance. Write summaries are updated
on both copied and shared paths. A real metadata change copies the input before
mutation; the incoming state may be frozen or shared by other CFG edges.

Only flow-created contexts enable read sharing by default. Standalone transfer
contexts retain copying unless explicitly enabled. Set
`BC2CPP_NUMERIC_READ_COPY_ELISION=0` to restore the original read transfers.

`scripts/bc2cpp/numeric_flow_speed_check.rb` exercises unchanged frozen reads,
1,000 randomized transfers with slot provenance, register aliases, element facts,
class tests and captured writes, and full-flow comparisons of every state, write
summary and oracle call across loops, handlers and context-dependent entry edges.
The numeric operand and join-soundness checks cover generated code and runtime
behavior.

## Measurements

Two alternating warm-cache whole-engine comparisons on Ruby 4.0.5/YJIT:

| Pair | Copying seconds | Sharing seconds | Copying allocations | Sharing allocations |
| --- | ---: | ---: | ---: | ---: |
| A | 51.37 | 52.34 | 66,374,961 | 66,325,310 |
| B | 52.89 | 51.65 | 66,373,367 | 66,325,685 |

The allocation saving is about 48,000–50,000 objects (0.07%). Timing varies in
both directions; these runs do not establish a whole-generator speedup. C++
and diagnostics excluding timing lines were byte-identical. These comparisons
use a snapshot based on `0cec9c47e`, before the independent source-parse cache
change, and generate all configured engine/core owners in one closed-world call.

A focused benchmark of 20,000 unchanged ivar reads, reusing a decoded step and
context, removed 20,000 state Array allocations. Warm repeats took about
0.0046/0.0020 seconds with 8 registers, 0.0078/0.0020 with 32, and
0.0131/0.0017 with 128 (copying/sharing). This isolates the optimized transfer;
it does not imply the same speedup for a complete numeric analysis or game.
The allocation regression check exercises this production transfer path.

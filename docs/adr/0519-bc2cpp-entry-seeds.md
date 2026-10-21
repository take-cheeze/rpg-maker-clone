# 0519. Entry points as seeds of the call-graph argument types

Date: 2026-10-20

## Status

Accepted

## Context

The call-graph argument summary (ADR 0446) seeds only from by-name callers that
bc2cpp can enumerate. The entry points are native calls that bc2cpp does not see
as SENDs, so no parameter they supply can be typed:

- The wio closed world (the one the type check analyses) boots RPG2k in
  `app/wio/src/maix_game_main.cxx`: `mrb_value args = mrb_ary_new(g_mrb);` and
  `mrb_obj_new(g_mrb, mrb_class_get(g_mrb, "RPG2k"), 1, &args)`. The desktop and
  browser entry, `src/main.cxx`, builds one of six makers (RPG2k, RPGVX, RPGXP, MZ,
  MV, WolfRPG) the same way, with the ARGV Array `mrb_ary_new_capa` creates.
  The constructor pools (ADR 0313) refuse this, because native source spells the
  class name.
- `src/main.cxx` also calls `start` with no argument on the maker object. The
  wio entry does not call `start`; it calls `main_loop` directly.

## Decision

Add ENTRY_SEEDS (`tools/bc2cpp/ir_entry_seeds.rb`, `codegen_entry_seeds.rb`):

- The `initialize` of a maker, at position 1, is seeded with `Array`. The seed
  is a complete caller set only when all of these hold:
  - every native source that spells the maker's name is a known entry
    (`IrEntrySeeds::ENTRIES`), and each of those spells it only in construction
    calls (`mrb_obj_new(<state>, mrb_class_get(<state>, "<Maker>"), 1, &args)`);
  - each such entry declares its Array and does not reassign `args`;
  - no foreign Ruby source spells the name;
  - the constructor-pool scan finds no Ruby `new` or `super` that can reach the
    body, and no other refusal applies. The scan is the pool's own, except that
    the native spelling of an admitted maker is accounted for (`exempt:`). The
    pools themselves never see the exemption.
- The `start` receiver is not wired. The closed-world self model already gives
  exactly the maker class for its `start` (no subclass), so a seed would be
  identical.
- Seeds feed only the reporting table (IrCallGraphTypes, source
  `inferred:call-graph`). Codegen does not read it, so the compiled output is
  unchanged. `BC2CPP_ENTRY_SEEDS=0` turns the seeds off.

## Consequences

- The type check can type the maker's argument and whatever it forwards.
- A change to an entry that breaks the admission conditions (a new spelling, a
  moved or reassigned Array, a new construction) refuses the seeds rather than
  guessing.
- The admission relies on the closed-world assumption the outside-spelling rule
  already makes: native code constructs a class only by a spelled name. The PSP
  entry (`app/psp/main.cxx`) constructs through a computed name, but its maker
  strings are spelled in that file, which is not an entry, so the seeds refuse
  there. The PSP build is its own closed world and is not the wio one.
- Ruby `new` of a maker, anywhere in the program, refuses its seed. A seed that
  must join Ruby callers needs the argument union, which is not implemented.

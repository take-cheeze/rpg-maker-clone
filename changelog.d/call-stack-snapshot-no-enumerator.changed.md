- **Two more unconditional per-frame allocators found via
  `RGSS::Profiler.stats[:object_types]`, both outside `Scene::Map`'s draw
  path this time — in the interpreter's own state-snapshotting.**
  - **`Game::Interpreter#call_stack_snapshot`** (`Scene::Map
    #record_foreground_event_exec`'s own every-frame call, backing the
    Save/Continue call-stack persistence added in cycle #191) built
    `@call_stack + [[@list, live_index, ...]]` — two extra array literals to
    hold the current frame's own tuple — then walked the result via
    `#each_with_index.map`, which allocates an Enumerator, boxes one `[item,
    index]` pair per iteration, and allocates a Proc plus its closure env for
    the block. Rewritten as a preallocated `Array.new(n + 1)` filled by a
    plain `while` loop, with the current (innermost) frame handled once
    after it since it never actually lived in `@call_stack`. Same per-frame
    values (checked against `rpg2k_logic_check.rb`'s existing
    `#call_stack_snapshot` unit tests, which already cover the nested-Call-
    Event multi-frame case and the Key Input Proc rewind this rewrite has to
    reproduce exactly): measured **16 → 2 Array allocations per frame** on
    this section, in the same profiler run used for the rest of this round's
    fixes.
  - **`Game::Map#substitution_snapshot`** (`Scene::Map
    #record_tile_substitutions`'s own every-frame call) unconditionally
    `dup`'d both Tile Substitution tables every frame regardless of whether
    a substitution had ever actually run — Tile Substitution itself is a
    rare command. The dup'd pair is now cached and only rebuilt when
    `@substitutions[0]`/`[1]` are no longer the same objects last dup'd
    from: `#substitute_tile` and `#restore_substitutions` both only ever
    *reassign* those slots to a fresh Hash/Array, never mutate one in place,
    so an unchanged object identity really does mean unchanged contents.
    Measured **~1.0 → ~0.0 Array allocations per frame** on this section
    (no substitution ever ran during the capture window).

  Verified against `scripts/rpg2k_command_soak.rb` (368,332 real event
  commands across both Nepheshel variants), `scripts/rpg2k_logic_check.rb`'s
  dedicated `#call_stack_snapshot`/`#restore_call_stack` unit tests, and the
  rest of the RPG2000 logic/render/scene checks — all pass, unchanged.

# 0376. Block loops inside a rescue range are inlined into the try body, and `each` spreads Array rows

Date: 2026-10-07

## Status

Accepted

## Context

An inlined block loop (`ary.each { }`, `n.times { }`, ADR 0147/0152) is emitted into the method's own `_impl`. A method
level `rescue` is different: `recognize_rescue_regions` lifts the protected range `[begin_addr, end_addr]` into a separate
function, `emit_rescue_try_body`, run under `mrb_protect_error`. `compile_method` therefore skips every address of the
range (`rescue_claimed`, RESCUE_INLINE_BLOCK_FIX, #1909): a loop registered there would be emitted after the rescue glue,
on the path only an exception reaches, with a receiver register that holds the exception. The try body itself ran no
inliner pass, so every literal block inside a `rescue` range went through the block-call fallback: an `RProc` built with
`mrb_proc_new_cfunc_with_env`, a standalone block function, and `mrb_funcall_with_block` (or, in the closed world with
ADR 0310's direct arms, `Array_each_impl` with that RProc).

In the shipped hot-only builds (`BC2CPP_HOT_METHODS=tools/bc2cpp/hot_methods.txt`: wio, psp, maix) the receiver of 9 of
those loops is a proven Array or Hash and the block is a pure mandatory-arity block, so the only thing standing between
them and an inline `for` was the range:

| Method | Loop | Why it was a call |
| --- | --- | --- |
| `Scene::Map#apply_move_requests` | `reqs.each { \|r\| ... }` | whole-method `rescue` |
| `Scene::Map#apply_location_requests` | `reqs.each { \|r\| ... }` | whole-method `rescue` |
| `Scene::Map#apply_halt_request` | `@events.each { \|e\| ... }` | whole-method `rescue` |
| `Scene::Map#apply_sprite_flash_requests` | `reqs.each { \|r\| ... }` | whole-method `rescue` |
| `Scene::Map#build_parallels` | `(@parallels \|\| []).each`, `@events.each`, `previous_map.each { \|id, prior\| }` | whole-method `rescue` |
| `Scene::Map#draw_transition_mask` | `tr.visible_rects.each { \|x, y, w, h\| }` | `rescue` and block arity 4 |
| `Scene::Map#patch_anim_cells` | `@anim_cells.each { \|rx, ry, lower, upper, upper_drawn\| }` | block arity 5 (no rescue) |

The last two also need multi-parameter binding: `recognize_each_regions` admitted only a one-parameter block.
`patch_anim_cells` has no `rescue`; it is closed by the spread alone (the census counts it with the other eight).

**What the VM does with a multi-parameter block.** `Array#each` yields one value per element (`yield self[idx]`). For a
non-strict proc, `OP_ENTER` (`3rd/mruby/src/vm.c`) runs `len > 1 && argc == 1 && mrb_array_p(argv[0])`: an Array element is
replaced by its own elements, parameters past its length stay nil and elements past the last parameter are dropped. The test
is the element's type; no `to_ary` is called, so an object that answers `to_ary` is not spread. Any other element binds the
first parameter alone and leaves the rest nil. This is ADR 0271's rule, which the direct block entry already follows.

## Decision

### RESCUE_TRY_INLINE: the try body runs the inliner passes over its own range

`compile_method`'s pass loop is now `run_inline_loop_passes`, and `emit_rescue_try_body` calls it for its range with
`try_range:` (before its block-call fallback pass, as `compile_method` orders them, so the fallback only sees what the named
inliners left). Nested rescue ranges are claimed first and run their own passes in their own function. The passes are the
same code with the same emitters; what changes is where a region may be claimed and what it may contain. The conditions, and
where each is enforced:

| | Condition | Enforced by |
| --- | --- | --- |
| a | The receiver proof and the block arity gate are the method's own. The recognizers run on the whole method irep, not on a slice, and their regions are then filtered to the range. | `run_inline_loop_passes` passes `irep` unchanged; `rescue_try_inlinable?` keeps a region only when both its anchor (`BLOCK`) and `SENDB` lie in `begin_addr..end_addr` and before the exit `JMP` at `end_addr` (the try function's `return`). |
| b | A `return` inside the body returns from the *method*, but a C++ `return` only leaves the try function, whose result `emit_rescue_glue` takes as the range's value. This is refused, not emulated. | `rescue_try_inlinable?` refuses a block that contains `RETURN_BLK` at any depth (`irep_tree_has_op?`); a second layer, `rescue_try_glue_safe?`, scans the emitted glue (string literals and comments dropped) for a `return` and for a `goto L<addr>` outside the range, and discards the region with its nested block functions. A `break` goes to the loop's own end label, inside the try function. |
| c | Writes to captured locals reach the method's registers. | Unchanged: `rescue_ref_regs` already walks every block created in the range (and its nested blocks) and passes each local one writes, and each local a block created outside the range touches, as a `bc2cpp_ref_r<N>` alias (`mrb_value& r<N> = *ctx->bc2cpp_ref_r<N>`), so a level-0 `SETUPVAR` of the inlined body assigns the outer register. The check pins this. |
| d | Labels and extra registers stay in the try function. | The loop's registers are `r<irep.nregs + k>`, declared inside the loop; its labels are `Lbc2cpp_*_<addr>` and `LBLK<addr>_<pc>`, emitted in the try function's instruction walk, with `body_targets` keeping a jump-target label on a claimed `BLOCK`. A pass is skipped for a block body's own `rescue` (`inline_mand` is passed by `compile_method` only), whose register model is a block's, and for a resumable method, whose loops live in the step function's flat part. |
| e | A `raise` in the body reaches the same handler and ensure order. | The loop is C++ inside the function `mrb_protect_error` runs, so a raise unwinds out of it to the same glue (`bc2cpp_set_errinfo`, the clause tests, `RAISEIF`); methods with an `ensure` have no rescue region (`recognize_rescue_regions` needs every handler to be a rescue), and a caller's `ensure` runs after the handler as before. Compiled-versus-interpreted fixtures pin the order. |
| f | GC and frame-slot safety are those of the existing inliners. | Nothing is allocated by the loop control; the receiver stays in its register for the whole loop; the body's registers are loop-local `mrb_value`s reset to nil per pass, exactly as `inline_block_frame` does in `_impl`. |

Also refused in a try body: a block that forwards the method's own block (`needs_blk`: the try function receives
`bc2cpp_blk` only for a method that declares it), and the `Profiler.section`/`frame` pass, whose begin and end calls
bracket a separate function and would be skipped by a raise (the block-call fallback it replaces keeps the end call).
`BC2CPP_RESCUE_INLINE_BLOCKS=0` turns the whole change off and is byte-identical to the previous output.

### EACH_SPREAD: a 2..8 parameter `each` block binds a row

`recognize_each_regions` admits a pure mandatory-arity block of 2..`EACH_SPREAD_MAX` (8) parameters and records
`spread: n`. `emit_each_inline` then binds, per element, `row = <element>`; `if (mrb_array_p(row))` each parameter `k < n`
is `RARRAY_PTR(row)[k]` when `RARRAY_LEN(row) > k` (else it keeps its nil from `inline_block_frame`), otherwise the first
parameter is `row`. The values are copied before the body runs, so writing a parameter writes the copy, never the row; nothing
is allocated, so the receiver keeps the row alive exactly as it does for the one-parameter loop. The element-class hint is off
for a spread block (the elements are the row's, not the row). A block wider than 8 parameters keeps the call.
`BC2CPP_EACH_SPREAD=0` restores the one-parameter-only gate. This is not limited to rescue ranges: an unprotected multi-parameter
`each` over a proven Array is inlined the same way (`Game::Interpreter#key_input_result`, and more in the full world).

## Consequences

Measured on master `d7212a1c`, the wio closed-world shipped pass of `scripts/bc2cpp_coverage_report.rb`, before being the
same tree with both switches off (byte-identical output), after with the change; `scripts/bc2cpp_rescue_inline_census.rb`
counts them (docs/bc2cpp-dynamic-site-census.md has the per-method table):

| Measure | Hot-only before | Hot-only after | Full before | Full after |
| --- | ---: | ---: | ---: | ---: |
| `mrb_funcall_with_block` sites | 39 | 29 | 445 | 441 |
| `BLOCK_FALLBACK` markers (an RProc and a block function per site) | 37 | 27 | 461 | 439 |
| the seven methods above: `BLOCK_FALLBACK` markers | 10 | 1 | 10 | 1 |
| the seven methods above: generated lines | 1,824 | 1,672 | 1,922 | 1,778 |
| generated lines of the shipped file | 56,014 | 55,840 | 445,055 | 444,596 |

All nine sites of the table are closed in the hot-only world (the tenth removed site is `Game::Interpreter#key_input_result`,
an unprotected arity-2 `each`). The one that remains in `build_parallels` is `@common.each`, an ivar whose class is not proven.
The full world already reached the seven methods through ADR 0310's direct arms (so its `mrb_funcall_with_block` count does
not move for them), but each still built an RProc and a block function. The 22 fewer markers there are those nine and
thirteen more: `Game::Interpreter#key_input_result`, `Game::Actor#learn_level_skills`, `Game::State#seed_screen_transitions` and
`#seed_vehicle_positions`, `Scene::Battle#apply_battle_event_requests` (2), `#battle_recovery_lines`, `#draw_battle_stat_segment`
and `#run_battle_events`, `Scene::Map#draw_captured_transition`, `RGSS.windowskin_rect_probe`, `RPG2k#continue_game` and
`#start_new_game` (the New Game site of #1909). The `NOMETHOD` listing is identical in both worlds, so
`NOMETHOD_REVIEWED` is unchanged. The generated C++ of both worlds passes `g++ -fsyntax-only`.

- `scripts/bc2cpp_rescue_inline_block_check.rb` (build.yml, `core-mrbtest` shard with the full-core build) holds the shape of
  the generated code and compares compiled and interpreted runs on real mruby: a raise inside the block reaching the handler,
  a handler that continues, an unmatched raise unwinding through a caller's `ensure`, `next`/`break`/`return`, captured locals
  written and read after the range, arity 2/4/5 over short, long, empty, `nil`, non-Array and `to_ary` rows, a Hash and a
  `times`, nesting, and a rescue inside a block. `scripts/bc2cpp_rescue_inline_block_mutation_check.rb` (build.yml, `fast`) breaks
  the passes, the kill switches, the range filter, each layer of the `return` refusal and the spread (binding, index, length
  test, `to_ary`, non-Array element, arity gate) one at a time.
- Refusals that remain by design: a `return` from the method through a protected block (a method-return protocol for try bodies
  would be the way to take them), a block-body `rescue`, a resumable method, `needs_blk`, the profiler pass, a block wider than
  8 parameters, and a receiver the method does not prove (`@common.each`).
- The spread widens `each` inlining for the whole world: every unprotected `each` over a proven Array with a 2..8 parameter
  block becomes a `for` loop. The `NOMETHOD` and `POLY` listings do not change; `BC2CPP_EACH_SPREAD=0` is the way back.

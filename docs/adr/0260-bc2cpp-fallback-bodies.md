# 260. bc2cpp: compile the last `#error` bodies, alias locals across a rescue try body, shrink BLOCK_FALLBACK

Date: 2026-09-30

## Status

Accepted

## Context

The whole-program coverage report (`scripts/bc2cpp_coverage_report.rb`, wio
closed world) listed four methods still on the interpreter, six `#error`
markers:

| method | marker |
| --- | --- |
| `LCF#unpack_double`, `LCF#pack_double` | `LOADL references a non-float pool entry (bigint)` x3 |
| `LCF::Array1D#initialize`, `LCF::Array2D#read_row_bytes` | `unhandled opcode JMPUW` x2, and `EXCEPT` x1 |
| `RPG2k::Scene::Map#page_field` | `unhandled opcode BLKPUSH` (uncounted: its text has no "not in this prototype") |

Both LCF loops are `begin; until s.eof?; ...; break if idx == 0; ...; end;
rescue StopIteration => e; e.result; end`. mrbc emits `JMPUW` for that
`break`, and `jmpuw_is_plain_jump?` refused any irep with a catch handler.
`read_row_bytes` additionally joins on `RETURN out`, and
`recognize_rescue_regions` rejected a join `RETURN Rx` with `Rx` other than the
rescue result.

Reading why that second rejection existed exposed a live miscompile in the
recognised shapes. `emit_rescue_try_body` runs the protected range in its own
C++ function on a copy of the register file, so a local the range assigns never
reached the handler or the code after the region. `Scene::Title#load_title_picture`
(`name = ...; ...; rescue => e; $stderr.puts "'#{name}' ..."`) logged an empty
name, and `y = 1; begin; y = x.succ; rescue; end; y + 1` returned the stale
`y`. The `RETURN Rx` rejection had been the only thing hiding it for join
shapes.

## Decision

**LOADL_BIGINT.** mruby's parser turns any literal past int32 into a bigint pool
entry (the decision is on int32, not on `mrb_int`), so the pool is identical for
every target. The codegen rebuilds it exactly as `OP_LOADL` does,
`mrb_bint_new_str(M, "<digits>", len, base)` from the entry's ASCII digits and
signed base (`irep_pool_entry` now carries both), under `#ifdef MRB_USE_BIGINT`
with the VM's own `RangeError: integer overflow` otherwise. No 64-bit C constant
and no computed shift is emitted, so the 32-bit-`mrb_int` targets and a
cross-compiled irep load are untouched. Declared `extern "C"` next to
`mrb_num_shift` (`mruby/internal.h` has no C linkage guard).

**JMPUW_RESCUE_SUPPORT.** vm.c's `OP_JMPUW` only consults ENSURE handlers
(`MRB_CATCH_FILTER_ENSURE`) whose `[begin, end)` covers the instruction and whose
range the target leaves. `jmpuw_plain_jump_at?` states that per instruction: a
rescue handler never intercepts, an ensure that covers the JMPUW and contains the
target does not. Only a covering ensure the target leaves keeps `#error` (the
unwind must run the ensure body). A plain JMPUW inside an ensure range that lands
on its end is remapped like a JMP (`ensure_remapped_jump_target`). The rescue
containment check (`region_boundary_breaches`) now counts JMPUW as a branch, so
a `break`, `next` or `retry` leaving a try body still rejects the region.

**RESCUE_JOIN_RETURN_SUPPORT.** A join `RETURN Rx` (`Rx` not the connector)
takes the ordinary `goto shared_target` path instead of rejecting the region; the
early return was only ever a shortcut for `Rx == connector`.

**RESCUE_LIVE_OUT.** The try body must see, and write, the outer registers it
shares with the handler and the join. `rescue_ref_regs` computes the locals the
range may write (leading-operand writers, `RESCUE`, `EXCEPT`, callee-frame
clobber, `SETUPVAR` of blocks created inside; an unmodelled op means every local)
plus the locals a block created outside the range touches, and those are passed
as `mrb_value*` Ctx fields and declared `mrb_value& rN = *ctx->...` in the try
function, at method level, in a block body and in nested regions (`&rN` of the
enclosing try body's own name, itself an alias). Temporaries above the locals
stay copies: mrbc's stack discipline leaves only the connector live across the
region, which every region shape already relies on. Rejecting instead would have
put seven shipped methods back on the interpreter.

**RESCUE_YIELD_SUPPORT.** A `yield` inside a protected range reads the method's
block through the Ctx like a captured upvar (`bc2cpp_blk`), which compiles
`page_field`.

**TIMES_NO_PARAM_SUPPORT.** `BLOCK_FALLBACK` reasons were categorised (below).
`n.times { ... }` with no block parameter was refused only by the `arity == 1`
gate; the loop is the same with the counter left unbound (the block's R1 is one
of its locals and stays nil per pass). Five sites move from `BLOCK_FALLBACK` to
the inlined loop.

**Runtime definition fallbacks.** SDEF 1, TDEF 1, SCLASS+EXEC 2 all come from two
smoke probes (`RGSS.audio_probe` defines `read` on a runtime-created object,
`RGSS.effect_probe` reopens `class << Graphics` to wrap `update`). The definition
target is created or already-compiled state at run time, so installation has to
stay dynamic; their bodies are already compiled cfuncs. Nothing changed.

## Categorising BLOCK_FALLBACK

330 bodies remain after this change (335 before). By called name: `each` 119,
`each_with_index` 41, `map` 37, `any?` 21, `page_field` 15 (a yielding method,
not an iterator), `section` 11 and `new` 11 (native blocks), `select` 9,
`each_index` 9, `cached_bitmap` 8, `open` 7, `loop` 7, and a tail of one to six.
The receiver is not proven `Array`/`Hash`/`Range` at 65 of the `each` sites, 35
`each_with_index`, 28 `map` and 16 `any?` (no proof means no inliner may claim
it); 27 `each` sites have a proven Array receiver and are refused by arity
(`|a, b|` destructuring, arity 2 to 6) or by a body the inline emitter declines.
There is no `each_with_index`, `any?`, `select`, `find`, `reject` or `loop`
inliner at all. Widening the receiver gate would need a runtime class guard with
both paths compiled, which is a separate design; nothing here is guessed.

## Consequences

- Methods left on the interpreter: 4 to 0. Entry points 2866 to 2871. A new
  dead-fallback site (`Game::Actor#base_stats -> int16_values`) appears because
  `LCF::Array1D` is now fully compiled and therefore embeddable; it is reviewed
  (`respond_to?` guard, only `Array1D` defines the name) and listed in
  `NOMETHOD_REVIEWED`.
- Generated rescue functions pass more registers by reference; 248 alias
  declarations across the gems. The behavioural fix is real and visible in log
  messages (`load_title_picture`, `play_battle_bgm`, ...).
- Dynamic dispatch sites go up (10185 to 10254) purely because five more method
  bodies are compiled and their calls are counted.
- `scripts/bc2cpp_fallback_bodies_check.rb` pins all of the above: hand-built
  ireps under plain CRuby (run in `ruby-checks`, and listed in
  `scripts/coverage_report.rb`), and a compiled-versus-interpreted comparison of a
  fixture against a real core (`bc2cpp-checks`, fast shard). The comparison fails
  with the alias code disabled.

## Not done

Ensure regions whose JMPUW leaves the range, `retry`, multi-class rescue
clauses and the iterator inliners above keep their fallbacks. The bigint arm was
verified against `mrb_bint_new_str` directly; the shared CI core is gem-free, so
the compiled comparison exercises the `RangeError` arm there.

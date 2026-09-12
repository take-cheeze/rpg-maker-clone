# 0146: bc2cpp SUPER support (real `super`/`super(...)` compilation)

## Status

Accepted.

## Context

`OP_SUPER` (a real `super`/`super(...)` call) has been unconditionally unsupported since bc2cpp's own first version, explicitly called out as a "genuine class-hierarchy method-dispatch feature, not a narrow single-opcode mechanical translation" (`compiled_gems.rb`, alongside BLOCK/SENDB and, until docs/adr/0145, RESCUE/RAISEIF/EXCEPT).

A real closed-world survey (mirroring ADR 0145's own RESCUE survey: `SKIP_UNSUPPORTED=0`, every real `#error` marker made visible) found **11** methods blocked only by SUPER, **10** of them inside owners the three `*-compiled` gems already cover:

- `RPG2k::Scene::Battle#initialize`/`DebugMenu#initialize`/`ItemMenu#initialize`/`Menu#initialize` — explicit `super parent` (one arg), into `RPG2k::Scene::Base#initialize`.
- `RPG2k3::Scene::Battle#update`/`#drive_battle_command`/`#enter_command_phase`/`#open_battle_options`/`#advance_actor`/`#prev_commandable_actor_index` — bare `super` (zero mandatory args), into `RPG2k::Scene::Battle`'s own same-named methods.

The 11th (`RGSS::Bitmap::LoadError#initialize`, into native `RuntimeError#initialize`) isn't a covered owner and reaches native code regardless — out of scope, same as any other native-reaching call site.

Unlike RESCUE, this needed no region-recognition machinery: `SUPER` is one ordinary instruction sitting in bc2cpp's existing goto-threaded control flow. But it depends on two real facts about *this program*, neither of which `compile_insn` can re-verify locally at codegen time, so both are checked once, by hand, and gated behind an explicit allowlist (`SUPER_TARGETS`) rather than a general, always-safe translation:

1. **Block forwarding.** Real `super`/`super(...)` (mrbc's own `codegen_super`/`codegen_zsuper`) unconditionally forwards whatever block was passed to the *enclosing* method. A compiled `_impl` function has no block parameter in its own C++ signature at all (every register besides self/mandatory-args is unconditionally nil-initialized), so this forwarded value is always nil — correct only if no real caller of the enclosing method ever actually supplies a block. Checked directly for all 10 targets: grepped every real call site of `Battle.new`/`DebugMenu.new`/`ItemMenu.new`/`Menu.new` and of the 6 `RPG2k3::Scene::Battle` method names across the whole closed world — none pass a block literal.
2. **No interposed module.** Real `super` walks the actual C ancestor chain, which can include an `include`d/`prepend`ed module between a class and its declared superclass; jumping straight to the registered superclass would skip a same-named override in one. Checked: the whole closed world has exactly one real `include` anywhere (`Enumerable`, an unrelated class), so this holds for every target here.

Both are facts about this program today, not language guarantees — a future `SUPER_TARGETS` entry re-checks them, never inherits them.

## Decision

- **Registry**: `build_registry`'s `CLASS`-instruction walk now also resolves the real superclass value sitting in the very next register (`OP_CLASS`'s own real shape, `3rd/mruby/include/mruby/ops.h`: `R[a] = newclass(R[a], Syms[b], R[a+1])`) via a new `resolve_superclass_ref`, a backward register-write walk in the same spirit as `trace_new_target`'s own GETMCNST/GETCONST chain-walk and `resolve_singleton_receiver`'s own bare-GETCONST case — general-purpose here (not gated on a pre-vetted table) because the caller is always actively walking the exact real lexical namespace a bare superclass reference would resolve against, the same "real by construction" guarantee `resolve_singleton_receiver` already relies on. Verified against real disassembly for all three real shapes: a bare constant (`class Foo < Bar`), a qualified chain (`class Battle < RPG2k::Scene::Battle`, a real `GETCONST`/`GETMCNST`/`GETMCNST` sequence — not a single instruction, checked directly rather than assumed), and no explicit superclass (`LOADNIL`, real Object default).
- **Codegen**: `compile_insn`'s new `SUPER` case resolves the target via `super_target` (owner's own registered superclass, same method name, gated on `SUPER_TARGETS`, target itself must compile clean) and emits a direct C++ call with the `n` explicit arguments already sitting in consecutive registers — the trailing block-forward register is read from nowhere (see point 1 above; there is nothing to forward).

Anything outside `SUPER_TARGETS` keeps falling through to the existing, honest `#error unhandled opcode SUPER` — never a silently wrong translation.

## Verification

- Real runtime test (a small harness against a freshly-built vanilla mruby core, exercising the actual bc2cpp-generated code): explicit-arg `super(parent)` correctly sets `@parent` on the real instance via the real superclass method; a two-level bare-`super` chain (`Battle3#update` → `Battle#update`, no further super) dispatches with `self` intact throughout, confirming a devirtualized super call never substitutes a wrong receiver.
- Real end-to-end regen of all three `*-compiled` gems: `mruby-lcf-compiled`/`mruby-rgss-compiled` byte-for-byte unaffected; `mruby-rpg2k-compiled` gains exactly the 10 predicted methods, zero regressions (full whole-program MONO/POLY registry diff is empty).
- All three gems' real `register.cxx` compile clean against real mruby headers with the regenerated output.

## Consequences

- A modest yield (10 methods) compared to RESCUE's 91-93, but low-risk: no new region-recognition machinery, a bounded registry extension plus one new `compile_insn` case, and every soundness-critical fact checked against real disassembly and real call sites rather than assumed.
- `RGSS::Bitmap::LoadError#initialize` (native superclass) and general MRO/native `super` dispatch stay out of scope, the same honest way BLOCK/SENDB stays out of scope for RESCUE.
- Adding a future `SUPER_TARGETS` entry means re-checking both the block-forwarding and no-interposed-module facts for it specifically — `resolve_superclass_ref`/`super_target` themselves impose no additional restriction beyond "the target compiles clean and is in this table."

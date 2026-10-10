# 0384. bc2cpp: the class-blind `@outside_names` gate, classified, and the one covered-class slice

Date: 2026-10-10

## Status

Accepted

## Context

`ClosedWorld#refusal` keeps a send dynamic with `:core_or_native` when `@outside_names` (the names some native or
outside-Ruby source defines) holds the name. The lever asked for: make that gate class-aware, so a send named `name` on
a receiver proven to be a compiled user class does not stay by name only because `RGSS::Font#name` or `Symbol#name`
exists. The shipped-pass census (`closed_world_kept`, 223 sends) lists 182 `core_or_native`, 29 `dynamic_install`, 9
`singleton_definer`, 2 `unlisted_class`, 1 `opaque_definer`.

The class-aware form already exists. ADR 0317 (`scoped` + `native_free`), ADR 0323 (`resolves_in_ruby?`,
instance-scoped installs and unknown definers) and ADR 0302 judge the gate against the receiver's proven set `S`
instead of the whole name, for both the exact-class flow and the call facts. What this change measured is what is left
and why.

## Measurement

Master `5ddf1d98`, wio closed world, shipped pass (`SKIP_UNSUPPORTED=1`). A temporary trace in
`guarded_fallback_line` (not kept) wrote, for every kept site, the proven set `instances`, `scoped`, `native_free`,
`instance_scope` and the raw flow mask; `BC2CPP_RECEIVER_PROOF_REPORT` (ADR 0331) gave the source of each receiver.

| Class of the 223 | Sites | Why it stays |
| --- | ---: | --- |
| receiver set unproven | about 200 | the receiver register is an argument (`name` 20, `string` 14, `at` 7 ...), an ivar whose pool carries `OTHER` (`resume`, `stop`), an element, a call result with an unmodelled return, or an inlined loop body that has no flow position (`wait` x3). No class-aware gate can be consulted without a set |
| set proven, an Array/Hash member | 15 | `Array#delete`, `shift`, `include?`, `Hash#delete`, `count`: the set holds a core class with no frame-independent entry (ADR 0323, "cells that block") |
| set proven, native member covered by an arm already emitted | 2 | `@map_viewport.update` / `@upper_viewport.update` in `Map#update_map_tone` |
| `dynamic_install` (`update`) | 29 | 22 constant-receiver ones are `Graphics.update`, the receiver the probe's `class << Graphics; alias_method :update` really rebinds; `Input.update` (1) is the only constant receiver the install cannot reach, and no install-target table exists; the rest are unproven receivers |
| `singleton_definer` / `opaque_definer` / `unlisted_class` | 12 | unproven receivers, or ADR 0369's separate gates |

Of the 182 `core_or_native` sends, `name` (35) and the other 130 or so have receivers whose class set is not proven, so
the receiver proof, not the gate, is what is missing (ADR 0331 measured the same: 1,783 sends with an unproven
receiver). The census sentence "unrelated mruby gems registering a name refuse the engine's own class" is true only
after the receiver is proven, and then ADR 0323 already lifts it.

## Decision

One slice, the only one whose receiver set is an existing proof and whose argument is local.

**NATIVE_ARM_COVER.** `CodeGen#native_class_free?` (the per-class judgement of a flow-proven set, ADR 0323) counts a
class as native free when an exact-class native arm for it was emitted ahead of this else
(`with_native_arms_emitted`: the zero-argument RGSS wrappers, `update` on Sprite, Viewport and Window). The arm tests
`mrb_obj_class(M, recv) == rgss::native_X_class()`; the exact-class flow says the receiver's class is exactly `X`, so a
receiver of the set takes the arm and never reaches the else. Soundness conditions, all existing: the set is the whole
receiver set (`scoped`), it is exact classes (`exact_instances_singleton_free?`), nil is excluded or unanswerable
(`nil_may_answer?`), the arm was emitted by `native_wrapper_owner_safe?` (one native registration, no Ruby definition
on the class, no mixin that could precede it), and the other gates of `refusal` (`required_classes`, method_missing)
still run. A class with no emitted arm (Tilemap `update`) is judged as before.

Counted refusal reason: unchanged (`:core_or_native`), now reached only by sets with a class that is neither covered
nor resolved in Ruby. Kill switch `BC2CPP_NATIVE_ARM_COVER=0` (byte-identical to master). The dead else is the
`bc2cpp_nomethod` tail, so the site joins `NOMETHOD_REVIEWED` (`RPG2k::Scene::Map#update_map_tone -> update`; the shipped pass lists it as unreviewed without the entry).

## Result

Shipped pass, `/*SO:*/` stripped, same base as the control (`shipped.cxx` byte-identical with the switch off):

| | before | after |
| --- | ---: | ---: |
| `bc2cpp_send(` occurrences | 2082 | 2080 |
| `mrb_funcall` occurrences | 10707 | 10707 |
| `CLOSED_WORLD kept` markers | 225 | 223 |
| native exact arms | unchanged (the diff is the two lines below) | |

The whole diff is two lines, both in `RPG2k::Scene::Map#update_map_tone`: `bc2cpp_send(M, r12, 634, 0)` with
`kept: core_or_native` becomes `bc2cpp_nomethod(M, r12, 638)` (`@map_viewport.update`, `@upper_viewport.update`).

## Not built

* Class-aware `@outside_names` for unproven receivers: unsound without a set; `name` has `RGSS::Font` and `Symbol`
  among its answerers, so an unproven `x.name` may reach either.
* Install-target table for `dynamic_install`: one site (`Input.update`) is unaffected by the `class << Graphics` probe.
  A target table (which constant's singleton each alias lands on, subclass inheritance of singleton lookup) is a new
  analysis for one site.
* Traced (inlined loop body) sends: `closed_world_site` receives `idx` only, so the three `wait` sends on a proven
  `KeyInputRequest` have no flow position; reading `trace_idx` there is the entry-guarded / loop-inline levers' area.
* A per-owner ledger of `Array`/`Hash` natives: each needs a frame-independent entry first (ADR 0323).

## Consequences

Two by-name sends in `Map#update_map_tone` become the proven-dead nomethod tail. The gate itself is unchanged for every
other site. The remaining `core_or_native` population is a receiver-proof problem; the next step is the receiver
sources of ADR 0331, not another look at `@outside_names`.

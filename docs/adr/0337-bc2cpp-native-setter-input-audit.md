# 0337. bc2cpp: audit native setter writes and measure their input blockers

Date: 2026-10-04

## Status

Accepted

## Context

ADRs 0331–0336 leave native contents=/bitmap= input constraints unproved. The
setters accept arbitrary values, and pooling a Bitmap class merely because current
named callers usually pass one would omit dynamic dispatch and outside entries.
The existing bitmap spelling also poisons unrelated Ruby @bitmap fields globally.

## Decision

### Native write contracts

Retain the complete-source pins for lib.cxx, rgss_construct.hxx and
rgss_native_direct.hxx. Audit the registered wrappers and direct helper paths:

| Writer | Receiver family | Stored value |
| --- | --- | --- |
| spr_set_bmp / sprite_bitmap_set_direct | RGSS::Sprite and subclasses | Unchanged setter argument |
| plane_set_bmp / plane_set_bmp_native_body / plane_set_bmp_direct | RGSS::Plane and subclasses | Unchanged setter argument |
| plane_init | RGSS::Plane and subclasses | nil |
| window_set_contents / window_contents_set_direct | RGSS::Window and subclasses | Unchanged setter argument |
| window_init | RGSS::Window and subclasses | Newly constructed Bitmap |

Functional setters store before display binding, retile or refresh; those helpers
can raise after the write. Compiled-out target implementations raise instead.
Neither behavior constrains the stored argument to Bitmap. Sprite's unassigned
bitmap starts as nil. The Graphics invalidation sweep reads @bitmap on registered
display objects, including Window, but does not write it; reads do not add store
values to an ivar pool.

Extend NativeIvarScopes with bitmap's Sprite/Plane writer families. Unrelated Ruby
families may pool their own @bitmap stores; native families, subclasses and shared
mixins remain poisoned. Outside references to setter wrappers/direct helpers,
function pointers and token pasting withdraw the audit. Outside @bitmap spellings,
reflection and attr writers retain the existing refusal checks. The full-source
pins withdraw all scopes on changed files or unmodelled callers.
BC2CPP_NATIVE_BITMAP_IVAR_SCOPE=0 restores bitmap's global poison. The existing
BC2CPP_NATIVE_IVAR_SCOPES switch still withdraws all native scopes.

### Setter input census

BC2CPP_NATIVE_SETTER_REPORT=path writes a versioned JSON sidecar after C++ emission.
It records every named contents=/bitmap= candidate's receiver and argument class
masks, fixed arity, owner/source/irep/index and unresolved-input/receiver blockers.
Symbol/String stems and definition mentions are separate from calls. Computed-name
presence is reported, but this scan is not an enumeration of dynamic/native calls.
Rows explicitly do not prove dispatch reaches a native setter; same-name Ruby
setters participate in this census. Source contracts are marked unaudited when
scoping is withdrawn. The report never enables native-family pooling or claims
caller completeness. See docs/bc2cpp-native-setter-inputs.md for use and the schema.

## Consequences

On the parent 042c3989 Wio world, 62 named contents= sites all supply RGSS::Bitmap;
six receivers remain unresolved. Of 31 named bitmap= sites, 23 supply RGSS::Bitmap,
one supplies Bitmap or nil, and seven inputs remain unknown. The computed-name
flag is set. Six contents= mentions and two bitmap= mentions include definitions
and stem literals, so their counts are not hidden-call counts.

The seven unknown bitmap inputs are Graphics.transition, RPG2k::Window#contents=
and five Scene::Battle paths. All have a proven RGSS::Sprite receiver. Caller
coverage and value production are separate next steps: known inputs at 62 sites
cannot establish native Window's complete caller set, especially when many calls
reach RPG2k's Ruby Window setter.

The shipped Wio census remains at 2,844 cached sends, 190 ivar pools, 136 argument
pools, 923 nil-receiver helpers and 1,026 exact-index arms. Output with bitmap
scoping or the setter report enabled is byte-identical to the parent (SHA-256
509ae942126c305f959688807748ad12a13f04382c50e836276c7ce308f2fa64).
No additional dispatch or speed gain is claimed; the existing 80-site reduction
is unchanged. The report supplies actionable evidence for the remaining input proof.

The ivar scope check exercises independent Ruby and Window bitmap slots, poisoned
Sprite/Plane families and a Sprite subclass, outside helper/pointer references,
reflection, attr writers, shared mixins and withdrawal switches. Full-core, core-only
and 32-bit parity use a C setter stand-in for the audited store/return contract,
passing another class into native receivers; they do not link the LVGL backend.
Eleven mutants plus a control verify the original scopes and new family boundaries.
The setter report check verifies byte-identical C++, known/unknown/nil inputs,
method capture, computed names, withdrawn source audits and open-world reporting.
Native receiver pooling still requires a complete dynamic/native caller proof,
constructor values, all Ruby stores and every accepted setter argument.

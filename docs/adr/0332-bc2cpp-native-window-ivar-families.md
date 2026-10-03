# 0332. bc2cpp: scope audited native RGSS ivars to their class families

Date: 2026-10-03

## Status

Accepted

## Context

ADR 0331 (PR #2003) identified native spelling of `@contents` and `@cursor_rect` as a blocker for unrelated Ruby
scene classes. The numeric and class-pool analyses poison every family with a matching ivar name, even when the
native access belongs exclusively to RGSS::Window. The candidate needed a native call-graph audit, rather than a
fixture that assumes a receiver class. The cutoff was 30 removed by-name sends, measured off against on on one tree.

## Decision

`NativeIvarScopes` audits the Window receiver discipline in `mruby-rgss/src/lib.cxx` and its two public declaration
headers. When that audit holds, `contents` and `cursor_rect` remain poisoned in the entire RGSS::Window family
(superclasses, subclasses and included/prepended modules). Other families may pool those names through the existing
whole-program store analysis. Native setters still accept arbitrary values; this change proves no value class for a
Window slot. The same audit scopes native `@viewport` writes to RGSS::Sprite, Plane, Tilemap and Window;
unrelated Ruby families, including RPG2k::Window, may pool their own viewport stores. It adds no result fact for
`bitmap` or other native setters.

The original flat outside-ivar set remains intact for typed-slot demotion and embedding. Only the numeric/class-pool
structural-poison check uses scoped native names. Ruby literal Symbol/String names, reflection, ownerless accesses,
attr writers, unknown stores and wild class families retain their existing withdrawal rules.

### Audited native call graph

Every candidate access uses the `self` parameter of its containing function:

| Function | Candidate accesses | Where its receiver comes from |
| --- | --- | --- |
| `window_structural_dirty` | reads `@contents` | only `window_refresh(M, self)` calls it |
| `window_refresh` | reads `@contents`, `@cursor_rect` | sixteen callers, listed below, all pass `M, self` |
| `window_init` | writes a fresh Bitmap to `@contents` | Window's registered `initialize` |
| `window_update` | reads `@cursor_rect` | Window's registered `update`, or `window_update_direct(M, self)` |
| `window_contents_set_direct` | writes its unconstrained argument to `@contents` | Window's registered `contents=` wrapper, or an exact-class compiler entry |
| `window_cursor_rect_set_direct` | writes its unconstrained argument to `@cursor_rect` | Window's registered `cursor_rect=` wrapper, or an exact-class compiler entry |

The sixteen refresh callers are `window_set_ox_native_body`, `window_set_oy_native_body`,
`window_set_contents_opacity_native_body`, `window_set_opacity_native_body`, `window_set_back_opacity_native_body`,
`window_set_stretch_native_body`, `window_set_openness_body`, `window_set_tone_body`, `window_update`,
`window_contents_set_direct`, `window_width_set_direct`, `window_height_set_direct`, `window_windowskin_set_direct`
`window_cursor_rect_set_direct`, `window_active_set_direct` and `window_pause_set_direct`. Every call
passes the caller's unchanged `self`. The native-body setters are reached through argument-unpacking wrappers
registered on the `window` variable, created as RGSS::Window, and their frame-independent forwarding entries.
The direct entries are selected by the compiler's existing exact RGSS::Window identity checks. No native caller or
function-pointer use of these entries occurs outside the audited files.

Off Wio, the registrations, wrappers and bodies are compiled together. On Wio the native Window bodies and
registrations are compiled out and the public direct entries are raising stubs. The conservative Window-family
poison applies in both cases; no preprocessor evaluation is needed to gain a proof for an unrelated scene family.

### Viewport writer audit

Every native `@viewport` write uses the unchanged `self` of one of these entries:

| Function | Receiver discipline |
| --- | --- |
| `spr_init` | registered only as RGSS::Sprite's `initialize` |
| `plane_init` | registered only as RGSS::Plane's `initialize` |
| `tilemap_init` | registered only as RGSS::Tilemap's `initialize` |
| `window_init` | registered only as RGSS::Window's `initialize` |
| `sprite_new_direct` | allocates the exact RGSS::Sprite class selected by the existing constructor identity guard |
| `window_set_viewport_native_body` | its Window-registered argument wrapper and `window_set_viewport_direct` both pass their unchanged `self` |

There are no other native writers or aliases of these entries in the pinned files. The values are unconstrained
constructor/setter arguments, so all four families remain poisoned, including subclasses and shared mixins.
Native reads, including `vp_refresh_children`'s walk over display-object roots, do not change the stored class and
need no narrower read-receiver assumption. No typed-slot embedding is enabled by this audit.

Outside references to the four constructor entries (`spr_init`, `plane_init`, `tilemap_init`, `sprite_new_direct`)
withdraw the audit, as does the existing Window-prefix scan. Address taking and bare prefixes followed by `##`
are covered. Other sprite/plane/tilemap helpers do not reach a viewport writer and do not need to be banned.
The full-file digest still withdraws the proof if a new writer or helper edge is added inside the boundary.

### Fail-closed source audit

The audit pins the complete byte digests of `mruby-rgss/src/lib.cxx`, `include/rgss_construct.hxx` and
`include/rgss_native_direct.hxx`. The full-file pins intentionally cover registrations, every helper edge, receiver
reassignment, conditional branches and macro definitions without introducing a partial C++ parser.

The compiler requires all three files in its scanned outside/native inputs. It also scans the union of `NATIVE_SRCS`,
`FOREIGN_RUBY_SRCS` and the actual closed-world build's outside sources, including host sources and public headers.
Any reference to an audited Window function outside the pinned files withdraws the whole audit, including address
taking and a newly introduced helper caller. The entire `window_` prefix is refused, including token-pasted calls;
the unrelated `window_title_` interface is excluded. Any outside ivar spelling restores global poison for that name, including `MRB_IVSYM` forms of
`contents`, `cursor_rect` and `viewport`. Symlink aliases are canonicalized before checking coverage.
An unreadable source raises through SourceText; a missing source logs and withdraws. The compiler logs the scopes or
the refusal reason. `BC2CPP_NATIVE_IVAR_SCOPES=0` restores the previous global poisoning.

### Measurement

Full Wio closed-world coverage, based on master `4bdd9492`, with the scope switch off and on on the same tree:

| Measure | Off | On | Change |
| --- | ---: | ---: | ---: |
| Cached by-name send / with-block sites, whole program | 2,924 | 2,881 | -43 |
| NILABLE_RECEIVER sites | 879 | 918 | +39 |
| Class ivar pools | 185 | 187 | +2 |
| Class argument pools | 115 | 117 | +2 |

All 43 removed cached sends are in engine functions; compiled core methods are unchanged. There are no removed
with-block calls. The affected methods include Scene::Base, ChipsetEditor, DebugMenu, MapViewer and RPG2k::Window.
The Window-only audit removed 41 sites (2,883 remaining); adding the viewport writer scope removes two more
and adds one class ivar pool. Thirty-nine
nil-helper calls are added, so the removed by-name count is not a claim that those potential nil calls disappear.
The helper still raises the interpreter's NoMethodError. A width fallback in Base#draw_wrapped_hint becomes a proven
no-method helper call (+1). Its native Bitmap/Rect arms and Ruby Sprite/Window/Game::Map/RPG2k::Window
arms cover every answering class, so the dead fallback is listed in NOMETHOD_REVIEWED. No other error helper grows. The viewport scope also removes four dead no-method helpers in RPG2k::Window (`dispose`, `open_animation`,
`visible=` and `z=`); their reviewed entries are removed. The total no-method helper change is therefore -3.
With the switch off, `shipped.cxx` is byte-identical to master.

## Consequences

The 43-site measurement clears the cutoff, so the audited scope proof ships enabled. It exposes the scene family's
Bitmap stores to existing class pools without weakening Window's arbitrary native-write behavior. The `bitmap`
accessors and RPG2k::Window's stores that still depend on native setter arguments remain follow-ups.

The byte pins trade maintenance convenience for a complete audit boundary: even a comment edit to a pinned file
withdraws the proof. Refresh a digest only after reviewing the native receiver contract and rerunning the audit,
withdrawal, mutation and runtime checks. A new outside helper caller must be audited before expanding the boundary.

`scripts/bc2cpp_native_ivar_scopes_check.rb` checks pinned inputs, external helper calls and function pointers,
outside native/Ruby spellings, Window/Sprite/Plane/Tilemap isolation and subclass native-write parity, shared mixins, reflection, the open world and the kill
switch. Its runtime fixture compares interpreted and compiled results, including nil and native writes of another
class into a Window subclass. `scripts/bc2cpp_native_ivar_scopes_mutation_check.rb` kills eight soundness mutants
plus an unmodified control. CI runs the checks in `call-facts` and runtime parity on 32-bit mrb_int in `bc2cpp-width`.
The width job sets `NIS_FULL_ONLY=1`: its supplied full library is 32-bit, while automatic core-library discovery
can find the separate 64-bit host mrbc build. Core-only parity runs in `call-facts` with an explicit matching library.

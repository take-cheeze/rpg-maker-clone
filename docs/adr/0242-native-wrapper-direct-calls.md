# 0242. Resolve proven native wrapper calls through frame independent bodies

Date: 2026-09-28

## Status

Accepted

## Context

Native mrbgem methods commonly enter through C wrappers that parse the active
mruby call frame with `mrb_get_args`. Calling such a wrapper directly from
compiled bytecode would inspect the caller's frame. A proven exact receiver
class identifies the implementation, but does not make that wrapper's frame
parsing safe. Static receiver traces can also lose the class across returned
values and indexed collections.

## Decision

For RGSS native methods, provide frame independent entry points that accept the
already evaluated receiver and arguments. A direct call is allowed only for a
listed owner with a native registration, no same-class Ruby definition, and
no prepended module. Generated code checks the captured native class pointer
and falls back to ordinary dispatch for other receivers. Keep argument
conversion, optional defaults, and validation in the shared native body so
wrapper and compiled calls have the same behavior.

Use the same owner gate for `Bitmap#width`, `Bitmap#height`, `#disposed?`,
`#visible`, `Bitmap#clear`, `Bitmap#rect`, `Viewport#rect`, and native
`#update` methods. Rect coordinates and dimensions plus Color/Tone components
are read through exact-class guarded helper bodies. The dispose entry points
share the `obj_dispose` body except Tilemap, whose direct entry must retain its
companion-canvas and priority-strip cleanup.

## Consequences

`Sprite#bitmap=`, Sprite `#opacity=`/`#tone=`, Window `#openness=`/`#tone=`,
Viewport `#tone=`, and Bitmap `#fill_rect`, `#blt`, `#stretch_blt`,
`#draw_text`, `#copy_blt`, and `#text_size` use frame independent bodies.
`Bitmap#width`/`#height`, `#disposed?` on Bitmap, Sprite, Viewport, Plane,
Tilemap, and Window, `#visible` on Sprite, Viewport, and Plane, and `dispose`
on those six classes also use frame independent bodies. Their exact runtime
class guards resolve calls when static receiver tracing has no class fact.
Bitmap `#clear`/`#rect` and Viewport `#rect` share the same guarded path.
Rect's `#x`, `#y`, `#width`, and `#height` and Color/Tone component getters
also use guarded direct wrappers; `Bitmap#width` and `Rect#width` select their
own helper under separate class checks.
Per-frame `#update` calls on Sprite, Viewport, and Window use the original
frame-independent native bodies; Tilemap remains on normal dispatch because
its build-specific registration is not uniformly available. Other native
wrappers remain on normal dispatch until they have an equivalent body and a
guarded owner.

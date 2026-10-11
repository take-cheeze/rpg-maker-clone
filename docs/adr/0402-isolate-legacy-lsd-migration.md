# 0402. Isolate legacy LSD extension migration

Date: 2026-10-11

## Status

Accepted

## Context

ADR 0401 migrated all active chunk-200 save fields to native LSD slots. The
remaining decoder still lived on `Game::State`, and comments in runtime state
and slot loading described chunk 200 as the current serialization mechanism.
This obscured which code was native serialization and which existed only to
load saves written by older engine versions.

## Decision

Move the version-1 marker, tagged-record decoder and restoration logic to
`Game::LegacyLsd` in `game/legacy_lsd.rb`. Native LSD loading invokes its
`marked?` check only to distinguish the old foreground wrapper, and its `apply`
adapter after loading native fields. The adapter remains read-only: every new
save uses native fields and omits chunk 200.

Move the picture restoration helper alongside the adapter and name it
`restore_legacy_lsd`, preserving erased state during migration. Remove the unused
integer opacity conversion formerly used by the extension-era writer. Correct
runtime and host-check comments to describe native pan and picture fields.

Register the new singleton owner for bc2cpp and its Wio stub stripping. Move
the reviewed dispatch keys with the unchanged migration method: its state
receiver still comes from native `State.from_lsd`. Load
the adapter before native serialization in host harnesses. Production mrblib
loads these files in sorted order, with `game.rb` defining the runtime classes
first.

## Consequences

Normal runtime state no longer owns private extension tags or codecs. Existing
version-1 saves still restore all previously supported extension records and
migrate on their next save. Unsupported versions still raise visible errors;
unmarked chunk-200 bytes remain ignored by state reconstruction.

This changes code ownership rather than native save bytes. The authoritative
save checks retain legacy migration, unsupported-version, unrelated-chunk and
old-foreground-wrapper coverage. Native compatibility evidence from ADR 0401
continues to apply.

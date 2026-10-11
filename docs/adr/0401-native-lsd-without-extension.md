# 0401. Write native LSD fields without the extension chunk

Date: 2026-10-11

## Status

Accepted; supersedes ADR 0395's chunk-200 writer decision.

## Context

ADR 0400 identifies genuine RPG_RT fields corresponding to the state previously
stored in our private chunk 200. Native foreground execution also stores its
execution state directly in chunk 113, whereas our old schema added a wrapper.

## Decision

New `Game::State#to_lsd` saves omit chunk 200. Weather uses screen 48/49;
boarding uses hero 102/103; encounter accumulation uses hero 124. Camera state
uses hero 111–115/121: coordinates are relative to 2304/1792, with right/down
motion subtracting sixteenths of pixels. Foreground execution writes chunk 113
directly. Common-event cursors use chunk 114's execution stacks; a cursor-only
state requires its database command list, and saving fails visibly without it.

Flash continuation uses native current intensity and remaining frames. Picture
current transparency uses native doubles, including fractional opacity; target
transparency uses the native integer percentage. The renderer's rounded opacity
getter is unsuitable for saving the current value.

The legacy version-1 marker and all existing extension records remain readable.
Legacy extension values override the native approximation when loading an old
save, including the old foreground wrapper. Its next save uses native fields
only. Unsupported marked versions fail explicitly. Unmarked chunk 200 is not
interpreted as our extension; the raw LCF reader/writer still preserves unknown
chunks independently of state reconstruction.

## Consequences

Native saves carry no private extension metadata. Integer picture targets round
to the nearest percentage, and camera coordinates round to a sixteenth of a
pixel. Flash loading reconstructs its fade from the current intensity and time,
preserving the remaining trajectory rather than the original peak/total-time
metadata. Erased pictures retain native data without a private remembered name.

The authoritative host checks compare representable live state, exercise field
removal and legacy migration, and cover missing database/error cases. The four
RPG_RT captures from ADR 0400 now pass the complete `lcf_save_check.rb` schema
walk, including their foreground execution stacks. RPG2003 runtime behavior
and preservation of every native event wait flag remain outside this change.

## Native runtime verification

Using the RPG2000 executable identified in ADR 0400, the native screen capture
was reconstructed through `Game::State.from_lsd` / `to_lsd`, then loaded and
saved to slot 2 in an isolated Wine game copy. RPG_RT resumed the foreground
Save Menu instruction and wrote a new file with save count 3 (input count 2).
Both input and native re-save omitted chunk 200. Weather 1/strength 2,
pan state 0/current X 2304/target X 1280/speed 4, flash level 25.0/time 600,
and foreground cursor 5 survived unchanged. The native re-save also passed
`lcf_save_check.rb`. No game assets or executable are committed.

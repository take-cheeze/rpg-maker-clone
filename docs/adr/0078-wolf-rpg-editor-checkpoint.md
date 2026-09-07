# 78. WOLF RPG Editor Checkpoint(99)

Date: 2026-09-07

## Status

Accepted

## Context

`Checkpoint`(99), WolfTL's own name, is the second most common
unimplemented command left after `Effect`(290) in a real-data census of
the sample game (49 occurrences). help/04eventwindowB.html documents it
as a pure editor-side bookmark: "チェックＰ追加"/"次チェックＰへジャンプ"
("add checkpoint" / "jump to next checkpoint") are buttons in the event
editor's own script view, letting a developer mark and later jump back to
an important or in-progress line of a large event -- a navigation aid,
never mentioned anywhere as having a runtime effect. The wolfrpg-map-
parser crate models it as a unit variant carrying no fields at all
(`Checkpoint()`), matching this. Real data carries one argument (0 in 40
calls, 1 in 9) -- the manual's own documented "特モード" checkbox, a
*second*, separate bookmark category the editor's own search can filter
on ("普段使ってるのとは別のチェックポイントを設置・検索することができま
す") -- itself still purely an editor-side distinction with no runtime
meaning.

## Decision

`Wolf::Interpreter::Run#dispatch` treats `C_CHECKPOINT`(99) as a no-op,
alongside `C_BLANK`(0) (ADR 0076) -- regardless of its own argument's
value, since neither documented value changes anything once the event is
actually running.

## Consequences

- The sample game's own large Common Events (several of which use
  `Checkpoint` liberally while under active development, per its own
  documented purpose) no longer log it as unimplemented; verified against
  the soak check, `ctest -R mruby_test` (crash count held at the
  pre-existing 19-crash baseline), and the compiled binary against the
  real sample game.

# 70. WOLF RPG Editor Choices(102): a real, blocking input primitive

Date: 2026-09-07

## Status

Accepted

## Context

`Choices`(102) -- "up to 10 choices, wait for the player" per help/04ev_select
.html -- was an explicit no-op (`Wolf::Interpreter::Run#dispatch`'s own
catch-all bucket): the command was skipped every time, its own dispatch
falling through to the first `ChoiceCase`(401) marker that follows it, which
*is* implemented (skip straight to `BranchEnd`) -- so no branch's body ever
ran, and (found while validating this change) that silent skip-through is
what made a real per-frame "show this shop menu again" retry loop in the
sample game's own data spin through hundreds of thousands of commands in a
single `Fiber.resume` with no `Wait`/yield to stop at, tripping
`scripts/wolf_interpreter_check.rb`'s own dispatched-command safety net (the
soak check's own pre-existing "note" about a suspected infinite loop in the
shop event).

Two things had to be established before implementing this for real:

- **The byte layout of `Choices`(102) itself.** The wolfrpg-map-parser
  crate's own `ShowChoiceCommand` parses an entirely different *tree*
  shape (choices and their case bodies nested inside one command object)
  than this reader's own flat, marker-based framing (`VariableCondition`
  (111)'s own proven shape: a command, then some number of
  `ChoiceCase`/`SpecialChoiceCase` markers, an optional `ElseCase`/
  `CancelCase`, closed by `BranchEnd`) -- so the crate's own overall
  structure could not be trusted directly. Its `Options` struct (bits 0-3
  choice count, bits 4-7 "cancel behaviour", bits 8-10 a left/right-key or
  forced-interrupt bitmask) could, since both parsers read the exact same
  underlying header bytes even though they diverge on what follows --
  confirmed empirically by dumping every real `Choices` command in the
  sample game (all 15 of them, every one in a map event page, none in a
  Common Event) and hand-walking what actually follows each one: a
  two-choice `Choices` carries exactly two `ChoiceCase` markers in source
  order, and only when its own cancel behaviour is the crate's own
  "Separate" (0) does a trailing `CancelCase` follow -- exactly the shape
  `VariableCondition`'s own branch structure already uses.
- **What a `ChoiceCase`/`SpecialChoiceCase` marker's own numeric argument
  means.** Real dumps rule out "the 0-based choice index": two different
  two-choice `Choices` commands both carry marker arguments `[2]`/`[3]`,
  not `[0]`/`[1]`. `Wolf::Interpreter::Run#exec_variable_condition` already
  ignored this argument (matching cases purely by *encounter order*,
  the same way `#skip_to`'s own callers always have) before this change
  existed, for the same reason -- so `Choices` reuses that exact
  convention rather than trying to decode a value that evidently is not
  the index at all.

`extra_cases` (the crate's own left/right-key and forced-interrupt bitmask)
has no real example anywhere in the sample game's own data -- every one of
its 15 real `Choices` commands carries `extra=0` -- so there is nothing to
cross-check that part of the crate's own struct against; left unimplemented,
logged and the whole construct skipped, rather than guessed.

## Decision

- `Wolf::Interpreter::Run#exec_variable_condition`'s own branch-walking loop
  is pulled out into a shared `#select_branch(indent) { |idx| ... }`:
  walks `ChoiceCase`/`SpecialChoiceCase` markers by encounter order, calling
  the block with each one's index, stopping (and letting that marker's own
  body fall through) the first time it returns true, an `ElseCase`/
  `CancelCase` is reached, or falling through the whole construct on
  `BranchEnd`/malformed input. `VariableCondition`'s own behaviour is
  unchanged (same tests still pass); `Choices` reuses the exact same method.
- `#exec_choices` decodes the choice count/cancel behaviour/extra-cases
  bitmask, skips the whole construct (`skip_to` its own `BranchEnd`) when
  `extra != 0` or every choice string is blank ("文字列が全て空だった場合
  は、選択肢コマンド自体がスキップされる", the manual's own words), then
  loops `Fiber.yield`ing once per frame -- the same blocking shape
  `#exec_wait` already uses -- polling a new `WolfRPG::MapScene#choice_input`
  (up/down move the cursor among the *visible*, non-blank choice slots;
  confirm resolves to the chosen slot's own original index; cancel resolves
  per the decoded cancel behaviour: a dedicated `CancelCase` branch, ignored
  entirely, or "act as if choice N was picked", cross-confirmed against the
  crate's own `CancelCase` enum) until it has an answer, then calls
  `#select_branch`.
- No native choice window is drawn -- this is the same "wait for real input,
  dispatch by index" primitive scope `Message`(101) already keeps
  (interpreter.rb's own existing "stderr line, no real window" simplification
  for messages); `#exec_choices` logs the visible choice texts to stderr the
  same way. `Interpreter` still has no rendering or input code of its own:
  `#choice_input` is one more `current_scene`-mediated seam, alongside
  Picture(150)'s own rendering hooks and event movement's own passability/
  hero-position queries.
- A blank choice slot is not offered to the player (skipped when navigating,
  never landed on by confirm) but still owns a real marker structurally, so
  `#select_branch`'s own encounter-order walk must still count it -- the
  chosen index handed to it is always the *original* slot position, not a
  position within the compacted visible list.

## Consequences

- The sample game's own title screen choice ("スタート"/"コンティニュー"/
  "ゲーム終了", cancel disabled) is now reachable and correctly blocks
  waiting for real player input against the real compiled binary -- booted
  headlessly and confirmed it stops there rather than crashing or racing
  past it.
- Fixed a real, previously-undiagnosed soak-check symptom as a side effect:
  the shop event's own "suspected infinite loop" note is gone, because the
  silent skip-through that caused it (a retry loop with nothing to ever
  yield on) no longer happens -- `Choices` now genuinely blocks like `Wait`
  does.
- Still unimplemented: the left/right-key and forced-interrupt extra-case
  bitmask (no real example to build or check one against), and the separate
  "■選択肢の強制中断" event command that can interrupt a `Choices` in
  progress from a different parallel event (an entirely different command
  code, not modeled at all).

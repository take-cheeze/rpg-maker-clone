# 0245. bc2cpp guards game-variable integer range specializations

Date: 2026-09-28

## Status

Accepted

## Context

`Game::Variables#[]=` clamps ordinary writes to the RPG2000/RPG2003 range, but
`replace` bypasses that clamp, `to_h` exposes the backing hash, and assignment
can store a Float. A static Fixnum fact for every indexed variable read would
therefore be unsound. At the same time, arithmetic on ordinary in-range game
variables is a useful source of Fixnum results, including on 32-bit targets.

## Decision

bc2cpp may infer a conservative interval for literals, indexed reads, and
integer arithmetic. It uses that interval only in a guarded arithmetic arm:
each actual operand must be a Fixnum and fit its inferred interval. Addition,
subtraction and division also require their result interval to fit Fixnum;
multiplication checks the actual product against `MRB_FIXNUM_MIN/MAX` before
boxing it. Division excludes zero from the fast arm. Every failed guard keeps
the existing arithmetic and Ruby dispatch fallback.

The accepted game-variable input interval is the union of both editions,
`-9,999,999..9,999,999`. The proof does not assume the indexed receiver or
stored value is well-formed: the runtime operand checks enforce the interval.
Control-flow joins that do not have a dominating definition and expressions
whose result interval cannot fit Fixnum remain unoptimized.

## Consequences

Chained integer arithmetic can reuse guarded interval facts and emit Fixnum
operations when the checked values fit. Reads involving Float, out-of-range
integers, or values introduced through bulk replacement keep the ordinary
fallback. The extra range checks cost instructions on these specialized paths;
performance should be measured before expanding the proof to other operations.

`scripts/bc2cpp_game_variable_range_check.rb` pins the emitted guards and
fallbacks.

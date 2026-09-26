bc2cpp: `trace_new_target` grows CONTAINER_PHI_MERGE, a sound merge of a
register's class across a `JMPNOT`/`JMPIF` that has a container literal on its
fall-through arm (`x || []`, `x && {}`).

The merge is admitted only when the other arm is provably the same container
class or provably nil, because the block inliners gate on `traced == 'Array'`
and then index the register with `RARRAY_LEN`/`RARRAY_PTR` with no runtime
check -- a wrong fact there would miscompile rather than fall back to
`mrb_funcall`.

No measurable effect on the real program today (0 lines of generated C++ differ
on the hot-only RPG2k build), because the sound subset is one `LOADNIL` site:
the taken side of ~200 `||`/`&&` sites is `GETIDX` (88), `MOVE` (42),
`SEND0`/`SEND`/`SSEND` (54), `GETIV` (15) or a comparison (6), none of which
proves a class without a further annotation. Kept as the sound encoding those
annotations will land in.

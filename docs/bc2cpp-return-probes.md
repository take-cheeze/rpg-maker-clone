# bc2cpp return-hint probes

The Fixnum-return hint probe runs before the final ivar-layout pass. Without
`FOREIGN_RUBY_SRCS`, its missing foreign-method scan forces an empty proof set.
In that case the probe skips embedding checks and the method compiles they
would trigger. A completed scan that returns an empty set still runs the normal
checks; missing evidence and evidence of no foreign methods are distinct inputs.

The final generator retains all embedding and compilation checks. This saves
work in fixtures and exploratory invocations that omit the outside-method scan;
builds providing that scan follow the existing path.

On x86_64 Linux with CRuby 3.4.9/YJIT, alternating full-source rpg2k generation
fell from 12.33/12.50 seconds to 10.74/10.67 seconds, with byte-identical C++.
The benchmark used `closed_world_mrblib_srcs(root)`, `SKIP_UNSUPPORTED=1` and
rpg2k owners, without outside-source overrides. The probe itself fell from
3.14 seconds to 0.08 seconds in the last run; some work moves to the final
compile, so the overall gain is about 14%, not the entire probe-time saving.

`scripts/bc2cpp/return_probe_check.rb` checks both absent and completed-empty
scans. The nightly fast shard runs it with the other return-proof checks.

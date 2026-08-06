- **ADR 0022 now records what "one canvas strip per row" has to mean.** The
  phrase did not say how tall a strip is, and both obvious readings fail: a
  full-screen canvas per `ty + prio` bucket is 24.6 MiB for one map (21× today's
  flat above-layer), while a one-tile-row strip cannot hold a bucket at all,
  since bucket `B` spans rows `B-5 .. B-1`. That same arithmetic bounds a
  workable strip at five rows. The cheap alternative — bucketing by row and
  taking the highest priority in it — is ruled out by the test bed: 4 of its 9
  priority-bearing rows carry more than one distinct priority, one of them three.

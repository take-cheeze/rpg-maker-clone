- **CI** cancels the run for a pull request's previous commit when a new one is
  pushed, and splits the 40 minute `bc2cpp-width (int32)` job into
  `int32-a` and `int32-b` so it is no longer the longest job.
- **CI** skips the bc2cpp mutation checks on pull requests; master, the merge
  queue and manual runs still run them.

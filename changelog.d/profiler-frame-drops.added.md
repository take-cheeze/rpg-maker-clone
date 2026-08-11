- **The built-in profiler now counts dropped frames.** `Graphics.update`'s
  fps-cap pacing already detects when it falls more than one frame behind and
  rebases its deadline instead of bursting through catch-up frames (issue
  [#451](https://github.com/take-cheeze/rpg-maker-clone/issues/451)); each
  rebase is now reported to `RGSS::Profiler` as a dropped frame. The `--profile`
  stderr summary line gains a `drops=N` field next to `fps`/`frame(work)`,
  `RGSS::Profiler.stats` exposes it as `:frame_drops`, and a Chrome trace
  (`--profile_trace`) marks each drop as an instant event on the main-loop
  track.

- **`wio-renode` CI job's "Build Renode with the Wio Terminal peripherals"
  step no longer fails with `remote error: upload-pack: not our ref`.**
  `scripts/wio_renode_build.bash` cloned Renode with
  `--recurse-submodules --shallow-submodules` *before* checking out the
  pinned `RENODE_REF` commit, which shallow-pins every submodule to
  whatever commit Renode's current default branch tip references. Checking
  out the (older) pinned commit afterward needs different submodule
  commits, and deepening an already-shallow submodule clone to an
  unrelated historical commit isn't supported by some of Renode's
  submodule hosts (`src/Emulator/Cores/tlib`, its nested `softfloat-3`,
  and `src/Infrastructure` all failed this way). Fixed by cloning without
  submodules, checking out `RENODE_REF` first, and only then running
  `git submodule update --init --recursive`, so each submodule's first
  clone goes straight to the commit that's actually needed.

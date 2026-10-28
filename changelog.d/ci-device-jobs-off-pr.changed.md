- **CI no longer builds the android, maix and psp targets on pull requests.**
  They run in the merge queue, on pushes to `master` and on a manual dispatch,
  so a pull request's checks finish sooner; `docs/ci.md` ("Device jobs") has
  the details. `nano7-qemu` keeps its path filter.

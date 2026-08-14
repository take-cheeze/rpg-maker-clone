- Dropped the unused `3rd/cmdline` submodule (tanakh/cmdline). Nothing in the
  source tree or build files ever included it — `src/main.cxx`'s command-line
  parsing has always gone through `gflags` (`3rd/gflags`) instead.

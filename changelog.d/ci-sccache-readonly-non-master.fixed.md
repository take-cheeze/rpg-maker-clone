- **CI**: sccache's GHA cache backend stores one blob per compilation unit,
  so every pull request and manual run writing to it multiplied cache
  entries fast. `SCCACHE_GHA_RW_MODE` now only allows writes on a push to
  `master`; every other trigger still reads master's cache but can no
  longer add new blobs of its own.

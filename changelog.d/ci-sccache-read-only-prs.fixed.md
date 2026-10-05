- **CI** makes pull-request runs really read-only for sccache: the dev shell's
  sccache 0.15.0 ignored `SCCACHE_GHA_RW_MODE`, so every PR wrote hundreds of
  cache blobs into the shared 10 GB Actions cache. Jobs now compile through the
  `sccache-action` binary.

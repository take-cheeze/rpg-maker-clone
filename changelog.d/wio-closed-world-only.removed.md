- **Wio Terminal:** the interpreted Wio build and the demo firmwares are gone.
  `MRUBY_TARGET=wio` now requires `RPGMAKER_BC2CPP=1` (the closed-world libmruby),
  and `env:wio` boots that libmruby. Removed the `wio_walk`, `wio_sim`,
  `wio_rgss_boot_heapdbg`, `wio_rgss_boot_heapdbg_ram` and `wio_mruby_sd_smoke`
  environments, the bring-up demo (`app/wio/src/main.cxx`), the Renode platform
  (`app/wio/renode`, `scripts/wio/renode_*`) and its CI job. `wio_sd_upload` is kept.

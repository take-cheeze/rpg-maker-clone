- **Wio Terminal:** the interpreted Wio build and the demo firmwares are gone.
  `MRUBY_TARGET=wio` now requires `RPGMAKER_BC2CPP=1` (the closed-world libmruby),
  and `env:wio` boots that libmruby. Removed the `wio_walk` and `wio_mruby_sd_smoke`
  environments, the heap-debug boot variants, the bring-up demo
  (`app/wio/src/main.cxx`) and `wio_hal.cxx`. `wio_sim` (Renode), `wio_sd_upload`
  and the Renode files are kept.

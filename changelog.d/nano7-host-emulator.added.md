- A **host-side emulator for the iPod nano 7G walk app** (`app/nano7/host`,
  see ADR 102): a native `nano7_walk_host` executable that links
  `app/nano7/rpg2k_walk/rpg2k_walk.c` unmodified against a host
  implementation of the small `hb_raw_surface`/`hb_sdk` API it calls, built
  on this repo's existing SDL2 dependency. Unlike the Wio Terminal's Renode
  platform (ADR 94), this does not emulate the nano 7G's Cortex-A8 SoC or its
  proprietary OS — the app never touches either directly, only that
  six-function API — so it needs no new toolchain and no from-source build of
  a separate project. Run it interactively (a real window, mouse as touch) or
  headless (`--frames N --screenshot out.bmp`, no display needed at all); the
  new `nano7_host_smoke` ctest exports a real Nepheshel map through it on
  every build and checks the rendered frame actually shows map content.

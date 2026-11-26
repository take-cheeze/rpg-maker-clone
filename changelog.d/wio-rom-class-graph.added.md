- **Wio Terminal**: the classes the boot makes can be linked into the firmware as const data (a ROM class graph,
  `WIO_ROM_GRAPH=GRAPH.c scripts/wio/build.bash`, made by `scripts/wio/rom_graph.bash` under Renode): class objects,
  singleton classes and their constant tables move from the heap to internal flash.

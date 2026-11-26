// The classes and modules whose constants or class-level instance variables the
// game changes after the boot (BC2CPP_HOST_CLASS_MUTATIONS over the host
// sweep). mrb_rom_graph_dump leaves their values out of the ROM class graph but
// for their classes and names, and the boot stores them, so a value made at
// boot is not the dump's. A store into any ROM class copies its table to the
// heap, so a class missing here still works; it only costs that copy at boot.
#pragma once

#define ROM_GRAPH_RAM_CLASSES                                                  \
  "Object", "RGSS", "RGSS::Graphics", "RGSS::Bitmap", "LCF", "LCF::EventList", \
      "Game::CommonEvent", "Game::ChipsetLayout"

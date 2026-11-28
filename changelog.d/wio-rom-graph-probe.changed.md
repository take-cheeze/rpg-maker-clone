- **Wio Terminal**: the ROM class graph is made by booting the build's own libmruby under qemu-arm
  (`WIO_ROM_GRAPH=probe scripts/wio/build.bash`) instead of a Renode run of a firmware linked without one, so a build
  links the firmware once. `scripts/wio/rom_graph.bash oracle` holds that graph to a Renode boot.

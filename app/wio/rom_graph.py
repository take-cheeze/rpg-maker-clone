# ROM_GRAPH (scripts/wio/rom_graph.bash): links the ROM class graph WIO_MRUBY_BUILD_DIR/lib/rom_graph.o when there is
# one, so the boot's classes are const data in flash; without it every class is on the heap.
import os

Import("env")  # noqa: F821

build = os.environ.get("WIO_MRUBY_BUILD_DIR")
graph = os.path.join(build, "lib", "rom_graph.o") if build else None
if graph and os.path.isfile(graph):
    env.Append(LINKFLAGS=[graph])  # noqa: F821
    # A flag is not a dependency: a new graph relinks only through this.
    env.Depends("$BUILD_DIR/${PROGNAME}.elf", graph)  # noqa: F821

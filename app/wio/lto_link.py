# libmruby.a carries GCC LTO bytecode (build_config.rb's wio stanza), so the firmware link runs the LTO step over it.
# LINKFLAGS only: the Arduino core stays ordinary objects, which keeps its exception_table, referenced by the linker
# script's KEEP alone (scripts/wio/vector_table_check.rb). One partition: a few KB smaller, about 1.4 GB at link.
# WIO_LTO=0 turns both halves off.
import os

Import("env")  # noqa: F821

if os.environ.get("WIO_LTO") != "0":
    env.Append(LINKFLAGS=["-flto", "-flto-partition=one", "-ffunction-sections", "-fdata-sections"])  # noqa: F821

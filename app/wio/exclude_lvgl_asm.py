# PlatformIO pre-build script: drop LVGL's hand-written SIMD assembly.
#
# LVGL ships Helium/NEON blend kernels as .S files. PlatformIO's Library
# Dependency Finder compiles every source in a library, including these, but the
# Wio Terminal's Cortex-M4 has neither Helium nor NEON, and the .S files pull
# newlib headers whose typedefs the assembler rejects ("bad instruction
# `typedef ...'"). LV_USE_DRAW_SW_ASM is NONE (see app/wio/lv_conf.h), so the
# assembly is unused -- remove the files so they are never assembled.
import glob
import os

Import("env")  # noqa: F821  (injected by PlatformIO/SCons)

for path in glob.glob("3rd/lvgl/src/**/*.S", recursive=True):
    try:
        os.remove(path)
        print("exclude_lvgl_asm: removed %s" % path)
    except OSError as e:
        print("exclude_lvgl_asm: could not remove %s (%s)" % (path, e))

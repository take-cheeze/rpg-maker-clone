# PlatformIO pre-build script: drop LVGL's hand-written SIMD assembly.
#
# LVGL ships Helium/NEON blend kernels as .S files. PlatformIO's Library
# Dependency Finder compiles every source in a library, including these, but
# none of this repo's embedded targets (Cortex-M4, Xtensa LX6, RISC-V K210)
# have Helium or NEON, and the .S files pull newlib headers whose typedefs
# the assembler rejects ("bad instruction `typedef ...'" / "unknown opcode or
# format name 'typedef'"). LV_USE_DRAW_SW_ASM is NONE in every board's
# lv_conf.h, so the assembly is unused -- remove the files so they are never
# assembled.
#
# Reused by more than one PlatformIO project (the repo root's platformio.ini
# for Wio/Maix, and app/m5stack's own standalone one), each with a different
# PROJECT_DIR -- a CWD-relative glob for "3rd/lvgl/..." silently matched
# nothing for app/m5stack (no error, just 0 files found, so the espidf/CMake
# build hit the exact same assembler failure this script exists to prevent).
# SCons execs this script with no __file__ in scope, so the fix is to walk
# up from PROJECT_DIR looking for the repo root (identified by 3rd/lvgl/src
# actually existing under it) instead of assuming either a fixed relative
# depth or that CWD is already the repo root.
import glob
import os

Import("env")  # noqa: F821  (injected by PlatformIO/SCons)

repo_root = env.subst("$PROJECT_DIR")  # noqa: F821
for _ in range(5):
    if os.path.isdir(os.path.join(repo_root, "3rd", "lvgl", "src")):
        break
    repo_root = os.path.dirname(repo_root)
else:
    raise RuntimeError(
        "exclude_lvgl_asm: could not find 3rd/lvgl/src above %s"
        % env.subst("$PROJECT_DIR")  # noqa: F821
    )

lvgl_glob = os.path.join(repo_root, "3rd", "lvgl", "src", "**", "*.S")

for path in glob.glob(lvgl_glob, recursive=True):
    try:
        os.remove(path)
        print("exclude_lvgl_asm: removed %s" % path)
    except OSError as e:
        print("exclude_lvgl_asm: could not remove %s (%s)" % (path, e))

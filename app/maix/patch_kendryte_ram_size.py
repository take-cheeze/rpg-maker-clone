# PlatformIO pre-script: extends the K210 linker script's usable RAM from
# 6MB to 8MB by folding in the KPU's "AI RAM" region.
#
# kendryte.ld's own MEMORY block only ever described the 6MB "general
# purpose" SRAM at 0x80000000 as `ram` (`_heap_end = _ram_end` later in the
# same script, so this is exactly what bounds newlib's sbrk-based heap --
# see syscalls.c's sys_brk). The K210 datasheet's own memory map (also
# baked into this same SDK: lib/bsp/include/platform.h's AI_RAM_BASE_ADDR
# = 0x80600000, AI_RAM_SIZE = 2MB) places a second 2MB SRAM bank -- meant
# for the KPU neural-net accelerator's weights/features -- immediately
# after that 6MB region, physically contiguous in the same address space.
# None of this port's firmwares touch the KPU, so that 2MB just sits idle
# under the stock 6MB linker script.
#
# Confirmed on real Maix Amigo hardware to be genuinely usable as ordinary
# heap: extending `ram` to 8MB here measurably grew get_free_heap_size()
# by exactly 2MB at runtime, with no crash and no change in behavior
# elsewhere -- found while chasing a real-game (large RPG_RT.ldb) SD-boot
# memory-pressure investigation on maix_game_sd. It did not fix that
# investigation's actual hang (a separate, since-confirmed-unrelated-to-
# memory issue -- see app/maix/README.md), but the extra headroom is real
# and free, so it stays regardless.

from os.path import isfile, join

Import("env")

MARKER = "LENGTH = (8 * 1024 * 1024)"
OLD = "ram (wxa!ri) : ORIGIN = 0x80000000, LENGTH = (6 * 1024 * 1024)"
NEW = "ram (wxa!ri) : ORIGIN = 0x80000000, LENGTH = (8 * 1024 * 1024)"


def patch_ld():
    framework_dir = env.PioPlatform().get_package_dir("framework-maixduino")
    if not framework_dir:
        return
    ld_path = join(framework_dir, "cores", "arduino",
                    "kendryte-standalone-sdk", "lds", "kendryte.ld")
    if not isfile(ld_path):
        return

    with open(ld_path, "r") as f:
        content = f.read()

    if MARKER in content:
        return  # already patched

    assert OLD in content, "kendryte.ld's `ram` region line not found -- framework version changed?"

    content = content.replace(OLD, NEW, 1)

    with open(ld_path, "w") as f:
        f.write(content)


patch_ld()

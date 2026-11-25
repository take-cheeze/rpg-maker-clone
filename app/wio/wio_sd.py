# WIO_SD: game data from the microSD card (app/wio/src/wio_sd.cxx). Builds the part of Seeed_Arduino_FS that reads a
# card -- FatFs and the SPI card driver, not its Arduino File/FS classes -- from a copy whose ffconf.h is read-only,
# UTF-16 (the card's long names are, and the engine's paths are UTF-8), FAT12/16/32 only and one 512-byte sector
# window shared by every open file. WIO_SD=0 at build time leaves all of it out.
#
# The env lists Seeed_Arduino_FS in lib_deps, so PlatformIO installs it, and in lib_ignore, so the unpatched copy is
# not built.
import os
import re

Import("env")  # noqa: F821

ENABLED = os.environ.get("WIO_SD") != "0"
LIB = "Seeed Arduino FS"
SOURCES = ["fatfs/ff.c", "fatfs/ccsbcs.c", "fatfs/diskio.c", "SD/Seeed_sdcard_hal.cpp", "SD/sd_diskio_crc.c"]
FFCONF = {
    "_FS_READONLY": "1",
    "_FS_MINIMIZE": "2",  # keeps f_lseek; no f_stat/f_opendir
    "_USE_STRFUNC": "0",
    "_USE_FIND": "0",
    "_USE_MKFS": "0",
    "_USE_FASTSEEK": "0",
    "_USE_EXPAND": "0",
    "_USE_CHMOD": "0",
    "_USE_FORWARD": "0",
    "_USE_LFN": "2",  # the name buffer on the stack, only during a lookup
    "_LFN_UNICODE": "1",
    "_FS_RPATH": "0",
    "_VOLUMES": "1",
    "_MAX_SS": "512",
    "_FS_TINY": "1",
    "_FS_EXFAT": "0",
}


def _write_if_changed(path, text):
    if os.path.isfile(path) and open(path, encoding="latin-1").read() == text:
        return
    with open(path, "w", encoding="latin-1") as f:
        f.write(text)


def _patched_copy(src, dst):
    for rel in ["fatfs", "SD"]:
        os.makedirs(os.path.join(dst, rel), exist_ok=True)
    for rel in SOURCES + ["Seeed_FS.h", "fatfs/ff.h", "fatfs/integer.h", "fatfs/diskio.h", "SD/Seeed_sdcard_hal.h"]:
        text = open(os.path.join(src, rel), encoding="latin-1").read()
        # _T() pastes L onto its argument, which is not a literal in the drive names.
        text, n = re.subn(r"_T\(char\(('0' \+ _?pdrv)\)\)", r"(TCHAR)(\1)", text)
        if n != {"SD/Seeed_sdcard_hal.cpp": 2, "Seeed_FS.h": 1}.get(rel, 0):
            raise SystemExit("wio_sd: %s changed: %d _T(char(...)) drive names" % (rel, n))
        if rel == "SD/Seeed_sdcard_hal.cpp":
            # One volume, not two.
            old = "s_cards[_VOLUMES] = {NULL, NULL};"
            if text.count(old) != 1:
                raise SystemExit("wio_sd: %s changed: expected %s" % (rel, old))
            text = text.replace(old, "s_cards[_VOLUMES] = {};")
        _write_if_changed(os.path.join(dst, rel), text)
    text = open(os.path.join(src, "fatfs/ffconf.h"), encoding="latin-1").read()
    for name, value in FFCONF.items():
        text, n = re.subn(r"^(#define\s+%s\s+)\S+" % name, r"\g<1>" + value, text, flags=re.M)
        if n != 1:
            raise SystemExit("wio_sd: ffconf.h has no single #define %s" % name)
    _write_if_changed(os.path.join(dst, "fatfs/ffconf.h"), text)


if ENABLED:
    src = os.path.join(env.subst("$PROJECT_LIBDEPS_DIR"), env.subst("$PIOENV"), LIB, "src")  # noqa: F821
    if not os.path.isdir(src):
        raise SystemExit("wio_sd: no %s (the env's lib_deps installs it)" % src)
    dst = os.path.join(env.subst("$BUILD_DIR"), "wio_sd_src")  # noqa: F821
    _patched_copy(src, dst)
    # The card driver's framework libraries, which the dependency finder only adds for the project's own sources.
    framework = env.PioPlatform().get_package_dir("framework-arduino-samd-seeed")  # noqa: F821
    libs = [os.path.join(framework, "libraries", d) for d in ("SPI", "Adafruit_ZeroDMA")]
    env.Append(CPPDEFINES=[("WIO_SD", 1)], CPPPATH=[dst] + libs)  # noqa: F821
    env.BuildSources(  # noqa: F821
        os.path.join("$BUILD_DIR", "wio_sd"), dst, src_filter=["-<*>"] + ["+<%s>" % s for s in SOURCES]
    )
else:
    env.Append(CPPDEFINES=[("WIO_SD", 0)])  # noqa: F821

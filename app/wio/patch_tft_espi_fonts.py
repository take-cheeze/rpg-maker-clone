# PlatformIO pre-script: lets a Wio Terminal environment opt out of the
# Seeed_Arduino_LCD (TFT_eSPI fork) bitmap fonts 2/4/6/7/8.
#
# The library's bundled User_Setup.h #defines LOAD_GLCD, LOAD_FONT2/4/6/7/8
# and LOAD_GFXFF unconditionally, and nothing in this repo draws text through
# any of fonts 2-8: mruby-rgss/src/wio.cxx (env:wio, env:wio_rgss_boot) only
# pushes pixels (startWrite/setAddrWindow/pushColors/endWrite/begin/
# setRotation/setSwapBytes/fillScreen), and app/wio/src/walk_main.cxx
# (env:wio_walk) calls drawString() without ever selecting a font
# (setTextFont/setFreeFont/loadFont appear nowhere in the repo), so it only
# renders font 1 (GLCD). Fonts 2-8 still cost ~13.5 KB of glyph tables plus
# their RLE renderer, kept alive because drawChar/drawString are virtual (the
# vtable references them). See docs/adr/0199.
#
# The library's own documented way to drop a font is commenting its #define
# out of User_Setup.h, and that file cannot be overridden from build_flags in
# this fork: -DUSER_SETUP_LOADED only skips it in TFT_eSPI.h, while
# TFT_Interface.h still does an unconditional `#include <User_Setup.h>`
# (tried: TFT_eSPI.cpp then sees the fonts' #ifdef LOAD_FONT2 code with the
# tables never included -- 'widtbl_f16' was not declared in this scope). So
# this patches the *installed* package in place, the same way
# app/maix/patch_wire_i2c_timeout.py does for framework-maixduino -- but only
# to wrap those five #defines in
#
#   #ifndef RPGMAKER_WIO_TFT_NO_EXTRA_FONTS ... #endif
#
# which is a no-op by itself: every build keeps all fonts unless its own
# build_flags define RPGMAKER_WIO_TFT_NO_EXTRA_FONTS, so a package patched by
# one environment never changes what another (or another checkout sharing
# ~/.platformio) compiles. LOAD_GLCD (font 1, env:wio_walk's text) and
# LOAD_GFXFF stay outside the guard: TFT_eSPI.h declares the class's gfxFont
# member under LOAD_GFXFF, and libmruby.a's own wio.o (which defines the
# `TFT_eSPI g_tft` global) is compiled by the mruby cross build without these
# build_flags -- fonts 2-8 only change the file-scope fontdata[] table, never
# the class layout, so both sides still agree on what a TFT_eSPI is.
#
# Idempotent (checks for the guard macro), applied fresh by every build that
# lists it, including CI.

from os.path import isfile, join

Import("env")  # noqa: F821  (injected by PlatformIO/SCons)

GUARD = "RPGMAKER_WIO_TFT_NO_EXTRA_FONTS"

FONT_LINES = [
    "#define LOAD_FONT2  // Font 2.",
    "#define LOAD_FONT4  // Font 4.",
    "#define LOAD_FONT6  // Font 6.",
    "#define LOAD_FONT7  // Font 7.",
    "#define LOAD_FONT8  // Font 8.",
]


def patch_user_setup():
    framework_dir = env.PioPlatform().get_package_dir(  # noqa: F821
        "framework-arduino-samd-seeed"
    )
    if not framework_dir:
        return
    path = join(framework_dir, "libraries", "Seeed_Arduino_LCD", "User_Setup.h")
    if not isfile(path):
        return

    with open(path, "r") as f:
        lines = f.read().split("\n")

    if any(GUARD in line for line in lines):
        return  # already patched

    idx = [
        next(
            (i for i, line in enumerate(lines) if line.startswith(prefix)),
            None,
        )
        for prefix in FONT_LINES
    ]
    assert None not in idx and idx == list(range(idx[0], idx[0] + len(idx))), (
        "Seeed_Arduino_LCD User_Setup.h font block not found as 5 consecutive "
        "lines -- library version changed?"
    )

    first, last = idx[0], idx[-1]
    lines[last + 1 : last + 1] = [
        "#endif // %s (app/wio/patch_tft_espi_fonts.py)" % GUARD
    ]
    lines[first:first] = [
        "#ifndef %s // added by app/wio/patch_tft_espi_fonts.py" % GUARD
    ]

    with open(path, "w") as f:
        f.write("\n".join(lines))


patch_user_setup()

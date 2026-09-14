# PlatformIO pre-script for env:maix_amigo (see platformio.ini).
#
# The framework-maixduino package (~0.3.9) that sipeed/platform-kendryte210
# 1.3.0 installs predates the Maix Amigo: its variants/ has BiT/Go/ONE
# DOCK/Maixduino only, and the stock Arduino builder hardcodes CPPPATH at
# <framework>/variants/<build.variant> with no variants_dir-style override --
# so this environment's sipeed_maix_amigo variant resolves to a directory that
# does not exist and every core include fails on pins_arduino.h. The Amigo
# variant is header-only (pins_arduino.h, no sources), so pointing CPPPATH at
# the copy vendored in app/maix/variants/sipeed_maix_amigo/ is the whole fix;
# the builder's own BuildLibrary call against the missing directory already
# degrades to an empty lib rather than an error. Delete this script (and the
# vendored variant) once the platform/framework packages ship the Amigo.

from os.path import join

Import("env")

env.Append(CPPPATH=[join(env["PROJECT_DIR"], "app", "maix", "variants",
                         "sipeed_maix_amigo")])

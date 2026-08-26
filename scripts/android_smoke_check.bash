#!/usr/bin/env bash

# Install the Android debug APK the `android` CI job built, push a real
# RPG2k project (Nepheshel) to the fixed external-files game directory
# RpgMakerCloneActivity.java points --game_dir at (see app/android/README.md
# > Building), launch it with the rpg2k_extra_args intent-extra hook
# (RpgMakerCloneActivity#getArguments) so it self-drives to New Game and
# exits cleanly via --timeout_ms -- the same flags scripts/rpg2k_boot_check.bash
# uses on desktop -- with no touch-input automation needed, and assert it
# reached the map scene with no native crash.
#
# Run from the `android-smoke` CI job's reactivecircus/android-emulator-runner
# `script:` step, with the emulator already booted and `adb` already on PATH;
# not meant to run standalone.

set -eu -o pipefail

cd "$(dirname "$0")/.."

APK="${APK:-apk/app-debug.apk}"
PACKAGE="org.rpg2k.android"
ACTIVITY="${PACKAGE}/.RpgMakerCloneActivity"
GAME_DIR="/sdcard/Android/data/${PACKAGE}/files/game"
TIMEOUT_MS="${RPG2K_TIMEOUT_MS:-20000}"
LOGCAT_OUT="android-smoke-logcat.txt"
FULL_LOGCAT_OUT="android-smoke-full-logcat.txt"
SCREENSHOT_OUT="android-smoke-screenshot.png"

if [ ! -f "${APK}" ] ; then
    echo "error: ${APK} not found -- download the android-debug-apk artifact first" >&2
    exit 1
fi

echo "== installing ${APK}"
adb wait-for-device
adb install -r "${APK}"

# `adb push` into Android/data/<pkg>/... as the plain `shell` user fails on
# this AVD system image even once the app has created that directory itself
# (getExternalFilesDir()/mkdirs(), RpgMakerCloneActivity#getArguments()):
# first "remote secure_mkdirs failed: Permission denied" creating it, then
# (after priming it with one throwaway launch, still below) "stat failed ...
# Permission denied" on the now-existing directory -- confirmed on real CI
# runs, both against `google_apis` x86_64 API 30. Scoped storage is meant to
# carve out an adb-push/pull exception for exactly this (it works for real,
# undocumented, on a real device -- see app/android/README.md > Building),
# but this AVD image does not honor it. `adb root` sidesteps the whole
# question: a root adbd is not subject to scoped storage at all. The one
# throwaway launch below is kept anyway (harmless, and still useful if a
# future non-rooted image needs it back).
adb root
adb wait-for-device

echo "== priming ${PACKAGE}'s external-files directory"
adb shell am start -W -n "${ACTIVITY}"
sleep 5
adb shell am force-stop "${PACKAGE}"

echo "== pushing Nepheshel to ${GAME_DIR}"
adb push data/Nepheshel206beta/Nepheshel206Rbeta/. "${GAME_DIR}/"

adb logcat -c

echo "== launching ${ACTIVITY}"
adb shell am start -W -n "${ACTIVITY}" \
    --es rpg2k_extra_args "--test_play --rpg2k_new_game --timeout_ms=${TIMEOUT_MS}"

# Poll logcat for the [RPG2k-MAP] marker (Scene::Map reached) rather than a
# blind sleep: first-boot ART JIT warmup makes a fixed wait unreliable. Waits
# up to TIMEOUT_MS (the engine's own self-exit) plus a healthy margin for
# process startup and the emulator's own scheduling jitter.
max_wait_s=$(( (TIMEOUT_MS / 1000) + 60 ))
waited=0
while [ "${waited}" -lt "${max_wait_s}" ] ; do
    adb logcat -d -s RPG2K > "${LOGCAT_OUT}"
    if grep -q '\[RPG2k-MAP\]' "${LOGCAT_OUT}" ; then
        break
    fi
    sleep 5
    waited=$(( waited + 5 ))
done

adb exec-out screencap -p > "${SCREENSHOT_OUT}" || true
adb logcat -d -s RPG2K > "${LOGCAT_OUT}"
adb logcat -d > "${FULL_LOGCAT_OUT}"

echo "=== asserting the engine booted and reached the map scene ==="
if grep -q '\[RPG2k-MAP\]' "${LOGCAT_OUT}" ; then
    grep '\[RPG2k-MAP\]' "${LOGCAT_OUT}"
else
    echo "never reached the map scene ([RPG2k-MAP] missing) after ${waited}s; last 100 lines:" >&2
    tail -100 "${LOGCAT_OUT}" >&2
    exit 1
fi

echo "=== asserting no native crash reached the device log ==="
# Same markers app/android/README.md's own Debugging on-device section greps
# for by hand (F libc / F DEBUG tombstone headers), plus mruby's own
# uncaught-exception report tag. Checked against the whole device log, not
# just the RPG2K-tagged stream above: a native abort's tombstone is logged by
# the system, not by this app.
if grep -qE 'F libc|F DEBUG|FATAL EXCEPTION' "${FULL_LOGCAT_OUT}" ; then
    echo "native crash marker found in the device log:" >&2
    grep -E 'F libc|F DEBUG|FATAL EXCEPTION' "${FULL_LOGCAT_OUT}" >&2
    exit 1
fi

echo "android smoke check: reached the map scene after ${waited}s, no crash markers"

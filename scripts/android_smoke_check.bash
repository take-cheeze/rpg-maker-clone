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

# `adb push` straight into Android/data/<pkg>/... as the plain `shell` user
# fails outright on this AVD system image (`google_apis` x86_64 API 30),
# existing destination or not: "remote secure_mkdirs failed" creating it,
# "stat failed" once it exists. `adb root` gets past both, but then the
# pushed files are owned by root rather than going through the FUSE layer's
# normal shell-user permission translation, so the app's own UID can't read
# them back either (a real CI run crashed in libc++abi's filesystem_error,
# "Permission denied" posix_stat'ing RPG_RT.ini -- `chmod -R 777` as root
# did not fix this: this AVD's emulated external storage is FUSE-backed and
# synthesizes access from *which app owns the path*, not from real mode
# bits, so chmod is a no-op on it). `run-as` sidesteps all of that at once:
# it runs a command as the app's own UID, which the OS already grants
# unrestricted read/write to its own external-files directory -- no root,
# no scoped-storage exception needed.
#
# But `run-as ... mkdir -p` on the *full* path failed too ("mkdir:
# '/sdcard/Android': Permission denied") -- a raw shell mkdir walking the
# path from /sdcard/Android down hits the same FUSE restriction non-owning
# processes hit elsewhere in this script, even under run-as. Real
# Android API calls don't: getExternalFilesDir()/mkdirs()
# (RpgMakerCloneActivity#getArguments()) create the same directory from
# inside the app process without issue. So prime it that way -- one
# throwaway launch, no project pushed yet, so it exits almost immediately
# via src/main.cxx's "no project found" path -- and let `run-as` do only the
# `cp`, into a directory that already exists.
echo "== priming ${PACKAGE}'s external-files directory"
adb shell am start -W -n "${ACTIVITY}"
sleep 5
adb shell am force-stop "${PACKAGE}"

STAGING="/data/local/tmp/nepheshel"
adb shell rm -rf "${STAGING}"
adb push data/Nepheshel206beta/Nepheshel206Rbeta/. "${STAGING}/"
echo "== copying Nepheshel into ${GAME_DIR} as ${PACKAGE}"
# One argv element (see the `am start` comment below): `adb shell` re-joins
# several arguments with plain spaces, so passing run-as/sh/-c/the command as
# separate argv elements lets adb's own re-join scramble the quoting. Handing
# adb the whole thing pre-quoted, with the sh -c argument itself
# double-quoted, keeps the remote shell's own top-level parse from doing that.
COPY_CMD="cp -r '${STAGING}/.' '${GAME_DIR}/'"
adb shell "run-as ${PACKAGE} sh -c \"${COPY_CMD}\""
adb shell rm -rf "${STAGING}"

adb logcat -c

echo "== launching ${ACTIVITY}"
# One argv element, not several: `adb shell` re-joins multiple arguments with
# plain spaces before sending them to the device's own shell, which then
# re-splits on those same spaces -- the space-separated extras value below
# came back apart as separate `am start` options ("Unknown option:
# --rpg2k_new_game") the first time this ran. Single-quoting the value here
# and handing the whole command to `adb shell` as one string lets the
# device's shell -- not adb's own re-join -- be the one place that matters.
EXTRA_ARGS="--test_play --rpg2k_new_game --timeout_ms=${TIMEOUT_MS}"
adb shell "am start -W -n ${ACTIVITY} --es rpg2k_extra_args '${EXTRA_ARGS}'"

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

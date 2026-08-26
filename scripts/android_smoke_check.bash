#!/usr/bin/env bash

# Install the Android debug APK the `android` CI job built, push a real
# RPG2k project (Nepheshel) to a plain world-writable staging directory
# (see the --game_dir override below for why this is not
# RpgMakerCloneActivity.java's own external-files game directory), launch it
# with the rpg2k_extra_args intent-extra hook
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

# Getting a real project into RpgMakerCloneActivity's own external-files
# game directory (Android/data/<pkg>/files/game) turned out to be a dead end
# on this AVD system image (`google_apis` x86_64 API 30) -- four attempts,
# four different scoped-storage walls:
#  - plain `adb push` as the `shell` user: "secure_mkdirs failed" creating
#    the directory, "stat failed" once it exists -- either way, permission
#    denied.
#  - `adb root` gets past both, but the pushed files land owned by root
#    rather than going through the FUSE layer's normal shell-user
#    permission translation, so the app's own UID can't read them back
#    (libc++abi filesystem_error, "Permission denied" posix_stat'ing
#    RPG_RT.ini) -- and `chmod -R 777` as root does not fix it, because this
#    AVD's emulated external storage synthesizes access from *which app
#    owns the path*, not from real mode bits.
#  - `run-as` (the app's own UID, no root) can create the directory via a
#    real getExternalFilesDir() launch, but a `run-as cp` into it still hit
#    "Permission denied": run-as's shell does not carry the same per-app
#    storage mount namespace a real, zygote-launched app process gets, so
#    it is not actually equivalent to the app for scoped storage.
#
# Sidestepping the question entirely: `rpg2k_extra_args` (below,
# RpgMakerCloneActivity#getArguments) can carry a second --game_dir, and
# gflags takes the *last* occurrence of a repeated flag (src/main.cxx's
# plain `DEFINE_string(game_dir, ...)`, no dedup) -- so pointing it at a
# plain world-writable staging directory outside external storage
# altogether (/data/local/tmp, which a normal push always reaches without
# any of the above) skips scoped storage rather than fighting it.
STAGING="/data/local/tmp/nepheshel"
adb shell rm -rf "${STAGING}"
adb push data/Nepheshel206beta/Nepheshel206Rbeta/. "${STAGING}/"

adb logcat -c

echo "== launching ${ACTIVITY}"
# One argv element, not several: `adb shell` re-joins multiple arguments with
# plain spaces before sending them to the device's own shell, which then
# re-splits on those same spaces -- a space-separated extras value came back
# apart as separate `am start` options ("Unknown option: --rpg2k_new_game")
# the first time this ran. Single-quoting the value here and handing the
# whole command to `adb shell` as one string lets the device's shell -- not
# adb's own re-join -- be the one place that matters.
EXTRA_ARGS="--game_dir ${STAGING} --test_play --rpg2k_new_game --timeout_ms=${TIMEOUT_MS}"
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
    echo "never reached the map scene ([RPG2k-MAP] missing) after ${waited}s; last 100 RPG2K lines:" >&2
    tail -100 "${LOGCAT_OUT}" >&2
    # The RPG2K tag only ever carries this app's own bridged stderr (see
    # main.cxx's android_stderr_bridge) -- a native abort's tombstone (F
    # DEBUG/F libc) is logged by the system under other tags entirely, so a
    # crash with no application-level message needs the full device log to
    # see why at all. A plain chronological tail of that full log is *not*
    # good enough here: this `google_apis` image runs the full Google app/
    # service suite, which floods logcat continuously, so by the time the
    # poll loop above gives up, the crash-time entries are long since pushed
    # out of any reasonably-sized tail (confirmed the hard way -- a captured
    # "last 150 lines" was 100% unrelated system noise, nothing from this
    # app at all). Filtering by this run's own pid keeps the result relevant
    # regardless of how much else logged in between.
    PID="$(tail -1 "${LOGCAT_OUT}" | awk '{print $3}')"
    if echo "${PID}" | grep -qE '^[0-9]+$' ; then
        echo "full device log lines for this run's pid (${PID}):" >&2
        adb logcat -d --pid="${PID}" >&2 || true
    else
        echo "could not recover this run's pid from the RPG2K log; last 150 lines of the full device log:" >&2
        tail -150 "${FULL_LOGCAT_OUT}" >&2
    fi
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

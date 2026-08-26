#!/usr/bin/env bash

# Install the Android debug APK the `android` CI job built, stage a real
# RPG2k project (Nepheshel) via a plain world-writable directory and copy it
# into the app's own internal storage as the app itself (see the --game_dir
# override below for why this is not RpgMakerCloneActivity.java's own
# external-files game directory), launch it with the rpg2k_extra_args
# intent-extra hook
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
# game directory (Android/data/<pkg>/files/game) turned out to be a dead
# end on this AVD system image (`google_apis` x86_64 API 30) -- several
# attempts, several different scoped-storage walls (secure_mkdirs/stat
# permission denied as the plain `shell` user; root-owned, app-unreadable
# files after `adb root`; `run-as`'s shell not carrying the same per-app
# storage mount namespace a real launched process gets). Routing around
# external storage entirely via a second --game_dir into plain
# /data/local/tmp (gflags takes the *last* occurrence of a repeated flag,
# src/main.cxx's plain `DEFINE_string(game_dir, ...)`, no dedup) got
# further but hit a wall of its own kind: SIGSEGV, with an SELinux denial
# logged in the same instant --
#   avc: denied { append } for name="RPG_RT.ini" ...
#     scontext=u:r:untrusted_app:s0:... tcontext=u:object_r:shell_data_file:s0
# -- /data/local/tmp is labeled shell_data_file, and SELinux policy simply
# does not let the untrusted_app domain every real app process runs under
# touch that label, DAC permission bits notwithstanding; the open() call
# fails and something downstream dereferences the result unchecked.
#
# The one class of path avoiding all of the above at once: the app's own
# *internal* storage (Context.getFilesDir(), /data/data/<pkg>/files) --
# always owned by the app's own uid, always labeled for its own SELinux
# domain, no scoped-storage mount-namespace question at all, and (unlike
# external storage) squarely what `run-as` is documented to reach: its
# shell starts already cd'd into /data/data/<pkg>, so a plain relative
# `cp` lands correctly with no `mkdir -p`/absolute-path games needed.
STAGING="/data/local/tmp/nepheshel"
INTERNAL_GAME_DIR="/data/data/${PACKAGE}/files/game"
adb shell rm -rf "${STAGING}"
adb push data/Nepheshel206beta/Nepheshel206Rbeta/. "${STAGING}/"
echo "== copying Nepheshel into ${PACKAGE}'s internal storage"
adb shell "run-as ${PACKAGE} sh -c \"mkdir -p files/game && cp -r ${STAGING}/. files/game/\""
adb shell rm -rf "${STAGING}"

adb logcat -c

echo "== launching ${ACTIVITY}"
# One argv element, not several: `adb shell` re-joins multiple arguments with
# plain spaces before sending them to the device's own shell, which then
# re-splits on those same spaces -- a space-separated extras value came back
# apart as separate `am start` options ("Unknown option: --rpg2k_new_game")
# the first time this ran. Single-quoting the value here and handing the
# whole command to `adb shell` as one string lets the device's shell -- not
# adb's own re-join -- be the one place that matters.
EXTRA_ARGS="--game_dir ${INTERNAL_GAME_DIR} --test_play --rpg2k_new_game --timeout_ms=${TIMEOUT_MS}"
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

# Print every device log line carrying this run's own pid -- used by both
# assertions below on failure. The RPG2K tag alone only ever carries this
# app's own bridged stderr (see main.cxx's android_stderr_bridge); a native
# abort's tombstone (F DEBUG/F libc) is logged by the system under other
# tags entirely, so seeing *why* (not just *that*) needs the full device
# log, not just the RPG2K-tagged stream. A plain chronological tail of that
# full log is not good enough here: this `google_apis` image runs the full
# Google app/service suite, which floods logcat continuously, so by the
# time either assertion below runs, unrelated entries have long since
# pushed the interesting ones out of any reasonably-sized tail (confirmed
# the hard way -- a captured "last 150 lines" was 100% unrelated system
# noise, nothing from this app at all). Filtering by this run's own pid
# keeps the result relevant regardless of how much else logged in between.
print_pid_context() {
    # grep for an actual RPG2K line first: logcat's own
    # "--------- beginning of crash" buffer-switch marker (not tied to the
    # -s RPG2K filter at all) can be the literal last line, and it has no
    # pid column to extract.
    local pid
    pid="$(grep ' RPG2K ' "${LOGCAT_OUT}" | tail -1 | awk '{print $3}')"
    if echo "${pid}" | grep -qE '^[0-9]+$' ; then
        echo "full device log lines for this run's pid (${pid}):" >&2
        adb logcat -d --pid="${pid}" >&2 || true
    else
        echo "could not recover this run's pid from the RPG2K log; last 150 lines of the full device log:" >&2
        tail -150 "${FULL_LOGCAT_OUT}" >&2
    fi
}

echo "=== asserting the engine booted and reached the map scene ==="
if grep -q '\[RPG2k-MAP\]' "${LOGCAT_OUT}" ; then
    grep '\[RPG2k-MAP\]' "${LOGCAT_OUT}"
else
    echo "never reached the map scene ([RPG2k-MAP] missing) after ${waited}s; last 100 RPG2K lines:" >&2
    tail -100 "${LOGCAT_OUT}" >&2
    print_pid_context
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
    print_pid_context
    exit 1
fi

echo "android smoke check: reached the map scene after ${waited}s, no crash markers"

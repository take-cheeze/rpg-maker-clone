#!/usr/bin/env bash

# Run a command with ALSA's "no sound card" flood filtered out of its output.
#
# CI runners have no audio device, so every engine run prints a wall of
# `ALSA lib confmisc.c:...: cannot find card '0'` / `snd_...` / `Unknown PCM`
# lines that says nothing about the check being run. The boot checks
# (rpg2k_boot_check.bash, mz_boot_check.bash) already strip exactly these three
# patterns from the logs they print; this wrapper lets the smoke steps in
# .github/workflows/build.yml do the same without each one re-spelling the
# pipeline.
#
# The command's exit status is preserved (`pipefail` plus a filter that always
# succeeds), so a failing engine still fails the step, and every non-ALSA line —
# including the `[MV-*]` / `[MZ-*]` markers the smokes assert on — is passed
# through untouched.
#
# Usage: ./scripts/quiet_alsa.bash <command> [args...]

set -u -o pipefail

"$@" 2>&1 | { grep -vE 'ALSA lib|snd_|Unknown PCM' || true; }

#!/usr/bin/env bash

set -eu -o pipefail

# Boot a nano7_walk_qemu.elf (scripts/nano7_qemu_build.bash) under
# qemu-system-arm, capture its UART log, and screendump the real PL110
# framebuffer once app/nano7/qemu/nano7_qemu_shim.c's own "NANO7-QEMU done"
# marker appears in that log -- see docs/adr/0103.
#
# Usage:
#   scripts/nano7_qemu_run.bash ELF OUT_PPM OUT_UART_LOG [TIMEOUT_SECONDS]

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
    echo "usage: $0 ELF OUT_PPM OUT_UART_LOG [TIMEOUT_SECONDS]" >&2
    exit 1
fi

elf=$1
out_ppm=$2
out_uart_log=$3
timeout_s=${4:-30}

work=$(mktemp -d)
qmp_sock="$work/qmp.sock"
qemu_pid=""

cleanup() {
    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

rm -f "$out_uart_log"
touch "$out_uart_log"

# -m 4M: sized against app/nano7/qemu/link.ld's own MEMORY regions (image +
# blobs + app_bss + shadow_fb + stack sums to ~1.76 MiB from ORIGIN(image)),
# not an arbitrary guess -- see that file's header for exactly which of
# those regions maps to a real NanoApps limit and which don't. -display
# none: this target's whole point is running headless in CI; the
# screendump below reads the real PL110 framebuffer directly, no window
# needed. Audio is left at its default backend -- ALSA warnings are the
# realview board's unrelated on-board codec probing a device this
# container doesn't have, harmless and unrelated to this target.
qemu-system-arm -M realview-pb-a8 -cpu cortex-a8 -m 4M -display none \
    -chardev file,id=ser0,path="$out_uart_log" -serial chardev:ser0 \
    -qmp unix:"$qmp_sock",server,nowait \
    -kernel "$elf" >/dev/null 2>&1 &
qemu_pid=$!

python3 - "$qmp_sock" "$out_uart_log" "$out_ppm" "$timeout_s" <<'PYEOF'
import json
import socket
import sys
import time

qmp_sock, uart_log, out_ppm, timeout_s = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
deadline = time.time() + timeout_s

s = None
while time.time() < deadline:
    try:
        s = socket.socket(socket.AF_UNIX)
        s.connect(qmp_sock)
        break
    except (FileNotFoundError, ConnectionRefusedError):
        time.sleep(0.1)
if s is None:
    sys.exit("nano7_qemu_run: QEMU's QMP socket never appeared")


def send(obj):
    s.send((json.dumps(obj) + "\n").encode())


def recv():
    return s.recv(65536).decode()


recv()  # greeting
send({"execute": "qmp_capabilities"})
recv()

marker_seen = False
while time.time() < deadline:
    try:
        with open(uart_log, encoding="utf-8", errors="replace") as f:
            if "NANO7-QEMU done" in f.read():
                marker_seen = True
                break
    except FileNotFoundError:
        pass
    time.sleep(0.1)

if not marker_seen:
    sys.exit(f"nano7_qemu_run: '{uart_log}' never showed the NANO7-QEMU done marker "
             f"within {timeout_s}s")

send({"execute": "human-monitor-command", "arguments": {"command-line": f"screendump {out_ppm}"}})
reply = json.loads(recv())
if "error" in reply:
    sys.exit(f"nano7_qemu_run: screendump failed: {reply['error']}")

send({"execute": "quit"})
PYEOF

wait "$qemu_pid" 2>/dev/null || true
qemu_pid=""

[ -f "$out_ppm" ] || {
    echo "nano7_qemu_run: $out_ppm was not written" >&2
    exit 1
}

#!/usr/bin/env python3
"""Push files onto a Maix Amigo's microSD card over USB-CDC serial.

Talks to the `maix_sd_upload` PlatformIO environment
(app/wio/src/maix_sd_upload_main.cxx), a throwaway firmware whose only job
is to receive a file over Serial and write it to SD -- for a dev machine
with a board but no card reader to pull the card into. Flash that
environment first (`pio run -e maix_sd_upload -t upload --upload-port
/dev/ttyUSB1`), run this, then reflash whichever real firmware
(`maix_game` or `maix_amigo`) you actually want running.

The wire protocol is byte-identical to scripts/wio_sd_upload.py's
(PING/PUT, see app/wio/src/sd_upload_main.cxx); only the defaults differ
for this board (K210 download/console port, 115200 baud).

Usage:
    scripts/maix_sd_upload.py [--port /dev/ttyUSB1] LOCAL:REMOTE [LOCAL:REMOTE ...]

Example (game data for the maix_game firmware, which reads GAME_DIR
/sd/maixhello):
    ruby scripts/gen-maix-hello-game.rb /tmp/maixhello
    scripts/maix_sd_upload.py \\
        /tmp/maixhello/RPG_RT.ldb:/sd/maixhello/RPG_RT.ldb \\
        /tmp/maixhello/RPG_RT.lmt:/sd/maixhello/RPG_RT.lmt \\
        /tmp/maixhello/Title/maix.png:/sd/maixhello/Title/maix.png
"""

import argparse
import sys

import serial


def read_line(ser):
    line = ser.readline()
    if not line.endswith(b"\n"):
        raise RuntimeError(f"timed out waiting for a reply, got {line!r}")
    return line.decode("ascii", "replace").strip()


def put_file(ser, local_path, remote_path):
    with open(local_path, "rb") as f:
        data = f.read()

    ser.write(f"PUT {remote_path} {len(data)}\n".encode("ascii"))
    reply = read_line(ser)
    if reply != "OK":
        raise RuntimeError(f"PUT {remote_path} rejected: {reply}")

    ser.write(data)

    reply = read_line(ser)
    if not reply.startswith("DONE"):
        raise RuntimeError(f"PUT {remote_path} failed: {reply}")
    written = int(reply.split()[1])
    if written != len(data):
        raise RuntimeError(
            f"PUT {remote_path}: wrote {written} of {len(data)} bytes"
        )
    print(f"{local_path} -> {remote_path} ({written} bytes)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="/dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "files", nargs="+", metavar="LOCAL:REMOTE", help="e.g. RPG_RT.ldb:/sd/maixhello/RPG_RT.ldb"
    )
    args = parser.parse_args()

    pairs = []
    for spec in args.files:
        if ":" not in spec:
            parser.error(f"expected LOCAL:REMOTE, got {spec!r}")
        local, remote = spec.split(":", 1)
        pairs.append((local, remote))

    with serial.Serial(args.port, args.baud, timeout=10) as ser:
        ser.write(b"PING\n")
        reply = read_line(ser)
        if reply != "PONG SD_OK":
            sys.exit(f"board did not report a usable SD card: {reply!r}")

        for local, remote in pairs:
            put_file(ser, local, remote)


if __name__ == "__main__":
    main()

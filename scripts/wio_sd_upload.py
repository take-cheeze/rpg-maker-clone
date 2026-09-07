#!/usr/bin/env python3
"""Push files onto a Wio Terminal's microSD card over USB-CDC serial.

Talks to the `wio_sd_upload` PlatformIO environment
(app/wio/src/sd_upload_main.cxx), a throwaway firmware whose only job is to
receive a file over Serial and write it to SD -- for a dev machine with a
board but no card reader to pull the card into. Flash that environment first
(`pio run -e wio_sd_upload -t upload`), run this, then reflash whichever real
firmware (`wio` or `wio_walk`) you actually want running.

Usage:
    scripts/wio_sd_upload.py [--port /dev/ttyACM0] LOCAL:REMOTE [LOCAL:REMOTE ...]

Example (the wio_walk map export):
    scripts/wio_sd_upload.py \\
        /tmp/rpg2k_walk_out/map.bin:/RPG2kWalk/map.bin \\
        /tmp/rpg2k_walk_out/tiles.bin:/RPG2kWalk/tiles.bin
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
    parser.add_argument("--port", default="/dev/ttyACM0")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument(
        "files", nargs="+", metavar="LOCAL:REMOTE", help="e.g. map.bin:/RPG2kWalk/map.bin"
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

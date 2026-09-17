#!/usr/bin/env python3
"""Push files onto a Maix Amigo's microSD card over USB-CDC serial.

Talks to the `maix_sd_upload` PlatformIO environment
(app/wio/src/maix_sd_upload_main.cxx), a throwaway firmware whose only job
is to receive a file over Serial and write it to SD -- for a dev machine
with a board but no card reader to pull the card into. Flash that
environment first (`pio run -e maix_sd_upload -t upload --upload-port
/dev/ttyUSB1`), run this, then reflash whichever real firmware
(`maix_game` or `maix_amigo`) you actually want running.

PING is byte-identical to scripts/wio_sd_upload.py's (see
app/wio/src/sd_upload_main.cxx), but PUT's data phase is this board's own
protocol (see app/wio/src/maix_sd_upload_main.cxx's own header comment
for why -- a K210 UARTHS quirk the Wio's UART doesn't have) -- so the two
scripts are not wire-compatible for that part. This board's defaults also
differ: K210 download/console port, 1500000 baud (see
maix_sd_upload_main.cxx's own setup() comment for why that rate is safe
here despite being well above the console/game firmwares' 115200).

Usage:
    scripts/maix_sd_upload.py [--port /dev/ttyUSB1] LOCAL:REMOTE [LOCAL:REMOTE ...]

Example (game data for the maix_game firmware, which reads GAME_DIR
/sd/maixgame):
    ruby scripts/gen-maix-hello-game.rb /tmp/maixhello
    scripts/maix_sd_upload.py \\
        /tmp/maixhello/RPG_RT.ldb:/sd/maixgame/RPG_RT.ldb \\
        /tmp/maixhello/RPG_RT.lmt:/sd/maixgame/RPG_RT.lmt \\
        /tmp/maixhello/Title/maix.png:/sd/maixgame/Title/maix.png

Remote paths must be 8.3: the bundled sdfat has no long-filename support
(SdFile::make83Name rejects anything past 8 chars before the dot), so a
remote like /sd/maixhello/... can never be created -- keep every path
component short.
"""

import argparse
import sys
import time

import serial


def read_line(ser):
    line = ser.readline()
    if not line.endswith(b"\n"):
        raise RuntimeError(f"timed out waiting for a reply, got {line!r}")
    return line.decode("ascii", "replace").strip()


#  Must match app/wio/src/maix_sd_upload_main.cxx's own kChunk exactly:
# that firmware only buffers one CHUNK_SIZE-decoded-byte accumulation
# before an SD write, and only sends "CHUNK_OK" (this side's cue to send
# the next piece) after that write completes -- sending more than it
# expects per piece would overrun its RX ring buffer during that write.
CHUNK_SIZE = 2048


def put_file(ser, local_path, remote_path):
    with open(local_path, "rb") as f:
        data = f.read()

    ser.write(f"PUT {remote_path} {len(data)}\n".encode("ascii"))
    reply = read_line(ser)
    if reply != "OK":
        raise RuntimeError(f"PUT {remote_path} rejected: {reply}")

    # Hex-encoded on the wire (two lowercase chars per byte): the
    # framework's UARTHS receive ISR drops 0x00 bytes outright, so raw
    # binary can never arrive intact. One CHUNK_SIZE-worth of hex per
    # write, each followed by waiting for the firmware's "CHUNK_OK" --
    # self-paced around its SD-write stall instead of a guessed sleep
    # (see maix_sd_upload_main.cxx's own comment on why that used to
    # dominate transfer time). The final chunk gets no CHUNK_OK -- the
    # firmware goes straight to DONE once nothing remains.
    total = len(data)
    for i in range(0, total, CHUNK_SIZE):
        chunk = data[i : i + CHUNK_SIZE]
        ser.write(chunk.hex().encode("ascii"))
        if i + CHUNK_SIZE < total:
            reply = read_line(ser)
            if reply != "CHUNK_OK":
                raise RuntimeError(
                    f"PUT {remote_path}: expected CHUNK_OK, got {reply!r}"
                )

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
    parser.add_argument("--baud", type=int, default=1500000)
    parser.add_argument(
        "files", nargs="+", metavar="LOCAL:REMOTE", help="e.g. RPG_RT.ldb:/sd/maixgame/RPG_RT.ldb"
    )
    args = parser.parse_args()

    pairs = []
    for spec in args.files:
        if ":" not in spec:
            parser.error(f"expected LOCAL:REMOTE, got {spec!r}")
        local, remote = spec.split(":", 1)
        pairs.append((local, remote))

    with serial.Serial(args.port, args.baud, timeout=10) as ser:
        # Opening the port resets the K210; give the loader time to boot
        # and drop any bytes the reset shook loose, or the first PING can
        # arrive garbled mid-boot and come back "ERR unknown command".
        time.sleep(3)
        ser.reset_input_buffer()
        ser.write(b"PING\n")
        reply = read_line(ser)
        if reply != "PONG SD_OK":
            sys.exit(f"board did not report a usable SD card: {reply!r}")

        for local, remote in pairs:
            put_file(ser, local, remote)


if __name__ == "__main__":
    main()

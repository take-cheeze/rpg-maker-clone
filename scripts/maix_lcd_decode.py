#!/usr/bin/env python3
# Decode a Maix Amigo Renode LCD capture ($MAIX_SPI_LOG: `D <dc> <hex32>`
# lines from app/maix/renode's DMA hook + GPIO pairing) into a framebuffer.
#
# The driver's traffic is plain ST7789 in the driver's own coordinate space:
# `2A` (CASET: 4 param bytes xs_hi xs_lo xe_hi xe_lo), `2B` (RASET, same for
# rows), `2C` (RAMWR: pixel data follows, one RGB565 pixel per 16 bits, two
# per 32-bit bus unit, row-major), everything else ignored. Command params
# arrive one byte per bus unit (low 8 bits); pixels arrive two per unit.
# stdlib only (zlib-free PPM output), so CI needs nothing installed.
#
# Usage:
#   scripts/maix_lcd_decode.py capture.log frame.ppm [--min-blue 0.9]
#       [--min-colors 2] [--expect-size 320x240]
# Prints a `MAIX-LCD ...` stats line and exits nonzero when an expectation
# fails -- the line is what CI greps, the exit code is what gates it.
import struct
import sys


def rgb565_to_rgb888(px):
    r = (px >> 11) & 0x1F
    g = (px >> 5) & 0x3F
    b = px & 0x1F
    return (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print("usage: maix_lcd_decode.py capture.log frame.ppm [--min-blue F] [--min-colors N] [--expect-size WxH]",
              file=sys.stderr)
        return 2
    cap_path, ppm_path = args[0], args[1]
    min_blue, min_colors, expect_size = 0.0, 0, None
    i = 2
    while i < len(args):
        if args[i] == "--min-blue":
            min_blue = float(args[i + 1])
            i += 2
        elif args[i] == "--min-colors":
            min_colors = int(args[i + 1])
            i += 2
        elif args[i] == "--expect-size":
            w, h = args[i + 1].split("x")
            expect_size = (int(w), int(h))
            i += 2
        else:
            print("unknown arg: %s" % args[i], file=sys.stderr)
            return 2

    fb_w, fb_h = 320, 480
    fb = [0x0000] * (fb_w * fb_h)
    max_x = max_y = 0
    cmd, params = None, []
    win = [0, 0, 0, 0]
    px = []
    n_pixels = 0

    def flush_pixels():
        nonlocal n_pixels
        xs, ys, xe, ye = win
        k = 0
        for y in range(ys, ye + 1):
            for x in range(xs, xe + 1):
                if k >= len(px):
                    return
                if 0 <= x < fb_w and 0 <= y < fb_h:
                    fb[y * fb_w + x] = px[k]
                k += 1
        n_pixels += k

    for line in open(cap_path):
        parts = line.split()
        if len(parts) != 3 or parts[0] != "D":
            continue
        dc, word = int(parts[1]), int(parts[2], 16)
        if dc == 0:
            flush_pixels()
            px = []
            if cmd in (0x2A, 0x2B) and len(params) == 4:
                a = (params[0] << 8) | params[1]
                b = (params[2] << 8) | params[3]
                if cmd == 0x2A:
                    win[0], win[2] = a, b
                else:
                    win[1], win[3] = a, b
                max_x = max(max_x, win[2])
                max_y = max(max_y, win[3])
            cmd, params = word & 0xFF, []
        else:
            if cmd == 0x2C:
                px.append(word & 0xFFFF)
                px.append((word >> 16) & 0xFFFF)
            elif cmd in (0x2A, 0x2B):
                params.append(word & 0xFF)
    flush_pixels()

    colors = {}
    for p in fb:
        colors[p] = colors.get(p, 0) + 1
    total = fb_w * fb_h
    blue = colors.get(0x001F, 0) / total

    with open(ppm_path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (fb_w, fb_h))
        for p in fb:
            f.write(struct.pack("BBB", *rgb565_to_rgb888(p)))

    ok = True
    reasons = []
    if blue < min_blue:
        ok = False
        reasons.append("blue %.3f < %.3f" % (blue, min_blue))
    if len(colors) < min_colors:
        ok = False
        reasons.append("colors %d < %d" % (len(colors), min_colors))
    if expect_size is not None and (max_x + 1, max_y + 1) != expect_size:
        ok = False
        reasons.append("extent %dx%d != %dx%d" % (max_x + 1, max_y + 1, *expect_size))
    print("MAIX-LCD pixels=%d blue=%.3f distinct=%d extent=%dx%d %s" % (
        n_pixels, blue, len(colors), max_x + 1, max_y + 1,
        "OK" if ok else "FAIL " + "; ".join(reasons)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

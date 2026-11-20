# QSPI_XIP (app/wio/qspi_xip.ld): split the linked firmware into the internal-flash image the bootloader takes
# (firmware.bin, without the QSPI sections) and the external-flash image (qspi.bin, the bytes at 0x04000000 with
# their header filled in). The header carries the firmware's build-id, which wio_qspi_xip.c compares at boot.
import struct
import subprocess

Import("env")  # noqa: F821  (SCons)

QSPI_SECTIONS = [".qspi_header", ".qspi", ".qspi_exidx"]
MAGIC = 0x49505351  # WIO_QSPI_MAGIC
HEADER_SIZE = 32

objcopy = env.subst("$OBJCOPY")  # noqa: F821
# ElfToBin/ElfToHex expand $OBJCOPY when they run, so the internal images leave the QSPI sections out; without
# this, -O binary would pad from 0x4000 up to the 0x04000000 window.
env.Replace(OBJCOPY=" ".join([objcopy] + [f"-R {s}" for s in QSPI_SECTIONS]))  # noqa: F821


def build_qspi_image(target, source, env):
    elf = target[0].get_abspath()
    out = elf[: -len(".elf")] + "_qspi.bin"
    subprocess.run([objcopy, "-O", "binary"] + sum([["-j", s] for s in QSPI_SECTIONS], []) + [elf, out], check=True)
    note = elf + ".build-id"
    subprocess.run([objcopy, "-O", "binary", "-j", ".note.gnu.build-id", elf, note], check=True)
    with open(note, "rb") as f:
        raw = f.read()
    namesz, descsz, kind = struct.unpack_from("<III", raw)
    if kind != 3 or descsz != 20:  # NT_GNU_BUILD_ID, sha1
        raise SystemExit(f"qspi_image.py: {elf} has no sha1 build-id note (link with -Wl,--build-id=sha1)")
    build_id = raw[12 + ((namesz + 3) & ~3):][:descsz]
    with open(out, "r+b") as f:
        image = f.read()
        if len(image) < HEADER_SIZE or image[:HEADER_SIZE] != bytes(HEADER_SIZE):
            raise SystemExit(f"qspi_image.py: {out} does not start with qspi_xip.ld's zeroed header")
        f.seek(0)
        f.write(struct.pack("<II", MAGIC, len(image) - HEADER_SIZE) + build_id + b"\0" * 4)
    print(f"QSPI image: {out} ({len(image)} bytes)")


env.AddPostAction("$BUILD_DIR/${PROGNAME}.elf", build_qspi_image)  # noqa: F821

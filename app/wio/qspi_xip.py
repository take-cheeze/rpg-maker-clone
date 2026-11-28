# QSPI_XIP: links the firmware with app/wio/qspi_xip.ld, which runs the cold code from the external QSPI flash, and
# writes the second image that flash takes (firmware_qspi.bin, header filled in). WIO_QSPI_XIP=0 keeps the env's own
# all-internal link. Listed twice in extra_scripts: the pre pass sets up the link, the post pass the size check and
# objcopy (the platform's builder sets both after the pre scripts run).
#
# custom_qspi_xip_ram (platformio.ini) overrides the RAM length, for the Renode boards with more of it.
import math
import os
import re
import struct
import subprocess
import zlib

Import("env")  # noqa: F821

ENABLED = os.environ.get("WIO_QSPI_XIP") != "0"
QSPI_START, QSPI_END = 0x04000000, 0x04400000
MAGIC = 0x50495857  # WIO_QSPI_MAGIC (app/wio/src/wio_qspi.h)
HEADER_SIZE = 32
BLOCK = 256
# Sections the internal-flash image leaves out: everything qspi_xip.ld places in QSPI.
QSPI_SECTIONS = [".qspi_header", ".qspi_text", ".qspi_rodata", ".ARM.extab", ".ARM.exidx"]
LIBMRUBY = ["*.ltrans.o", "*libmruby.a:*"]
# Objects that go to QSPI whole: the microSD card's FAT driver (app/wio/wio_sd.py builds it there), which runs only
# while a game file is opened or read, and the QSPI cache (app/wio/src/wio_image_cache*.cxx), which runs when a
# bitmap or file is fetched; its flash writes are QSPI_WRITE's, which stay internal.
COLD_OBJECTS = ["*/wio_sd/*.o", "*/src/wio_image_cache*.o"]
HERE = os.path.join(env.subst("$PROJECT_DIR"), "app", "wio")  # noqa: F821


def _patterns(path):
    """(where, glob) per line of a placement file: `internal`, `text` or `rodata`, then an ld section-name glob."""
    out = []
    for n, line in enumerate(open(path), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        where, _, glob = line.partition(" ")
        glob = glob.strip()
        if where not in ("internal", "text", "rodata") or not glob or " " in glob:
            raise SystemExit("qspi_xip: %s:%d: expected `internal|text|rodata GLOB`" % (path, n))
        out.append((where, glob))
    return out


def _write_fragments(build):
    rules = _patterns(os.path.join(HERE, "qspi_xip_placement.txt"))
    rules += [("internal", g) for _, g in _patterns(os.path.join(HERE, "qspi_xip_hot.txt"))]
    # A pinned function stays internal whatever GCC's guess about it.
    prefixes = {"internal": [".text.", ".text.hot.", ".text.unlikely."], "text": [".text."], "rodata": [".rodata."]}
    # Only libmruby's code moves (its LTO unit, or its members with WIO_LTO=0): the Arduino core, the USB stack, the
    # LCD driver and newlib stay internal whatever their names.
    files = {"internal": ["*"], "text": LIBMRUBY, "rodata": LIBMRUBY}
    for where in ("internal", "text", "rodata"):
        lines = ["%s(%s)" % (f, " ".join(p + g for p in prefixes[where]))
                 for w, g in rules if w == where for f in files[where]]
        if where != "internal":
            lines += ["%s(.%s .%s.*)" % (o, where, where) for o in COLD_OBJECTS]
        with open(os.path.join(build, "qspi_xip_%s.ld" % where), "w") as f:
            f.write("\n".join(lines) + "\n")


def _ldscript(build):
    text = open(os.path.join(HERE, "qspi_xip.ld")).read()
    ram = env.GetProjectOption("custom_qspi_xip_ram", "")  # noqa: F821
    if ram:
        text, n = re.subn(r"(RAM \(rwx\) : ORIGIN = 0x20000000, LENGTH = )0x[0-9a-fA-F]+", r"\g<1>" + ram, text)
        if n != 1:
            raise SystemExit("qspi_xip: qspi_xip.ld has no single RAM line to widen")
    path = os.path.join(build, "qspi_xip.ld")
    with open(path, "w") as f:
        f.write(text)
    return path


def _sections(elf):
    data = open(elf, "rb").read()
    shoff = struct.unpack_from("<I", data, 0x20)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)
    raw = [struct.unpack_from("<10I", data, shoff + i * shentsize) for i in range(shnum)]
    names = raw[shstrndx][4]
    out = {}
    for r in raw:
        name = data[names + r[0]:data.index(b"\0", names + r[0])].decode()
        out[name] = (r[1], r[3], data[r[4]:r[4] + r[5]])  # type, addr, bytes
    return out


def _stride(blocks):
    """A step coprime with +blocks+, near its golden section, so consecutive blocks are far apart."""
    if blocks < 3:
        return 1 if blocks == 2 else 0
    s = max(1, int(blocks * 0.618))
    while math.gcd(s, blocks) != 1:
        s += 1
    return s


def _crc(payload, stride):
    blocks = (len(payload) + BLOCK - 1) // BLOCK
    crc = 0
    for i in range(blocks):
        off = (i * stride % blocks) * BLOCK
        crc = zlib.crc32(payload[off:off + BLOCK], crc)
    return crc


def _image(target, source, env):
    elf = target[0].get_abspath()
    secs = _sections(elf)
    placed = sorted((addr, name, body) for name, (typ, addr, body) in secs.items()
                    if QSPI_START <= addr < QSPI_END and typ != 8 and body)  # not NOBITS
    unknown = [n for _, n, _ in placed if n not in QSPI_SECTIONS]
    if unknown or not placed or placed[0][1] != ".qspi_header":
        raise SystemExit("qspi_xip: unexpected QSPI sections %s" % [n for _, n, _ in placed])
    image = bytearray()
    for addr, _, body in placed:
        image += b"\0" * (addr - QSPI_START - len(image))  # alignment padding
        image += body
    note = secs[".note.gnu.build-id"][2]
    namesz, descsz, kind = struct.unpack_from("<III", note)
    if kind != 3 or descsz < 16:  # NT_GNU_BUILD_ID
        raise SystemExit("qspi_xip: %s has no build-id note" % elf)
    build_id = note[12 + ((namesz + 3) & ~3):][:16]
    payload = bytes(image[HEADER_SIZE:])
    blocks = (len(payload) + BLOCK - 1) // BLOCK
    stride = _stride(blocks)
    header = struct.pack("<IIII16s", MAGIC, len(payload), _crc(payload, stride), stride, build_id)
    image[:HEADER_SIZE] = header
    base = elf[: -len(".elf")]
    with open(base + "_qspi.bin", "wb") as f:
        f.write(image)
    # The ELF carries the filled header too, so loading it (Renode) is the same as programming both images.
    with open(base + "_qspi_header.bin", "wb") as f:
        f.write(header)
    objcopy = env.subst("$OBJCOPY").split()[0]
    subprocess.run([objcopy, "--update-section", ".qspi_header=%s_qspi_header.bin" % base, elf], check=True)
    print("QSPI image: %s_qspi.bin (%d bytes of %d, game ROM at 0x%08x)"
          % (base, len(image), QSPI_END - QSPI_START, _game_rom_base(elf, env)))


def _game_rom_base(elf, env):
    nm = env.subst("$OBJCOPY").split()[0].replace("objcopy", "nm")
    for line in subprocess.check_output([nm, elf], text=True).splitlines():
        f = line.split()
        if len(f) == 3 and f[2] == "__wio_game_rom_base":
            return int(f[0], 16)
    raise SystemExit("qspi_xip: no __wio_game_rom_base in %s" % elf)


if ENABLED and not env.get("QSPI_XIP_PRE_DONE"):  # noqa: F821
    build = env.subst("$BUILD_DIR")  # noqa: F821
    os.makedirs(build, exist_ok=True)
    _write_fragments(build)
    script = _ldscript(build)
    # The board config too: the framework builder only sets its own linker script when the board names none.
    env.BoardConfig().update("build.ldscript", script)  # noqa: F821
    env.Replace(LDSCRIPT_PATH=script, QSPI_XIP_PRE_DONE=True)  # noqa: F821
    env.Append(LINKFLAGS=["-L" + build, "-Wl,--build-id=sha1"], CPPDEFINES=[("WIO_QSPI_XIP", 1)])  # noqa: F821
    env.AddPostAction("$BUILD_DIR/${PROGNAME}.elf", _image)  # noqa: F821
elif ENABLED:
    # Internal flash only, in the size check and in firmware.bin (what the bootloader writes): without the -R, -O
    # binary would pad from 0x4000 up to the QSPI window.
    env.Replace(SIZEPROGREGEXP=r"^(?:\.text|\.text_rest|\.note\.gnu\.build-id|\.data)\s+(\d+).*")  # noqa: F821
    objcopy = env.subst("$OBJCOPY")  # noqa: F821
    env.Replace(OBJCOPY=" ".join([objcopy] + ["-R %s" % s for s in QSPI_SECTIONS]))  # noqa: F821

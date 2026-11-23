# EXIDX_MERGE: ld drops an .ARM.exidx entry equal to the one before it (EXIDX_CANTUNWIND, or the same inline unwind
# descriptor), and thousands of functions share about a hundred descriptors. The firmware is linked once, then again
# with its .text input sections grouped by descriptor, leaving about one entry per group. Only the order changes: each
# function is covered by its own unwind entry or an equal one, which _check proves against the first link.
# WIO_EXIDX_MERGE=0 links once.
import bisect
import os
import re
import shlex
import struct

Import("env")  # noqa: F821


def _elf_sections(path):
    data = open(path, "rb").read()
    shoff = struct.unpack_from("<I", data, 0x20)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x2E)
    raw = [struct.unpack_from("<10I", data, shoff + i * shentsize) for i in range(shnum)]
    names = raw[shstrndx][4]
    out = {}
    for r in raw:
        name = data[names + r[0]:data.index(b"\0", names + r[0])].decode()
        out[name] = (r[3], data[r[4]:r[4] + r[5]], r)
    return data, out


def _prel31(word, place):
    off = word & 0x7FFFFFFF
    if off & 0x40000000:
        off -= 0x80000000
    return (place + off) & 0xFFFFFFFF


def _exidx(path):
    """Sorted (start, descriptor): the inline word or 1 (CANTUNWIND), or ("extab", bytes) for an out-of-line entry."""
    data, secs = _elf_sections(path)
    addr, ex, _ = secs[".ARM.exidx"]
    tab_addr, tab, _ = secs.get(".ARM.extab", (0, b"", None))
    raw = []
    for i in range(len(ex) // 8):
        w0, w1 = struct.unpack_from("<II", ex, i * 8)
        place = addr + i * 8
        raw.append((_prel31(w0, place), w1, _prel31(w1, place + 4)))
    tabs = sorted({t for _, w1, t in raw if not (w1 == 1 or w1 & 0x80000000)})
    ends = dict(zip(tabs, tabs[1:] + [tab_addr + len(tab)]))
    out = []
    for start, w1, t in raw:
        if w1 == 1 or w1 & 0x80000000:
            out.append((start, w1))
        else:
            # Only the size: an LSDA's type-table references are relative to where the table lands.
            out.append((start, ("extab", ends[t] - t)))
    out.sort()
    return out


def _functions(path):
    data, secs = _elf_sections(path)
    _, _, symtab = secs[".symtab"]
    strtab = secs[".strtab"][2]
    out = {}
    for i in range(symtab[5] // 16):
        name_off, value, size, info, _, shndx = struct.unpack_from("<IIIBBH", data, symtab[4] + i * 16)
        if info & 0xF != 2 or size == 0 or shndx == 0:
            continue
        name = data[strtab[4] + name_off:data.index(b"\0", strtab[4] + name_off)].decode(errors="replace")
        out.setdefault(name, []).append((value & ~1, size))
    return {k: v[0] for k, v in out.items() if len(v) == 1}


def _unwind_of(entries, starts, lo, size):
    """The descriptors covering [lo, lo + size), as (offset, descriptor) runs. An address below the first entry has
    none, which the unwinder treats as it does EXIDX_CANTUNWIND (1): the throw fails there."""
    i = bisect.bisect_right(starts, lo) - 1
    runs = [(0, entries[i][1] if i >= 0 else 1)]
    for j in range(max(i + 1, 0), bisect.bisect_left(starts, lo + size)):
        if entries[j][1] != runs[-1][1]:
            runs.append((entries[j][0] - lo, entries[j][1]))
    return runs


def _text_input_sections(map_path):
    """(name, addr, size) of each input section the map places in the .text output section."""
    out, inside, pending = [], False, None
    for line in open(map_path, errors="replace").read().split("\n"):
        if not inside:
            inside = line.startswith(".text ")
            continue
        if line and not line.startswith(" "):
            break
        m = re.match(r"^ (\.text\S*)\s*$", line)
        if m:
            pending = m.group(1)
            continue
        m = re.match(r"^ (\.text\S*)?\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+\S", line)
        if m and (m.group(1) or pending):
            out.append((m.group(1) or pending, int(m.group(2), 16), int(m.group(3), 16)))
        pending = None
    return out


def _order(elf, map_path):
    entries = _exidx(elf)
    starts = [e[0] for e in entries]
    keys = {}
    for name, addr, size in _text_input_sections(map_path):
        if size:
            runs = _unwind_of(entries, starts, addr, size)
            key = runs[0][1] if len(runs) == 1 and isinstance(runs[0][1], int) else None
            keys.setdefault(name, set()).add(key)
    groups = {}
    for name, ks in keys.items():
        # A name shared by several input sections moves all of them, so only when they agree.
        if len(ks) == 1 and None not in ks:
            groups.setdefault(ks.pop(), []).append(name)
    return ["*(%s)" % name for key in sorted(groups) for name in sorted(groups[key])]


def _check(first, second):
    """Every function keeps the unwind entries it had in the first link (a moved one is otherwise unwound wrongly)."""
    a, b = _exidx(first), _exidx(second)
    sa, sb = [e[0] for e in a], [e[0] for e in b]
    fa, fb = _functions(first), _functions(second)
    bad = [n for n in fa if n in fb and _unwind_of(a, sa, *fa[n]) != _unwind_of(b, sb, *fb[n])]
    if bad or set(fa) != set(fb):
        raise SystemExit("exidx_merge: the reordered link changed unwind entries of %s" % (bad[:5] or "the symbol set"))
    return len(a), len(b)


def _ldscript(cmd):
    for i, arg in enumerate(cmd):
        if arg == "-T":
            return i + 1, cmd[i + 1]
        if arg.startswith("-Wl,-T"):
            return None, arg[len("-Wl,-T"):]
    raise SystemExit("exidx_merge: no -T linker script in the link command")


def _find(name, cmd):
    if os.path.isfile(name):
        return name
    for arg in cmd:
        if arg.startswith("-L") and os.path.isfile(os.path.join(arg[2:], name)):
            return os.path.join(arg[2:], name)
    raise SystemExit("exidx_merge: linker script %s not found" % name)


def _link(target, source, env):
    cmd = shlex.split(env.subst(LINKCOM, target=target, source=source))
    idx, script = _ldscript(cmd)
    if idx is None:
        raise SystemExit("exidx_merge: expected `-T SCRIPT` in the link command")
    build = env.subst("$BUILD_DIR")
    elf = str(target[0])
    order = os.path.join(build, "exidx_order.ld")
    text = open(_find(script, cmd)).read()
    anchor = "KEEP(*(.isr_vector))"
    if text.count(anchor) != 1:
        raise SystemExit("exidx_merge: %s has no single %s to order .text after" % (script, anchor))
    merged = os.path.join(build, "exidx_merge.ld")
    with open(merged, "w") as f:
        f.write(text.replace(anchor, '%s\n\t\tINCLUDE "%s"' % (anchor, order)))
    cmd[idx] = merged
    open(order, "w").close()
    first = os.path.join(build, "exidx_first.elf")
    first_map = os.path.join(build, "exidx_first.map")
    # The first link only measures; it may overflow FLASH where the merged one fits.
    pass1 = [first if a == elf else a for a in cmd] + ["-Wl,--noinhibit-exec", "-Wl,-Map=" + first_map]
    if env.Execute(" ".join(shlex.quote(a) for a in pass1)):
        return 1
    lines = _order(first, first_map)
    with open(order, "w") as f:
        f.write("\n".join(lines) + "\n")
    status = env.Execute(" ".join(shlex.quote(a) for a in cmd))
    if status or not os.path.isfile(elf):
        return status or 1
    before, after = _check(first, elf)
    print("exidx_merge: %d sections grouped, .ARM.exidx %d -> %d entries" % (len(lines), before, after))
    return 0


if os.environ.get("WIO_EXIDX_MERGE") != "0":
    LINKCOM = env["LINKCOM"]  # noqa: F821
    env.Replace(LINKCOM=_link)  # noqa: F821

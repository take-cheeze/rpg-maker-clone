#!/usr/bin/env python3
"""Derive an *encrypted* copy of an RPG Maker MZ/MV project, the way the editor's
deployment does.

Real releases very often ship with "Encrypt Images"/"Encrypt Audio" ticked — both
games sampled from freem while testing this path had them on — and an encrypted
project exercises a completely different loading route: the engine XHRs the file
as an ArrayBuffer, decrypts it in its own JavaScript, wraps the plaintext in a
`Blob` and hands the object URL to an `Image`. None of that touches the
filesystem by name, so a host without `Blob`/`URL.createObjectURL` cannot load a
single asset and the boot dies in `Scene_Boot`. See ADR 0004 M6.3r.

The format is simple and unauthenticated — it is obfuscation, not security:

  * the asset keeps its bytes, but gains a **16-byte header**
    `52 50 47 4D 56 00 00 00 00 03 01 00 00 00 00 00` ("RPGMV" + a version), and
  * its **first 16 bytes are XORed** with the 16 bytes of the encryption key
    (`System.json`'s `encryptionKey`, 32 hex characters). Everything after those
    16 bytes is stored as-is.

The extension changes too: MZ appends an underscore (`.png_`, `.ogg_`), MV
renames to `.rpgmvp`/`.rpgmvo`/`.rpgmvm`.

This writes a derived copy rather than committing one: the encrypted bed is
byte-for-byte as large as the plain one, and deriving it keeps a single source of
truth (scripts/gen-mz-sample.py) for what the bed contains.

Usage: gen-mz-encrypted.py <src-project> <dst-project> [--mv]
"""

import json
import os
import shutil
import sys

# "RPGMV" + version, then padding, exactly as the editor writes it.
HEADER = bytes([0x52, 0x50, 0x47, 0x4D, 0x56, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])

# The key the derived project declares. Any 32 hex characters will do — the
# engine reads it straight out of System.json — so this is simply a fixed,
# recognisable one rather than a secret.
KEY_HEX = "d41d8cd98f00b204e9800998ecf8427e"

# What gets encrypted, and what the encrypted file is called. Audio is included
# because the engine takes the same XHR-then-decrypt route for it.
MZ_EXT = {".png": ".png_", ".ogg": ".ogg_", ".m4a": ".m4a_"}
MV_EXT = {".png": ".rpgmvp", ".ogg": ".rpgmvo", ".m4a": ".rpgmvm"}


def encrypt(data, key):
    """Header + the first 16 bytes XORed with the key + the rest verbatim."""
    head = bytearray(data[:16])
    for i in range(min(16, len(head))):
        head[i] ^= key[i]
    return HEADER + bytes(head) + data[16:]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit("usage: gen-mz-encrypted.py <src-project> <dst-project> [--mv]")
    src, dst = args
    ext_map = MV_EXT if "--mv" in sys.argv[1:] else MZ_EXT
    key = bytes.fromhex(KEY_HEX)

    if os.path.exists(dst):
        shutil.rmtree(dst)

    encrypted = 0
    for root, _dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        out_dir = os.path.join(dst, rel) if rel != "." else dst
        os.makedirs(out_dir, exist_ok=True)
        for name in files:
            stem, ext = os.path.splitext(name)
            src_path = os.path.join(root, name)
            # Only img/ and audio/ are encrypted; data/, js/ and fonts/ are
            # copied through, which is what the editor does too.
            top = rel.split(os.sep)[0]
            if ext.lower() in ext_map and top in ("img", "audio"):
                with open(src_path, "rb") as f:
                    blob = encrypt(f.read(), key)
                with open(os.path.join(out_dir, stem + ext_map[ext.lower()]),
                          "wb") as f:
                    f.write(blob)
                encrypted += 1
            else:
                shutil.copy2(src_path, os.path.join(out_dir, name))

    # The flags are what make the engine take the decrypt path at all; without
    # them it would look for the plain names and find nothing.
    sys_path = os.path.join(dst, "data", "System.json")
    with open(sys_path, encoding="utf-8") as f:
        system = json.load(f)
    system["hasEncryptedImages"] = True
    system["hasEncryptedAudio"] = True
    system["encryptionKey"] = KEY_HEX
    with open(sys_path, "w", encoding="utf-8") as f:
        json.dump(system, f, ensure_ascii=False, separators=(",", ":"))
        f.write("\n")

    print("encrypted %d asset(s) into %s" % (encrypted, dst))


if __name__ == "__main__":
    main()

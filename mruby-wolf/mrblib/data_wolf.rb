# Reader for a released WOLF RPG Editor game's packed `Data.wolf` archive --
# the same shape as `RPGXP::RGSSAD` (mruby-rpgxp/mrblib/rgssad.rb, this
# reader's structural template), but for a different container: a released
# game ships its whole `Data/` tree (BasicData, MapData, ...) packed into one
# encrypted `Data.wolf`, rather than as loose files on disk. `Wolf::Project`
# only knew the loose tree before this; see the ADR this file implements
# (docs/adr, search "wolf-rpg-editor-data-wolf") and docs/TODO.md's own
# "Packed releases" entry.
#
# `Data.wolf` is *not* a WOLF-specific format: it is a stock DxLib "DXA"
# archive (dxlib.o.oo7.jp), the same generic packer countless Windows games
# built on DxLib use, XOR-encrypted with a key that differs per editor
# version. This reader is cross-validated line-by-line against the vendored
# DxLib archiver source WolfDec (github.com/Sinflower/WolfDec) ships to
# implement its own decryption, `3rdParty/DXArchive.cpp`/`.h` (only the
# *reading* half -- `OpenArchiveFile`, `LoadFileToMem`, `GetFileInfo`,
# `KeyCreate`/`KeyConv`, `HashCRC32` -- since that half is what real,
# already-released games are decoded by and has years of community use
# behind it; the *encoding* half, `EncodeArchive`/`DirectoryEncode`, has an
# internal inconsistency around whether the outer `DARC_HEAD` struct itself
# is XOR'd, and is not what any real archive was necessarily built by in the
# first place, so it is not treated as authoritative here -- see "Format"
# below for the resolution). `WolfDec`'s own `main.cpp` is also the source of
# the per-editor-version key table (`KNOWN_KEYS` below): WolfDec has no way to
# know which key a given `.wolf` needs either, and brute-forces the same way
# `.open` here does (`detectMode`, trying each key against the file, keeping
# the first that produces sane output).
#
# ## Format
#
# A DXA v8 archive (the version every current WOLF RPG Editor release and
# WolfDec's own default `DXArchive::DecodeArchive` writes/reads; the older
# v2.x editor releases use a structurally different DXA v5/v6 container
# WolfDec keeps separate reader classes for, `DXArchiveVer5`/`Ver6` --
# out of scope here, see "Scope" below) is:
#
#   `DARC_HEAD` (64 bytes, plain -- see below) | name table | file table |
#   directory table | file data
#
# `DARC_HEAD` carries a "DX" tag, a version (must be 8), a `HeadSize` (the
# combined byte length of the three tables that follow it), `DataStartAddress`
# (where file data begins, file-start-relative), `FileNameTableStartAddress`
# (where the name table begins, file-start-relative -- the file and directory
# tables are stored back-to-back right after it), `FileTableStartAddress` and
# `DirectoryTableStartAddress` (both relative to the name table's own start),
# and a `Flags` word. Two flags matter here: `NO_KEY` (no XOR anywhere) and
# `NO_HEAD_PRESS` ("the three tables are stored as-is" -- unset means they are
# instead Huffman+LZ compressed, which this reader does not implement; see
# "Scope"). Unlike every other field in the archive, `DARC_HEAD` itself is
# read completely plain: WolfDec's own `OpenArchiveFile` (the tested,
# community-used reader) `fread`s it straight into the struct and checks the
# "DX" tag with no decryption step at all, even though its sibling
# `EncodeArchive`/`DirectoryEncode` (the writer half, see above) XORs it with
# the archive key on the way out -- an inconsistency in that vendored source,
# not a choice made here. This reader follows the reader: `DARC_HEAD`'s own
# fields (including the two table-start offsets used for the plausibility
# check `.open` picks a key with) never need a key to read, exactly as real,
# already-released games are successfully unpacked today.
#
# The name/file/directory tables that follow, by contrast, ARE one combined
# XOR-encrypted block (keyed from `KeyCreate` of the archive's own key string,
# cycling a 7-byte derived key from byte position 0 of the block). Directory
# entries (`DARC_DIRECTORY`: this directory's own file-table run --
# `FileHeadNum`/`FileHeadAddress` -- plus book-keeping this reader does not
# need, see below) and file-header entries (`DARC_FILEHEAD`: name address,
# Windows-style attributes, a data address/size, and two "compressed size"
# fields that read `0xFFFF_FFFF_FFFF_FFFF` when the entry is stored as-is)
# form a tree the same shape a filesystem does; each name-table entry stores
# both an upper-cased copy of the name (used only for the per-file key below)
# and the original-case one this reader returns as the path.
#
# Each file's *data* is separately XOR'd with its own key -- not the archive
# key, but `KeyCreate` of the archive key string followed by the file's own
# upper-cased name and then its containing directory's, its parent's, and so
# on up to (but not including) the root's -- and the byte position the XOR
# key stream starts cycling from is the entry's own `DataSize`, not its
# offset (`LoadFileToMem`'s own `KeyConvFileRead(Buffer, FileH->DataSize, fp,
# lKey, FileH->DataSize)` -- the position argument really is the size field
# a second time, not a copy-paste of the address one; matched here exactly
# since a real archive's bytes depend on it). `#walk_directory` computes that
# per-file key by carrying the ancestor chain down through the same recursion
# that finds each file (nearest ancestor first, as the leaf is reached) rather
# than DXArchive.cpp's own up-the-tree walk through `ParentDirectoryAddress`
# starting back at each leaf -- both visit the exact same path from a file to
# the root and so produce an identical key, but the down-the-tree order means
# this reader never needs `ParentDirectoryAddress`/`DirectoryAddress` at all
# (`.pack`, the writer below, still fills them in for a structurally faithful
# archive, just as unused input for a real DXA reader would be).
#
# CRC32 (`KeyCreate`'s own step, and so every key this file ever derives)
# is standard CRC-32/ISO-HDLC (poly 0xEDB88320, reflected, init/final
# 0xFFFFFFFF) -- verified against the textbook check value ("123456789" ->
# 0xCBF43926) in the unit tests, independently of anything WOLF- or
# DXA-specific.
#
# ## Scope
#
# Two things this reader deliberately does not attempt, refusing with a clear
# error rather than mis-parsing, the same "detect and refuse" discipline
# `Wolf::Crypt.protected?`/`.decrypt_protected` already applies to whichever
# Pro-protected *file* sub-schemes are not implemented (see
# wolf_crypt_pro.rb's file header):
#
#   * A compressed **table** (`NO_HEAD_PRESS` unset) *is* decoded --
#     `.huffman_decode`/`.dxa_lz_decode` below port DxLib's own
#     `Huffman_Decode`/`DXArchive::Decode`. This turned out not to be a
#     hypothetical: the expectation this reader originally shipped with (that
#     `Data.wolf` itself would skip DXA's own redundant compression, since
#     WOLF's own asset formats are already independently LZ4-compressed at
#     the *content* layer -- `Wolf::LZ4`, wolf.rb -- before ever reaching the
#     archive) was wrong, discovered by pointing this reader at a real,
#     freely-distributable released game's own `Data.wolf` rather than only
#     this repo's own round-trip fixture (`.pack` always writes an
#     uncompressed table, so `scripts/wolf_data_wolf_check.rb`'s round trip
#     alone could never have exercised this path). A compressed **file
#     entry** (`PressDataSize`/`HuffPressDataSize` not the "uncompressed"
#     sentinel) is still refused with a clear error rather than mis-parsed:
#     no real archive's own individual files have been seen using it yet
#     (consistent with the LZ4-at-the-content-layer reasoning above still
#     holding for file *data*, just not for the header table), so there is
#     nothing to cross-validate a decoder against.
#   * Pro-protected **data.wolf containers** are not a thing distinct from
#     Pro-protected *files*: Pro protection (byte 1 == 0x50) is a separate
#     AES scheme applied to individual `Data/` files' own bytes, wholly
#     independent of the DXA container they may or may not be packed into --
#     `WolfTL`'s own `WolfDxArcKey.hpp` derives a *DXA* key from a Pro-
#     protected `Game.dat`'s bytes, i.e. the container is still plain DXA even
#     for a Pro-protected release. So this reader does not special-case
#     protection at all: it decodes the DXA container exactly the same either
#     way, and `Wolf::Project#read`'s callers already run every file through
#     the *same* `Wolf.open_envelope`/`Crypt.decrypt_protected` gate the
#     loose-tree path always has (`data.rb`'s `GameDat`/`Database`/
#     `CommonEvents`/`Map` parsers, `Wolf.open_envelope`) -- a Pro-protected
#     packed release is decrypted (v3.5) or refused (v3.1/v3.3) at exactly
#     the same place a loose-tree one already is, with no separate detection
#     needed here.
#
# Also out of scope: the older DXA v5/v6 container the 2.0x editor releases
# used (`DXArchiveVer5`/`Ver6` in WolfDec, structurally different from v8
# above) -- `KNOWN_KEYS` below only covers the v8-format entries from
# WolfDec's own key table (2.281 and later, the format every 3.x release
# including the bundled sample game's own 3.724 uses).
module Wolf
  class DataWolf
    VERSION = 8
    FLAG_NO_KEY = 0x0000_0001
    FLAG_NO_HEAD_PRESS = 0x0000_0002
    KEY_BYTES = 7
    KEY_STRING_MAX = 63
    FILE_ATTRIBUTE_DIRECTORY = 0x10
    DARC_HEAD_SIZE = 64
    FILEHEAD_SIZE = 72
    DIRECTORY_SIZE = 32
    # PressDataSize/HuffPressDataSize's "not compressed" sentinel, and
    # DARC_DIRECTORY's "no parent" one -- both 0xFFFF_FFFF_FFFF_FFFF, DXA's
    # 64-bit -1. Spelled as `2**64 - 1` rather than the literal so nothing
    # here depends on how big an unsuffixed hex literal mruby's compiler pool
    # allows (see rgssad.rb's own MASK for the 32-bit version of this).
    SENTINEL64 = (2**64) - 1
    # DxLib's own fallback key string when a caller supplies none at all
    # ("DXBDXARC" as raw bytes -- not the "DXLIBARC" the vendor source's own
    # comment claims, but the literal bytes `KeyCreate`'s 4-byte-minimum pad
    # uses; harmless here since every `KNOWN_KEYS` entry is already well over
    # 4 bytes, but kept for fidelity to `KeyCreate`'s pad branch).
    DEFAULT_KEY_STRING = Wolf.bin([0x44, 0x58, 0x42, 0x44, 0x58, 0x41, 0x52, 0x43].pack("C*"))

    # The per-editor-version DXA keys WolfDec's own `main.cpp` tries in turn
    # (`DECRYPT_MODES`) -- only the entries whose `decFunc` is the plain
    # `DXArchive::DecodeArchive` (the v8 format above); the v5/v6 entries
    # (2.01/2.10/2.20) are a different container, out of scope (see the file
    # header). Each byte string already excludes the literal trailing 0x00
    # WolfDec's own table pads every entry with for its `KeyString_ const
    # char*` / `CL_strlen` call -- `KeyCreate` only ever sees the bytes before
    # it either way, so it is dropped here rather than reproduced.
    KNOWN_KEYS = [
      # Wolf RPG v2.281
      Wolf.bin("WLFRPrO!p(;s5((8P@((UFWlu$#5(="),
      # Wolf RPG v3.10
      Wolf.bin([0x0F, 0x53, 0xE1, 0x3E, 0x8E, 0xB5, 0x41, 0x91, 0x52, 0x16, 0x55, 0xAE, 0x34, 0xC9,
                0x8F, 0x79, 0x59, 0x2F, 0x59, 0x6B, 0x95, 0x19, 0x9B, 0x1B, 0x35, 0x9A, 0x2F, 0xDE,
                0xC9, 0x7C, 0x12, 0x96, 0xC3, 0x14, 0xB5, 0x0F, 0x53, 0xE1, 0x3E, 0x8E].pack("C*")),
      # Wolf RPG v3.173 (the newest documented key; covers the bundled sample
      # game's own 3.724 and every other current 3.x release)
      Wolf.bin([0x31, 0xF9, 0x01, 0x36, 0xA3, 0xE3, 0x8D, 0x3C, 0x7B, 0xC3, 0x7D, 0x25, 0xAD, 0x63,
                0x28, 0x19, 0x1B, 0xF7, 0x8E, 0x6C, 0xC4, 0xE5, 0xE2, 0x76, 0x82, 0xEA, 0x4F, 0xED,
                0x61, 0xDA, 0xE0, 0x44, 0x5B, 0xB6, 0x46, 0x3B, 0x06, 0xD5, 0xCE, 0xB6, 0x78, 0x58,
                0xD0, 0x7C, 0x82].pack("C*")),
      # One Way Heroics
      Wolf.bin("nGui9('&1=@3#a"),
      # One Way Heroics Plus
      Wolf.bin("Ph=X3^]o2A(,1=@3#a")
    ].freeze

    # Max per-byte-Array size held while XOR-cycling or building name-table
    # bytes, kept under mruby's MRB_ARY_LENGTH_MAX (131072) the same way
    # rgssad.rb's own DECRYPT_CHUNK does, for the same reason: a real archive's
    # combined header table (or a single large file) is well past that cap.
    CHUNK = 65536

    # Little-endian byte multipliers for 4- and 8-byte fields, so integers are
    # assembled/read without bit-shifting (rgssad.rb's own POW, extended to 8
    # bytes for DXA's 64-bit offsets/sizes).
    POW4 = (0..3).map { |i| 256**i }.freeze
    POW8 = (0..7).map { |i| 256**i }.freeze

    # The archive path for a game directory (`Data.wolf`), or nil when the
    # project is unpacked. Mirrors `RPGXP::RGSSAD.find`.
    def self.find(game_dir)
      path = "#{game_dir}/Data.wolf"
      File.exist?(path) ? path : nil
    end

    # Opens the archive for streaming, seekable reads (see #initialize)
    # rather than reading it whole -- the same PSP-memory-budget reasoning
    # rgssad.rb's own .open documents (docs/adr/0047-psp-memory-budget.md
    # Finding 2): a released game's `Data.wolf` packs every map, chipset and
    # character sheet into one file, easily past the PSP's whole RAM budget.
    def self.open(path)
      new(File.open(path, "rb"))
    end

    # `data` is either a `String` of the whole archive (wrapped in a
    # `StringIO`, as rgssad.rb's own `.new` does) or an IO-like object already
    # open for reading (what `.open` passes). `key_string:` forces one exact
    # editor-version key (bytes, not a `KNOWN_KEYS` index) instead of trying
    # `KNOWN_KEYS` in turn -- mainly for tests that need a specific key
    # exercised regardless of which one a plausibility check would pick.
    def initialize(data, key_string: nil)
      @io = data.is_a?(String) ? StringIO.new(data) : data
      @io.seek(0)
      raw_head = @io.read(DARC_HEAD_SIZE)
      if raw_head.nil? || raw_head.bytesize < DARC_HEAD_SIZE
        raise Error, "Data.wolf: truncated header"
      end
      unless raw_head.getbyte(0) == 0x44 && raw_head.getbyte(1) == 0x58 # "DX"
        raise Error, "Data.wolf: not a DXA archive (bad header)"
      end
      version = self.class.u16_at(raw_head, 2)
      unless version == VERSION
        raise Error, "Data.wolf: unsupported DXA version #{version} " \
                     "(only version #{VERSION}, the current WOLF RPG Editor " \
                     "release format, is supported)"
      end

      @head_size = self.class.u32_at(raw_head, 4)
      @data_start = self.class.u64_at(raw_head, 8)
      name_table_start = self.class.u64_at(raw_head, 16)
      @file_table_start = self.class.u64_at(raw_head, 24)
      @dir_table_start = self.class.u64_at(raw_head, 32)
      flags = self.class.u32_at(raw_head, 44)
      @no_key = (flags & FLAG_NO_KEY) != 0
      no_head_press = (flags & FLAG_NO_HEAD_PRESS) != 0

      # `name_table_start` is one of `DARC_HEAD`'s own supposedly-plain
      # fields (see the file header's "Format"); a huge, clearly-bogus value
      # here means this archive was not built the way this reader (matching
      # the vendored WolfDec reference) expects `DARC_HEAD` to be laid out --
      # seen in the wild on at least one current, real released game whose
      # own `Game.exe` bundles a `DxArchive_WOLF_MOD_security.cpp`-derived
      # archiver rather than the stock DxLib one, per Sinflower/UberWolf's
      # own newer "WolfX" reverse-engineering effort (a large, still
      # actively-updated per-release magic-value table this reader does not
      # attempt to port -- see docs/TODO.md's own "Packed releases" entry).
      # Caught here as a clear, named error rather than a raw `Errno::EINVAL`
      # from seeking to nonsense.
      if name_table_start > (1 << 48)
        raise Error, "Data.wolf: DARC_HEAD's own table offsets look bogus " \
                     "(name table at #{name_table_start}) -- this archive " \
                     "was likely built by a WOLF-specific modified DxArchive " \
                     "this reader does not yet support, not the stock DxLib " \
                     "one (see the file header's \"Scope\")"
      end

      @io.seek(name_table_start)
      if no_head_press
        raw_table = @io.read(@head_size)
        if raw_table.nil? || raw_table.bytesize < @head_size
          raise Error, "Data.wolf: truncated name/file/directory table"
        end
      else
        # Compressed header (see the file header's "Scope" -- real released
        # games do take this path, not just the uncompressed one this reader
        # originally assumed). The compressed blob runs from here to EOF
        # (OpenArchiveFile's own `HuffHeadSize = FileSize - ftell(...)`);
        # `@head_size` itself still holds the true *uncompressed* size either
        # way (DXArchive.cpp's own encoder sets it before compressing), used
        # below both as the Huffman decode's expected size and as a cheap
        # per-key plausibility gate before committing to a full decode.
        raw_table = @io.read
        if raw_table.nil? || raw_table.empty?
          raise Error, "Data.wolf: truncated compressed name/file/directory table"
        end
      end

      @key_string, @key, blob = find_key(raw_table, key_string, !no_head_press)

      @entries = {}
      walk_directory(blob, 0, "", [])
    end

    attr_reader :key_string

    # Entry paths present in the archive ('/'-separated, original case).
    def names
      @entries.keys
    end

    def include?(name)
      @entries.key?(name)
    end

    # An entry's decoded byte size without reading it -- a plain Hash lookup,
    # not I/O (mirrors rgssad.rb's own #entry_size). nil when absent.
    def entry_size(name)
      e = @entries[name]
      e && e[:size]
    end

    # Decrypted bytes for one entry, or nil when it is not in the archive.
    # Raises if the entry is stored compressed (see the file header's
    # "Scope"). Seeks to the entry's own offset and reads only its own bytes
    # -- the archive is never loaded whole (see .open/#initialize).
    def read(name)
      e = @entries[name]
      return nil unless e
      if e[:compressed]
        raise Error, "Data.wolf: #{name} is stored compressed; " \
                     "compressed DXA entries are not supported"
      end
      return Wolf.bin("") if e[:size] == 0
      @io.seek(@data_start + e[:address])
      bytes = @io.read(e[:size])
      return nil if bytes.nil? || bytes.bytesize < e[:size]
      return bytes if e[:key].nil?
      # The XOR key stream's own cycling position is the entry's DataSize,
      # not its address -- see the file header's "Format" note; matched
      # exactly since it changes which of the 7 key bytes byte 0 starts at.
      self.class.xor_cycle(bytes, e[:key], e[:size])
    end

    # Build a version-8 DXA archive from `files`, a list of [path, bytes]
    # pairs (path '/'-separated, e.g. "BasicData/Game.dat"). The inverse of
    # the reader above -- used as the fixture builder for the archive tests,
    # the same role rgssad.rb's own .pack_v1/.pack_v3 play for RGSSAD, since
    # no real `Data.wolf` fixture is available to test against (see the file
    # header's "Scope").
    def self.pack(files, key_string: KNOWN_KEYS[2], no_key: false)
      key_bytes = no_key ? nil : truncate_key(key_string)
      key = key_bytes && key_create(key_bytes)

      root = { name: Wolf.bin(""), dirs: [], files: [], parent: nil }
      files.each do |path, bytes|
        parts = split_path(path)
        node = root
        parts[0..-2].each do |seg|
          child = node[:dirs].find { |d| d[:name] == seg }
          unless child
            child = { name: seg, dirs: [], files: [], parent: node }
            node[:dirs] << child
          end
          node = child
        end
        node[:files] << [parts[-1], bytes]
      end

      # Assign directory ids by a breadth-first walk (root = 0) so every
      # DIRECTORY-typed DARC_FILEHEAD's DataAddress (its own directory
      # record's offset) is known before any table bytes are written.
      dir_list = [root]
      queue = [root]
      until queue.empty?
        d = queue.shift
        d[:dirs].each do |c|
          dir_list << c
          queue << c
        end
      end
      dir_list.each_with_index { |d, i| d[:id] = i }

      name_table = Wolf.bin(+"")
      file_table = Wolf.bin(+"")
      data_parts = []
      data_cursor = 0

      dir_list.each do |d|
        children = d[:dirs].map { |c| { name: c[:name], dir: c } } +
                   d[:files].map { |n, b| { name: n, dir: nil, bytes: b } }
        d[:file_head_addr] = file_table.bytesize
        d[:file_head_num] = children.size
        children.each do |ch|
          name_addr = name_table.bytesize
          name_table << encode_name_entry(ch[:name])
          if ch[:dir]
            data_address = ch[:dir][:id] * DIRECTORY_SIZE
            file_table << filehead_bytes(name_addr, FILE_ATTRIBUTE_DIRECTORY,
                                          data_address, 0, SENTINEL64, SENTINEL64)
          else
            data_address = data_cursor
            size = ch[:bytes].bytesize
            fkey = key && key_create(key_bytes + upper_name_bytes(ch[:name]) + ancestor_upper_names(d))
            enc = fkey ? xor_cycle(ch[:bytes], fkey, size) : ch[:bytes]
            data_parts << enc
            data_cursor += size
            file_table << filehead_bytes(name_addr, 0, data_address, size, SENTINEL64, SENTINEL64)
          end
        end
      end

      dir_table = Wolf.bin(+"")
      dir_list.each do |d|
        parent_addr = d[:parent] ? d[:parent][:id] * DIRECTORY_SIZE : SENTINEL64
        dir_table << dir_record_bytes(0, parent_addr, d[:file_head_num], d[:file_head_addr])
      end

      head_size = name_table.bytesize + file_table.bytesize + dir_table.bytesize
      file_table_start = name_table.bytesize
      dir_table_start = name_table.bytesize + file_table.bytesize
      name_table_start = DARC_HEAD_SIZE
      data_start = DARC_HEAD_SIZE + head_size

      flags = FLAG_NO_HEAD_PRESS
      flags |= FLAG_NO_KEY if no_key
      head = darc_head_bytes(head_size, data_start, name_table_start,
                              file_table_start, dir_table_start, flags)

      table_blob = name_table + file_table + dir_table
      table_blob = xor_cycle(table_blob, key, 0) if key

      head + table_blob + data_parts.join
    end

    private

    # Try each candidate editor-version key (or the one exact key
    # `key_string:` forced) against the raw table bytes, keeping the first
    # whose decrypted root directory record looks like a real one --
    # `WolfDec`'s own `main.cpp` has no better way to pick either (see the
    # file header). `compressed` is whether `raw_table` still needs the
    # Huffman+LZ decode below (see #initialize) before it is a real table.
    # Returns [key_string_bytes_or_nil, derived_key_or_nil, decoded_table].
    # Raises if nothing plausible turns up.
    def find_key(raw_table, key_string, compressed)
      if @no_key
        blob = compressed ? decompress_table(raw_table) : raw_table
        return [nil, nil, blob]
      end

      candidates = key_string ? [self.class.truncate_key(key_string)] : KNOWN_KEYS
      candidates.each do |ks|
        key = self.class.key_create(ks)
        decrypted = self.class.xor_cycle(raw_table, key, 0)
        if compressed
          # A wrong key turns the Huffman size prefix into noise -- possibly
          # a huge 64-bit value -- so this checks the cheap size-only prefix
          # (a handful of bit reads, see .huffman_decoded_size) before ever
          # committing to a full Huffman+LZ decode of the candidate. That
          # prefix is the size of the *LZ-compressed* intermediate (Huffman's
          # own immediate input, see `.decompress_table`'s ordering) rather
          # than the final table's -- not `@head_size` itself, which is only
          # known once the table is fully decoded -- so this is a generous
          # sanity bound tied to it (real archives don't inflate anywhere
          # near this much at the LZ stage) rather than an exact check; the
          # final blob's own size against `@head_size`, and the same
          # #plausible? check the uncompressed path uses, are what actually
          # confirm the key below.
          lz_size = self.class.huffman_decoded_size(decrypted)
          next if lz_size <= 0 || lz_size > @head_size * 4 + 4096
          blob = decompress_table(decrypted)
          next unless blob.bytesize == @head_size
        else
          blob = decrypted
        end
        return [ks, key, blob] if plausible?(blob)
      end
      raise Error, "Data.wolf: could not decrypt the archive header with " \
                   "any known editor-version key (#{candidates.size} tried); " \
                   "a Pro-protected release still uses a plain DXA container " \
                   "(see the file header), so this means the key table itself " \
                   "is missing this game's editor version"
    end

    # The name/file/directory table, Huffman-decoded then LZ-decoded (see the
    # file header's "Format" -- `DXArchive::OpenArchiveFile`'s own order for
    # a compressed header). `bytes` is already XOR-decrypted.
    def decompress_table(bytes)
      self.class.dxa_lz_decode(self.class.huffman_decode(bytes))
    end

    # A cheap, non-cryptographic sanity check on a candidate decryption of the
    # root directory record: does its child count and file-table span look
    # like real data rather than the noise a wrong key produces? `DARC_HEAD`'s
    # own table-start offsets are always plain (see the file header), so only
    # the *decrypted* fields here depend on having picked the right key.
    def plausible?(blob)
      return false if @dir_table_start + DIRECTORY_SIZE > blob.bytesize
      file_head_num = self.class.u64_at(blob, @dir_table_start + 16)
      file_head_addr = self.class.u64_at(blob, @dir_table_start + 24)
      return false if file_head_num > 200_000
      span = @file_table_start + file_head_addr + file_head_num * FILEHEAD_SIZE
      return false if span > blob.bytesize
      return true if file_head_num == 0

      first = @file_table_start + file_head_addr
      name_addr = self.class.u64_at(blob, first)
      attrs = self.class.u64_at(blob, first + 8)
      return false if name_addr + 4 > blob.bytesize
      return false if attrs >= 0x1_0000
      pack_num = self.class.u16_at(blob, name_addr)
      pack_num <= blob.bytesize / 4
    end

    # Recursively flattens the directory tree (`blob` is the already-
    # decrypted name/file/directory table) into `@entries`, a flat path =>
    # {address:, size:, compressed:, key:} Hash -- rgssad.rb's own
    # `@entries` shape. `dir_offset` is this directory's own record's byte
    # offset within the directory table (0 for root); `ancestors` is the
    # upper-cased name of every directory from this one's *parent* up to
    # (not including) the root, nearest first -- see the file header's
    # "Format" for why this is the down-the-tree equivalent of DXArchive.cpp's
    # own up-the-tree `CreateKeyFileString` walk.
    def walk_directory(blob, dir_offset, path_prefix, ancestors)
      dir_addr = @dir_table_start + dir_offset
      file_head_num = self.class.u64_at(blob, dir_addr + 16)
      file_head_addr = self.class.u64_at(blob, dir_addr + 24)
      base = @file_table_start + file_head_addr

      i = 0
      while i < file_head_num
        fh = base + i * FILEHEAD_SIZE
        name_addr = self.class.u64_at(blob, fh)
        attrs = self.class.u64_at(blob, fh + 8)
        data_address = self.class.u64_at(blob, fh + 40)
        data_size = self.class.u64_at(blob, fh + 48)
        press_size = self.class.u64_at(blob, fh + 56)
        huff_size = self.class.u64_at(blob, fh + 64)
        upper_name, orig_name = self.class.read_name_entry(blob, name_addr)

        path = path_prefix.empty? ? orig_name : "#{path_prefix}/#{orig_name}"
        if (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0
          walk_directory(blob, data_address, path, [upper_name] + ancestors)
        else
          fkey = @key && self.class.key_create(@key_string + upper_name + ancestors.join)
          @entries[path] = {
            address: data_address,
            size: data_size,
            compressed: press_size != SENTINEL64 || huff_size != SENTINEL64,
            key: fkey
          }
        end
        i += 1
      end
    end

    # ---- shared byte-level helpers (used by both the reader and .pack) ----

    def self.u16_at(s, i)
      s.getbyte(i) + s.getbyte(i + 1) * 256
    end

    def self.u32_at(s, i)
      v = 0
      j = 0
      while j < 4
        v += s.getbyte(i + j) * POW4[j]
        j += 1
      end
      v
    end

    def self.u64_at(s, i)
      v = 0
      j = 0
      while j < 8
        v += s.getbyte(i + j) * POW8[j]
        j += 1
      end
      v
    end

    def self.u16_bytes(v)
      Wolf.bin([v % 256, (v / 256) % 256].pack("C*"))
    end

    def self.u32_bytes(v)
      b = []
      j = 0
      while j < 4
        b << (v / POW4[j]) % 256
        j += 1
      end
      Wolf.bin(b.pack("C*"))
    end

    def self.u64_bytes(v)
      b = []
      j = 0
      while j < 8
        b << (v / POW8[j]) % 256
        j += 1
      end
      Wolf.bin(b.pack("C*"))
    end

    # ---- compressed-header decode (DxLib's own Huffman + custom LZ) ----
    #
    # Ported from `Huffman.cpp`'s `Huffman_Decode` and `DXArchive.cpp`'s
    # `DXArchive::Decode` (see the file header's "Format"/"Scope") -- the
    # two-stage decompression a real released game's `Data.wolf` header table
    # needs whenever `NO_HEAD_PRESS` is unset. Deliberately decode-only: this
    # reader never *writes* a compressed header (`.pack` below always sets
    # `NO_HEAD_PRESS`, a spec-valid choice a real DXA reader accepts fine),
    # so `Huffman_Encode`/`DirectoryEncode`'s own compression path is not
    # ported.
    #
    # Reads `n` bits (MSB-first, matching `Huffman.cpp`'s own `BIT_STREAM`)
    # from `bytes` starting at zero-based bit offset `pos`, without requiring
    # `pos` to be byte-aligned. Returns `[value, pos + n]` so callers thread
    # the position through a sequence of reads the same way `BitStream_Read`
    # advances its own cursor.
    def self.bits_read(bytes, pos, n)
      v = 0
      i = 0
      while i < n
        bit_pos = pos + i
        byte = bytes.getbyte(bit_pos / 8) || 0
        bit = (byte >> (7 - bit_pos % 8)) & 1
        v = (v << 1) | bit
        i += 1
      end
      [v, pos + n]
    end

    # Just the compressed blob's own claimed *uncompressed* size, without
    # decoding the rest of the stream (the frequency table and the compressed
    # bits themselves) -- the first two `BitStream_Read` calls
    # `Huffman_Decode(Src, NULL)` itself would do to answer the same
    # question. Used by `#find_key`'s per-candidate-key gate: cheap enough to
    # try for every `KNOWN_KEYS` entry, unlike a full decode of a stream a
    # wrong key has turned to noise (whose *own* claimed size could be
    # anything up to 2**64-1).
    def self.huffman_decoded_size(bytes)
      size_bits, pos = bits_read(bytes, 0, 6)
      original_size, = bits_read(bytes, pos, size_bits + 1)
      original_size
    end

    # Full Huffman decode: rebuilds the same 511-node tree `Huffman_Encode`
    # built from the per-byte-value frequency table stored in the stream
    # (256 signed differences from the previous entry, `Weight[0]` on its
    # own), then walks it root-to-leaf one output byte at a time. Skips
    # `Huffman_Decode`'s own `NodeIndexTable` (a 9-bit lookup table purely for
    # decode speed in the original C++) in favor of the plain bit-by-bit walk
    # `Huffman_Decode` itself falls back to for a stream's last 17 bytes --
    # both visit the exact same tree edges for the exact same output, so the
    # lookup table's absence changes nothing but how many bits are read one
    # at a time.
    def self.huffman_decode(bytes)
      size_bits, pos = bits_read(bytes, 0, 6)
      original_size, pos = bits_read(bytes, pos, size_bits + 1)
      press_bits, pos = bits_read(bytes, pos, 6)
      _press_size, pos = bits_read(bytes, pos, press_bits + 1)

      weight = Array.new(256, 0)
      prev = 0
      i = 0
      while i < 256
        diff_bits, p1 = bits_read(bytes, pos, 3)
        diff_bits = (diff_bits + 1) * 2
        minus, p2 = bits_read(bytes, p1, 1)
        diff, p3 = bits_read(bytes, p2, diff_bits)
        pos = p3
        prev = minus == 1 ? (prev - diff) & 0xffff : (prev + diff) & 0xffff
        weight[i] = prev
        i += 1
      end

      # Repeatedly merge the two lowest-weight not-yet-merged nodes (linear
      # scan, first-found-wins on ties) into a new node, same as
      # `Huffman_Encode` itself does to build the tree it assigned codes
      # from -- this must reproduce that exact tree, not just any valid one,
      # since the bits in the stream were chosen against it.
      node_weight = Array.new(511, 0)
      child = Array.new(511) { [-1, -1] }
      parent = Array.new(511, -1)
      i = 0
      while i < 256
        node_weight[i] = weight[i]
        i += 1
      end

      data_num = 256
      node_num = 256
      while data_num > 1
        min1 = -1
        min2 = -1
        idx = 0
        seen = 0
        while seen < data_num
          if parent[idx] == -1
            seen += 1
            if min1 == -1 || node_weight[min1] > node_weight[idx]
              min2 = min1
              min1 = idx
            elsif min2 == -1 || node_weight[min2] > node_weight[idx]
              min2 = idx
            end
          end
          idx += 1
        end
        node_weight[node_num] = node_weight[min1] + node_weight[min2]
        child[node_num] = [min1, min2]
        parent[min1] = node_num
        parent[min2] = node_num
        node_num += 1
        data_num -= 1
      end

      root = 510
      out = Wolf.bin("\x00" * original_size)
      # The compressed *payload* (unlike the header fields/weight table just
      # above) is not more `BIT_STREAM`/`BitStream_Read` -- `Huffman_Encode`
      # packs it with a separate, simpler bit writer (`PressData[...] |=
      # (BitData & 1) << PressBitCounter`, `BitData >>= 1` each step): LSB-
      # first within each byte rather than MSB-first, and always starting at
      # a fresh byte boundary right after the header (`HeadSize` itself is
      # `BitStream_GetBytes`, i.e. already rounded up past the header's own
      # last partial byte) rather than continuing mid-byte from `pos`.
      byte_pos = (pos + 7) / 8
      cur_byte = bytes.getbyte(byte_pos) || 0
      bit_counter = 0
      n = 0
      while n < original_size
        node = root
        while node > 255
          if bit_counter == 8
            byte_pos += 1
            cur_byte = bytes.getbyte(byte_pos) || 0
            bit_counter = 0
          end
          bit = cur_byte & 1
          cur_byte >>= 1
          bit_counter += 1
          node = child[node][bit]
        end
        out.setbyte(n, node)
        n += 1
      end
      out
    end

    # `DXArchive::Decode`'s custom LZ77-family decoder, for the LZ-compressed
    # (post-Huffman-decode) stream: a plain byte is copied through as-is; a
    # run of the stream's own "key" byte value repeated twice copies one
    # literal key byte through; any other `key, code` pair is a back-
    # reference (`code` packs a length nibble/extra-length-byte and a
    # 1/2/3-byte distance, `MIN_COMPRESS` == 4 added back to the length since
    # the encoder subtracted it to fit more lengths in fewer bits). The
    # `index < conbo` branch is a self-overlapping copy (the referenced run
    # extends past the position being written), expanded by doubling the
    # already-copied span each pass -- exactly `Decode`'s own loop, not a
    # generic `memcpy` (which would corrupt an overlapping copy that way).
    def self.dxa_lz_decode(bytes)
      dest_size = u32_at(bytes, 0)
      src_size = u32_at(bytes, 4) - 9
      keycode = bytes.getbyte(8)

      out = Wolf.bin("\x00" * dest_size)
      sp = 9
      dp = 0
      while src_size > 0
        b = bytes.getbyte(sp)
        if b != keycode
          out.setbyte(dp, b)
          dp += 1
          sp += 1
          src_size -= 1
          next
        end

        if bytes.getbyte(sp + 1) == keycode
          out.setbyte(dp, keycode)
          dp += 1
          sp += 2
          src_size -= 2
          next
        end

        code = bytes.getbyte(sp + 1)
        code -= 1 if code > keycode # undo the encoder's +1 keycode dodge
        sp += 2
        src_size -= 2

        conbo = code >> 3
        if (code & 0x4) != 0
          conbo |= bytes.getbyte(sp) << 5
          sp += 1
          src_size -= 1
        end
        conbo += 4 # MIN_COMPRESS

        index_size = code & 0x3
        case index_size
        when 0
          index = bytes.getbyte(sp)
          sp += 1
          src_size -= 1
        when 1
          index = u16_at(bytes, sp)
          sp += 2
          src_size -= 2
        else
          index = u16_at(bytes, sp) | (bytes.getbyte(sp + 2) << 16)
          sp += 3
          src_size -= 3
        end
        index += 1

        if index < conbo
          num = index
          while conbo > num
            i = 0
            while i < num
              out.setbyte(dp + i, out.getbyte(dp - num + i))
              i += 1
            end
            dp += num
            conbo -= num
            num += num
          end
          if conbo != 0
            i = 0
            while i < conbo
              out.setbyte(dp + i, out.getbyte(dp - num + i))
              i += 1
            end
            dp += conbo
          end
        else
          i = 0
          while i < conbo
            out.setbyte(dp + i, out.getbyte(dp - index + i))
            i += 1
          end
          dp += conbo
        end
      end
      out
    end

    # 32-bit XOR of two (possibly bignum-range) integers via byte-wise `^` --
    # each byte pair is 0..255, always plain-fixnum-safe, so no bitwise
    # operator here ever touches a value outside that range (see rgssad.rb's
    # own "no bignum bitwise operators" note; CRC32's own working value
    # routinely exceeds mruby's 32-bit `mrb_int`, per build_config.rb).
    def self.xor32(a, b)
      r = 0
      i = 0
      while i < 4
        r += (((a / POW4[i]) % 256) ^ ((b / POW4[i]) % 256)) * POW4[i]
        i += 1
      end
      r
    end

    # Standard CRC-32/ISO-HDLC (poly 0xEDB88320, reflected, init/final
    # 0xFFFFFFFF) -- the same table-driven algorithm DXArchive.cpp's own
    # HashCRC32 uses, verified independently against the textbook check value
    # in the unit tests ("123456789" -> 0xCBF43926).
    def self.build_crc32_table
      (0...256).map do |i|
        data = i
        j = 0
        while j < 8
          bit = data % 2
          data /= 2
          data = xor32(data, 0xEDB8_8320) if bit == 1
          j += 1
        end
        data
      end
    end
    CRC32_TABLE = build_crc32_table.freeze

    def self.crc32(bytes)
      crc = 0xFFFF_FFFF
      i = 0
      n = bytes.bytesize
      while i < n
        idx = (crc % 256) ^ bytes.getbyte(i)
        crc = xor32(CRC32_TABLE[idx], crc / 256)
        i += 1
      end
      xor32(crc, 0xFFFF_FFFF)
    end

    # DXA's own `KeyCreate`: split `source` into its even- and odd-indexed
    # bytes, CRC32 each half, and lay the two checksums end to end (4 bytes +
    # the low 3 bytes of the second) as the 7-byte derived key -- one archive-
    # wide (from the archive's own key string) and one per file (from the
    # archive key string plus the file's own upper-cased name and ancestor
    # chain, see #walk_directory).
    def self.key_create(source)
      src = source.bytesize < 4 ? (source + DEFAULT_KEY_STRING) : source
      even = []
      odd = []
      i = 0
      n = src.bytesize
      while i < n
        (i % 2 == 0 ? even : odd) << src.getbyte(i)
        i += 1
      end
      crc0 = crc32(Wolf.bin(even.pack("C*")))
      crc1 = crc32(Wolf.bin(odd.pack("C*")))
      key = []
      j = 0
      while j < 4
        key << (crc0 / POW4[j]) % 256
        j += 1
      end
      j = 0
      while j < 3
        key << (crc1 / POW4[j]) % 256
        j += 1
      end
      key
    end

    # XORs `bytes` against `key` (an Array of KEY_BYTES integers), cycling
    # from `key[start_pos % KEY_BYTES]`. Assembled in bounded chunks (see
    # CHUNK) rather than one big Array of per-byte integers, the same reason
    # rgssad.rb's own #decrypt_data is chunked: mruby's Array length cap.
    def self.xor_cycle(bytes, key, start_pos)
      n = bytes.bytesize
      pos = start_pos % KEY_BYTES
      parts = []
      chunk = []
      i = 0
      while i < n
        chunk << (bytes.getbyte(i) ^ key[pos])
        pos += 1
        pos = 0 if pos == KEY_BYTES
        if chunk.size >= CHUNK
          parts << chunk.pack("C*")
          chunk = []
        end
        i += 1
      end
      parts << chunk.pack("C*") unless chunk.empty?
      Wolf.bin(parts.join)
    end

    def self.truncate_key(key_string)
      s = Wolf.bin(key_string)
      s.bytesize > KEY_STRING_MAX ? s.byteslice(0, KEY_STRING_MAX) : s
    end

    # A name-table entry's [upper-cased name, original-case name] pair, per
    # AddFileNameData's own layout: u16 PackNum, u16 Parity (unchecked here --
    # this reader looks entries up by address, never DXArchive.cpp's own
    # linear PackNum+Parity+bytes scan), PackNum*4 bytes of the upper-cased
    # name (NUL-padded), then PackNum*4 more of the original-case one. An
    # empty name (the root's own, never actually read by #walk_directory) is
    # PackNum == 0 with no name bytes at all.
    def self.read_name_entry(blob, addr)
      pack_num = u16_at(blob, addr)
      return [Wolf.bin(""), Wolf.bin("")] if pack_num == 0
      upper = read_cstr(blob, addr + 4)
      orig = read_cstr(blob, addr + 4 + pack_num * 4)
      [upper, orig]
    end

    def self.read_cstr(s, start)
      n = s.bytesize
      e = start
      e += 1 while e < n && s.getbyte(e) != 0
      s.byteslice(start, e - start)
    end

    # `name`, upper-cased the way DXArchive.cpp's own AddFileNameData does:
    # byte-range Shift_JIS lead-byte detection (0x81-0x9F, 0xE0-0xFC) leaves a
    # 2-byte character alone, everything else folds 'a'-'z' to 'A'-'Z'. Purely
    # mechanical (it need not know the archive's actual text encoding) --
    # WOLF project file/folder names are ASCII in every real project this
    # reader has been checked against, so this only ever exercises the
    # single-byte branch in practice, but is implemented byte-range-faithfully
    # regardless since a real encoder's own key derivation depends on it.
    def self.upper_name_bytes(name)
      out = []
      i = 0
      n = name.bytesize
      while i < n
        b = name.getbyte(i)
        if (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xFC)
          out << b << (i + 1 < n ? name.getbyte(i + 1) : 0)
          i += 2
        else
          out << (b >= 97 && b <= 122 ? b - 32 : b)
          i += 1
        end
      end
      Wolf.bin(out.pack("C*"))
    end

    # The upper-cased name of `d` and every ancestor up to (not including)
    # the root, nearest first -- the writer's side of the same chain
    # #walk_directory reads back (see the file header's "Format").
    def self.ancestor_upper_names(d)
      names = Wolf.bin(+"")
      cur = d
      while cur[:parent]
        names << upper_name_bytes(cur[:name])
        cur = cur[:parent]
      end
      names
    end

    def self.encode_name_entry(name)
      return Wolf.bin([0, 0, 0, 0].pack("C*")) if name.empty?
      upper = upper_name_bytes(name)
      pack_num = (name.bytesize + 1 + 3) / 4
      pad = pack_num * 4
      upper_padded = upper + Wolf.bin("\0" * (pad - upper.bytesize))
      orig_padded = Wolf.bin(name.dup) + Wolf.bin("\0" * (pad - name.bytesize))
      u16_bytes(pack_num) + u16_bytes(0) + upper_padded + orig_padded
    end

    def self.filehead_bytes(name_addr, attrs, data_address, data_size, press, huff)
      u64_bytes(name_addr) + u64_bytes(attrs) + Wolf.bin("\0" * 24) +
        u64_bytes(data_address) + u64_bytes(data_size) + u64_bytes(press) + u64_bytes(huff)
    end

    def self.dir_record_bytes(own_addr, parent_addr, file_head_num, file_head_addr)
      u64_bytes(own_addr) + u64_bytes(parent_addr) + u64_bytes(file_head_num) + u64_bytes(file_head_addr)
    end

    def self.darc_head_bytes(head_size, data_start, name_table_start, file_table_start, dir_table_start, flags)
      Wolf.bin([0x44, 0x58].pack("C*")) + u16_bytes(VERSION) + u32_bytes(head_size) +
        u64_bytes(data_start) + u64_bytes(name_table_start) +
        u64_bytes(file_table_start) + u64_bytes(dir_table_start) +
        u32_bytes(0) + u32_bytes(flags) + Wolf.bin([0].pack("C*")) + Wolf.bin("\0" * 15)
    end

    # '/'-separated path splitting without String#split (not a dependency of
    # this gem -- see mrbgem.rake), the same reason rgssad.rb's own
    # #arch_name_bytes stays byte-loop-based rather than using String#tr.
    def self.split_path(path)
      parts = []
      start = 0
      i = 0
      n = path.bytesize
      while i < n
        if path.getbyte(i) == 47 # '/'
          parts << path.byteslice(start, i - start)
          start = i + 1
        end
        i += 1
      end
      parts << path.byteslice(start, n - start)
      parts
    end
  end
end

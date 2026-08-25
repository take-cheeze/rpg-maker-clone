# Reader for RPG Maker's encrypted RGSSAD archives.
#
# A released RPG Maker XP game usually ships its whole Data/ (and Graphics/,
# Audio/, ...) tree packed into a single encrypted `Game.rgssad`, with no loose
# files on disk. RPG Maker VX packs the same "version 1" format under the name
# `Game.rgss2a`. VX Ace ships a different, version-3 layout as `Game.rgss3a`;
# both are handled here.
#
# The v1 format is a header — "RGSSAD\0" plus a version byte — followed by a flat
# list of entries, each one: a 32-bit name length, the name (with '\' path
# separators, e.g. "Data\System.rxdata"), a 32-bit data size, then that many
# bytes of file data. Every field is obfuscated with a rolling 32-bit key that
# starts at 0xDEADCAFE and advances by `key = key * 7 + 3` (mod 2**32):
#
#   * the length and size integers XOR the four little-endian key bytes, then
#     advance the key once;
#   * each name byte XORs the key's low byte, advancing the key per byte;
#   * the file data XORs the four little-endian key bytes, advancing the key
#     every four bytes, seeded from the key value in force right after the
#     entry's size field.
#
# The v3 (`.rgss3a`) format instead stores a single base key in the header (a
# plaintext 32-bit seed at offset 8, from which `key = seed * 9 + 3`), then a
# table of fixed-shape entry records — offset, size, per-file data key, name
# length, name — terminated by a record whose offset decrypts to 0. Every record
# integer XORs the *same* base key's four little-endian bytes (the key does not
# advance while walking the table), and each name byte XORs the key byte at its
# position mod 4. The file data at `offset` is decrypted exactly as in v1 but
# seeded with the record's own per-file key, so the same `decrypt_data` serves
# both versions.
#
# Implemented with byte-wise arithmetic only — no bignum bitwise operators, no
# `Integer#chr` / String-ext helpers — so it runs on this trimmed mruby the same
# as under CRuby (where scripts/rpgxp_testbed_check.rb exercises it against real
# data). Decrypted bytes are assembled by packing bounded chunks with
# `Array#pack("C*")` (mruby-pack) and joining them, so no single Array grows past
# mruby's array-length cap on large entries.
#
# .open (below) never reads the archive whole: it opens a seekable stream and
# only reads the header plus each version's entry table, then seeks straight to
# an entry's own bytes when #read asks for it by name. See docs/adr/0047-psp-
# memory-budget.md Finding 2 for why that matters -- a released game routinely
# packs this file past the size of the PSP's entire RAM budget by itself.

class RPGXP
  class RGSSAD
    HEADER = "RGSSAD\0".freeze
    START_KEY = 0xDEADCAFE
    MASK = 0x100000000 # 2**32
    # Little-endian byte multipliers, so an int is rebuilt without bit-shifting.
    POW = [1, 256, 65536, 16777216].freeze
    # Max per-byte integers held in one Array while decrypting, kept under mruby's
    # MRB_ARY_LENGTH_MAX (131072) so a large entry does not overflow the Array.
    DECRYPT_CHUNK = 65536

    # The archive path for a game directory (Game.rgssad / .rgss2a / .rgss3a), or
    # nil when the project is unpacked. Extensions are tried in release order.
    def self.find(game_dir)
      %w[rgssad rgss2a rgss3a].each do |ext|
        path = "#{game_dir}/Game.#{ext}"
        return path if File.exist?(path)
      end
      nil
    end

    # Opens the archive for streaming, seekable reads (see #initialize) rather
    # than reading the whole file up front: a released XP/VX game routinely
    # packs tens of MB into this single file, comfortably larger than the
    # PSP's entire ~24 MB budget by itself (docs/adr/0047-psp-memory-budget.md,
    # Finding 2), so the old `File.read` here was a hard memory-budget
    # blocker for any archive bigger than what was left of RAM. The `File`
    # stays open for the archive object's lifetime (the same lifetime the
    # whole-buffer version kept its String alive for).
    def self.open(path)
      new(File.open(path, "rb"))
    end

    # Build a version-1 archive from `files`, a list of [name, bytes] pairs (name
    # with '\' or '/' separators). The inverse of the reader — used to repack a
    # project and as the fixture builder for the archive tests.
    def self.pack_v1(files)
      key = START_KEY
      # Accumulate into bounded chunks (see DECRYPT_CHUNK): a whole archive is far
      # larger than mruby's array-length cap, so a single `out` array would
      # overflow. `flush` empties `out` in place so the closures below keep
      # writing to the same array.
      parts = []
      out = [0x52, 0x47, 0x53, 0x53, 0x41, 0x44, 0x00, 0x01] # "RGSSAD\0" + v1
      flush = lambda do
        parts << out.pack("C*") unless out.empty?
        out.clear
      end
      put_int = lambda do |v|
        b = 0
        while b < 4
          out << (((v / POW[b]) % 256) ^ ((key / POW[b]) % 256))
          b += 1
        end
        key = (key * 7 + 3) % MASK
      end
      files.each do |name, bytes|
        nb = arch_name_bytes(name)
        put_int.call(nb.size)
        nb.each do |c|
          out << (c ^ (key % 256))
          key = (key * 7 + 3) % MASK
        end
        put_int.call(bytes.bytesize)
        dkey = key
        j = 0
        idx = 0
        n = bytes.bytesize
        while idx < n
          if j == 4
            dkey = (dkey * 7 + 3) % MASK
            j = 0
          end
          out << (bytes.getbyte(idx) ^ ((dkey / POW[j]) % 256))
          flush.call if out.size >= DECRYPT_CHUNK
          j += 1
          idx += 1
        end
      end
      flush.call
      parts.join
    end

    # Build a version-3 (`.rgss3a`) archive from `files` ([name, bytes] pairs).
    # The inverse of parse_v3 — used to repack a project and as the v3 test
    # fixture builder. `seed` is the plaintext base seed stored in the header.
    def self.pack_v3(files, seed = 0xCAFECAFE)
      key = (seed * 9 + 3) % MASK
      # Precompute name bytes and give each file a distinct per-file data key.
      entries = []
      files.each_with_index do |(name, bytes), i|
        entries << { name: arch_name_bytes(name), bytes: bytes,
                     magic: (0x11111111 * (i + 1)) % MASK }
      end
      # The data region begins after the whole entry table (records + a 4-byte
      # zero-offset terminator); assign each file a slot there in order.
      table_size = 4
      entries.each { |e| table_size += 16 + e[:name].size }
      pos = 12 + table_size
      entries.each { |e| e[:offset] = pos; pos += e[:bytes].bytesize }

      # Bounded-chunk accumulation, as in pack_v1 (a full archive overflows a
      # single mruby array); `flush` empties `out` in place for the closures.
      parts = []
      out = [0x52, 0x47, 0x53, 0x53, 0x41, 0x44, 0x00, 0x03] # "RGSSAD\0" + v3
      flush = lambda do
        parts << out.pack("C*") unless out.empty?
        out.clear
      end
      b = 0
      while b < 4 # plaintext seed, little-endian
        out << ((seed / POW[b]) % 256)
        b += 1
      end
      put_int = lambda do |v|
        c = 0
        while c < 4
          out << (((v / POW[c]) % 256) ^ ((key / POW[c]) % 256))
          c += 1
        end
      end
      entries.each do |e|
        put_int.call(e[:offset])
        put_int.call(e[:bytes].bytesize)
        put_int.call(e[:magic])
        put_int.call(e[:name].size)
        j = 0
        while j < e[:name].size
          out << (e[:name][j] ^ ((key / POW[j % 4]) % 256))
          j += 1
        end
      end
      put_int.call(0) # terminator: an offset that decrypts to 0
      entries.each do |e|
        bytes = e[:bytes]
        dkey = e[:magic]
        j = 0
        idx = 0
        n = bytes.bytesize
        while idx < n
          if j == 4
            dkey = (dkey * 7 + 3) % MASK
            j = 0
          end
          out << (bytes.getbyte(idx) ^ ((dkey / POW[j]) % 256))
          flush.call if out.size >= DECRYPT_CHUNK
          j += 1
          idx += 1
        end
      end
      flush.call
      parts.join
    end

    # A name's bytes with '/' rewritten to '\' (works without String#tr).
    def self.arch_name_bytes(name)
      bytes = []
      i = 0
      n = name.bytesize
      while i < n
        b = name.getbyte(i)
        bytes << (b == 47 ? 92 : b)
        i += 1
      end
      bytes
    end

    # `data` is either a `String` of the whole archive (wrapped in a
    # `StringIO` below -- how the tests and pack_v1/pack_v3's own round-trip
    # callers use this) or an IO-like object already open for reading (what
    # .open above passes: a real `File`, read on demand instead of slurped
    # whole up front). Either way, only the header and each version's entry
    # table are read here; entry *data* is read lazily by #read via a seek,
    # so opening the archive no longer requires it to fit in RAM all at once
    # (see .open's comment above).
    def initialize(data)
      @io = data.is_a?(String) ? StringIO.new(data) : data
      @io.seek(0)
      header = @io.read(8)
      raise "not an RGSSAD archive (bad header)" unless header_ok?(header)
      @version = header.getbyte(7)
      @entries = {}
      case @version
      when 1
        parse_v1
      when 3
        parse_v3
      else
        raise "unsupported RGSSAD version #{@version} " \
              "(only versions 1 — .rgssad / .rgss2a — and 3 — .rgss3a — " \
              "are supported)"
      end
    end

    attr_reader :version, :entries

    # Entry names present in the archive (with '\' separators).
    def names
      @entries.keys
    end

    def include?(name)
      @entries.key?(normalize(name))
    end

    # Decrypted bytes for one entry, or nil when it is not in the archive. `name`
    # may be given with '/' or '\' separators. Seeks to the entry's own offset
    # and reads only its own bytes -- the archive is never loaded whole (see
    # #initialize).
    def read(name)
      e = @entries[normalize(name)]
      return nil unless e
      @io.seek(e[:offset])
      bytes = @io.read(e[:size])
      return nil if bytes.nil?
      decrypt_data(bytes, e[:key])
    end

    private

    def header_ok?(header)
      return false if header.nil? || header.bytesize < 8
      i = 0
      while i < 7
        return false unless header.getbyte(i) == HEADER.getbyte(i)
        i += 1
      end
      true
    end

    def advance(key)
      (key * 7 + 3) % MASK
    end

    # Byte n (0..3, little-endian) of the 32-bit key, via arithmetic so no bignum
    # bitwise operators are needed.
    def key_byte(key, n)
      (key / POW[n]) % 256
    end

    # De-obfuscate an already-read 4-byte little-endian integer with `key`.
    def decrypt_int(bytes, key)
      v = 0
      b = 0
      while b < 4
        v += (bytes.getbyte(b) ^ key_byte(key, b)) * POW[b]
        b += 1
      end
      v
    end

    # An already-read, plain (un-obfuscated) 4-byte little-endian integer.
    def plain_int(bytes)
      v = 0
      b = 0
      while b < 4
        v += bytes.getbyte(b) * POW[b]
        b += 1
      end
      v
    end

    # Walks the archive sequentially from just after the 8-byte header,
    # reading only each entry's own name-length/name/size fields and then
    # seeking past its data block (never reading the data itself -- that
    # only happens lazily, per entry, in #read). A short/missing read at any
    # point (a truncated or otherwise malformed tail) stops enumeration the
    # same way running off the end of a bounds-checked buffer used to.
    def parse_v1
      key = START_KEY
      loop do
        len_bytes = @io.read(4)
        break if len_bytes.nil? || len_bytes.bytesize < 4
        nlen = decrypt_int(len_bytes, key)
        key = advance(key)
        break if nlen <= 0

        name_enc = @io.read(nlen)
        break if name_enc.nil? || name_enc.bytesize < nlen
        name_bytes = []
        j = 0
        while j < nlen
          name_bytes << (name_enc.getbyte(j) ^ key_byte(key, 0))
          key = advance(key)
          j += 1
        end

        size_bytes = @io.read(4)
        break if size_bytes.nil? || size_bytes.bytesize < 4
        size = decrypt_int(size_bytes, key)
        key = advance(key)
        break if size < 0

        offset = @io.pos
        @entries[name_bytes.pack("C*")] = { offset: offset, size: size, key: key }
        @io.seek(offset + size) # skip the data block itself -- see #read
      end
    end

    # Parse the v3 (`.rgss3a`) entry table. The base key comes from the plaintext
    # header seed and stays fixed while walking the records; each record carries
    # its data's absolute offset, size and per-file key, so unlike v1 the records
    # live together up front and the data blocks follow -- meaning this table was
    # already cheap to read without touching the data even before streaming.
    # Terminated by a record whose offset field decrypts to 0.
    def parse_v3
      seed_bytes = @io.read(4)
      return if seed_bytes.nil? || seed_bytes.bytesize < 4
      key = (plain_int(seed_bytes) * 9 + 3) % MASK
      loop do
        offset_bytes = @io.read(4)
        break if offset_bytes.nil? || offset_bytes.bytesize < 4
        offset = decrypt_int(offset_bytes, key)
        break if offset == 0 # terminator record

        size_bytes = @io.read(4)
        break if size_bytes.nil? || size_bytes.bytesize < 4
        size = decrypt_int(size_bytes, key)

        fkey_bytes = @io.read(4)
        break if fkey_bytes.nil? || fkey_bytes.bytesize < 4
        file_key = decrypt_int(fkey_bytes, key)

        nlen_bytes = @io.read(4)
        break if nlen_bytes.nil? || nlen_bytes.bytesize < 4
        nlen = decrypt_int(nlen_bytes, key)
        break if nlen <= 0

        name_enc = @io.read(nlen)
        break if name_enc.nil? || name_enc.bytesize < nlen
        name_bytes = []
        j = 0
        while j < nlen
          name_bytes << (name_enc.getbyte(j) ^ key_byte(key, j % 4))
          j += 1
        end
        next if offset < 0

        @entries[name_bytes.pack("C*")] = { offset: offset, size: size, key: file_key }
      end
    end

    # Decrypt `size` bytes of file data, seeded from `seed` (the key right after
    # the size field). The key advances every four bytes.
    #
    # The plaintext is assembled in bounded chunks rather than one big Array of
    # per-byte integers: mruby caps Array length at MRB_ARY_LENGTH_MAX (131072),
    # so a single accumulating array overflows on any archived entry larger than
    # that (real XP games pack maps, Animations.rxdata and graphics well past it).
    # Packing each chunk to a String and joining stays byte-for-byte identical to
    # the old `out.pack("C*")` while keeping every intermediate array tiny.
    def decrypt_data(bytes, seed)
      key = seed
      parts = []
      chunk = []
      j = 0
      idx = 0
      n = bytes.bytesize
      while idx < n
        if j == 4
          key = advance(key)
          j = 0
        end
        chunk << (bytes.getbyte(idx) ^ key_byte(key, j))
        if chunk.size >= DECRYPT_CHUNK
          parts << chunk.pack("C*")
          chunk = []
        end
        j += 1
        idx += 1
      end
      parts << chunk.pack("C*") unless chunk.empty?
      parts.join
    end

    # Canonical archive form of a lookup name: '/' separators rewritten to '\'.
    def normalize(name)
      bytes = []
      i = 0
      n = name.bytesize
      while i < n
        b = name.getbyte(i)
        bytes << (b == 47 ? 92 : b) # '/' (47) -> '\' (92)
        i += 1
      end
      bytes.pack("C*")
    end
  end
end

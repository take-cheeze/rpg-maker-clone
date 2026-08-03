# Reader for RPG Maker's encrypted RGSSAD archives.
#
# A released RPG Maker XP game usually ships its whole Data/ (and Graphics/,
# Audio/, ...) tree packed into a single encrypted `Game.rgssad`, with no loose
# files on disk. RPG Maker VX packs the same "version 1" format under the name
# `Game.rgss2a`. (VX Ace's `Game.rgss3a` is a different, version-3 layout and is
# not handled yet.)
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
# Implemented with byte-wise arithmetic only — no bignum bitwise operators, no
# `Integer#chr` / String-ext helpers — so it runs on this trimmed mruby the same
# as under CRuby (where scripts/rpgxp_testbed_check.rb exercises it against real
# data). Decrypted bytes are assembled with `Array#pack("C*")` (mruby-pack).

class RPGXP
  class RGSSAD
    HEADER = "RGSSAD\0".freeze
    START_KEY = 0xDEADCAFE
    MASK = 0x100000000 # 2**32
    # Little-endian byte multipliers, so an int is rebuilt without bit-shifting.
    POW = [1, 256, 65536, 16777216].freeze

    # The archive path for a game directory (Game.rgssad / .rgss2a / .rgss3a), or
    # nil when the project is unpacked. Extensions are tried in release order.
    def self.find(game_dir)
      %w[rgssad rgss2a rgss3a].each do |ext|
        path = "#{game_dir}/Game.#{ext}"
        return path if File.exist?(path)
      end
      nil
    end

    def self.open(path)
      new(File.open(path, "rb") { |f| f.read })
    end

    # Build a version-1 archive from `files`, a list of [name, bytes] pairs (name
    # with '\' or '/' separators). The inverse of the reader — used to repack a
    # project and as the fixture builder for the archive tests.
    def self.pack_v1(files)
      key = START_KEY
      out = [0x52, 0x47, 0x53, 0x53, 0x41, 0x44, 0x00, 0x01] # "RGSSAD\0" + v1
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
          j += 1
          idx += 1
        end
      end
      out.pack("C*")
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

    # `data` is the raw archive bytes.
    def initialize(data)
      @data = data
      raise "not an RGSSAD archive (bad header)" unless header_ok?
      @version = @data.getbyte(7)
      @entries = {}
      case @version
      when 1
        parse_v1
      else
        raise "unsupported RGSSAD version #{@version} " \
              "(only version 1 — .rgssad / .rgss2a — is supported)"
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
    # may be given with '/' or '\' separators.
    def read(name)
      e = @entries[normalize(name)]
      return nil unless e
      decrypt_data(@data[e[:offset], e[:size]], e[:key])
    end

    private

    def header_ok?
      return false if @data.bytesize < 8
      i = 0
      while i < 7
        return false unless @data.getbyte(i) == HEADER.getbyte(i)
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

    # Read a 32-bit little-endian integer at `i`, de-obfuscated with `key`.
    def read_int(i, key)
      v = 0
      b = 0
      while b < 4
        v += (@data.getbyte(i + b) ^ key_byte(key, b)) * POW[b]
        b += 1
      end
      v
    end

    def parse_v1
      key = START_KEY
      i = 8
      len = @data.bytesize
      while i + 4 <= len
        nlen = read_int(i, key)
        key = advance(key)
        i += 4
        break if nlen <= 0 || i + nlen + 4 > len

        name_bytes = []
        j = 0
        while j < nlen
          name_bytes << (@data.getbyte(i + j) ^ key_byte(key, 0))
          key = advance(key)
          j += 1
        end
        i += nlen

        size = read_int(i, key)
        key = advance(key)
        i += 4
        break if size < 0 || i + size > len

        @entries[name_bytes.pack("C*")] = { offset: i, size: size, key: key }
        i += size
      end
    end

    # Decrypt `size` bytes of file data, seeded from `seed` (the key right after
    # the size field). The key advances every four bytes.
    def decrypt_data(bytes, seed)
      key = seed
      out = []
      j = 0
      idx = 0
      n = bytes.bytesize
      while idx < n
        if j == 4
          key = advance(key)
          j = 0
        end
        out << (bytes.getbyte(idx) ^ key_byte(key, j))
        j += 1
        idx += 1
      end
      out.pack("C*")
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

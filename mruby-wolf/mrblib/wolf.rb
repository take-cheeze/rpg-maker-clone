# WOLF RPG Editor (ウディタ / "Woditor") data layer: the byte-level readers every
# format under Data/BasicData and Data/MapData shares.
#
# Written in the mruby/CRuby common subset -- no String#unpack directives beyond
# what both provide, no encodings API, integers assembled byte by byte -- so the
# exact same source is loaded under CRuby by scripts/wolf_testbed_check.rb and
# driven over a real game, the way mruby-lcf's parser is. Two portability rules
# shape the code (see AGENTS.md):
#
#   * `mrb_int` is 32-bit on the browser / Wio / PSP builds, so a little-endian
#     32-bit word is folded to its signed value arithmetically instead of via
#     pack('L').unpack('l'), exactly like LCF.read_ber.
#   * mruby has no String#encode. Shift_JIS text (every file a v2.x editor
#     writes) goes through LCF.cp932_to_utf8, the uni-algo-backed transcoder
#     mruby-lcf already ships; CRuby's own transcoder stands in under the host
#     check.
#
# The formats themselves are undocumented by the editor's author. They were
# reconstructed from three independent open-source readers that agree with each
# other -- wolftrans (Ruby, elizagamedev), WolfTL (C++, Sinflower) and the
# wolfrpg-map-parser crate (Rust, G1org1owo) -- plus the MIT-licensed Kaitai
# Struct descriptions in djytw/wolf-rpg-formats, and then checked byte-for-byte
# against the sample game the official editor package ships
# (scripts/download-wolfrpg-sample.bash). See
# docs/adr/0064-wolf-rpg-editor-data-layer.md.
module Wolf
  # Every WOLF RPG Editor version this layer knows how to read, by the marker
  # each file carries:
  #
  #   * "v2" files (editor 2.x): Shift_JIS strings, no compression, Game.dat /
  #     *DataBase.dat optionally scrambled with a 3-seed XOR (Crypt.v2).
  #   * "v3" files (editor 3.0 - 3.4): UTF-8 strings (a 0x55 byte replaces one
  #     0x00 of the magic), same layouts.
  #   * "v3.5+" files (editor 3.5 and later, what every current release
  #     writes): UTF-8, and the body after the version byte is one LZ4 block
  #     (u32 decompressed size, u32 compressed size, block). Maps store their
  #     layer count per map, and every event command carries a trailing byte
  #     array.
  #
  # Pro-edition "protected" data (byte 1 == 0x50) is AES/ChaCha-encrypted;
  # detected and refused with a clear error rather than decrypted. This
  # reader deliberately does not decrypt Pro-protected data: the official
  # WOLF RPG Editor terms of use (silversecond.com/WolfRPGEditor/
  # Download.shtml, "9.2. 暗号化データ（「.wolf」ファイル）の解析・解凍、
  # ならびに情報共有は禁止です" -- analysis/decryption of encrypted ".wolf"
  # data is prohibited) explicitly excludes Pro-protected files from the
  # format-analysis permission its own 9.1 otherwise grants Game.dat/
  # CommonEvent.dat/TileSetData/the Database.dat and MapTree.dat families/
  # .mps maps. See docs/adr/0095-wolf-rpg-editor-pro-protected.md for the
  # history (a real, working decryptor was briefly shipped here, then
  # removed once this term was found).
  UTF8_MARK = 0x55

  class Error < StandardError; end

  # Transcode a Shift_JIS (Windows-31J) byte string to UTF-8. mruby-lcf's native
  # decoder in the game build; scripts/wolf_testbed_check.rb swaps in CRuby's.
  def self.sjis_to_utf8(s)
    LCF.cp932_to_utf8(s)
  end

  # Tag a UTF-8 byte string as such where the host distinguishes encodings
  # (CRuby); mruby strings are byte strings and need nothing.
  def self.utf8(s)
    s.respond_to?(:force_encoding) ? s.force_encoding("UTF-8") : s
  end

  # Tag a byte-literal string as binary where the host distinguishes encodings
  # (CRuby's String#b); mruby has no encoding concept, so a plain literal
  # already behaves as one. Used for every magic-number / separator constant
  # below, since they are almost all non-ASCII byte sequences compared against
  # bytes read straight off disk.
  def self.bin(s)
    s.respond_to?(:b) ? s.b : s
  end

  # Little-endian 32-bit word at byte offset `i` of `bytes` (an Array of
  # Integers), folded to its signed value without pack/unpack -- see the file
  # header for why.
  def self.s32_at(bytes, i)
    v = bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16) | (bytes[i + 3] << 24)
    v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
  end

  # Sequential reader over one file's bytes. Strings are decoded according to
  # the file's own marker (`utf8`), which the caller learns from the magic.
  class Reader
    attr_reader :pos, :data
    attr_accessor :utf8

    def initialize(data, utf8 = true)
      @data = data
      @pos = 0
      @utf8 = utf8
      @size = data.bytesize
    end

    def size; @size; end
    def eof?; @pos >= @size; end
    def remaining; @size - @pos; end

    def pos=(p)
      raise Error, "seek past end (#{p} > #{@size})" if p > @size
      @pos = p
    end

    def skip(n)
      self.pos = @pos + n
    end

    def peek_u8
      raise Error, "read past end of data at #{@pos}" if @pos >= @size
      @data.getbyte(@pos)
    end

    def u8
      b = peek_u8
      @pos += 1
      b
    end

    def u16
      lo = u8
      lo | (u8 << 8)
    end

    # A signed little-endian 32-bit integer -- the format's one integer type
    # (counts, ids, command parameters and -1 markers alike).
    def int
      raise Error, "read past end of data at #{@pos}" if @pos + 4 > @size
      d = @data
      p = @pos
      v = d.getbyte(p) | (d.getbyte(p + 1) << 8) | (d.getbyte(p + 2) << 16) |
          (d.getbyte(p + 3) << 24)
      @pos = p + 4
      v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
    end

    # The same word read as an unsigned quantity, for the bit-field fields
    # (tile passability flags, picture command flags) whose top bit is data.
    def uint
      raise Error, "read past end of data at #{@pos}" if @pos + 4 > @size
      d = @data
      p = @pos
      v = d.getbyte(p) | (d.getbyte(p + 1) << 8) | (d.getbyte(p + 2) << 16) |
          (d.getbyte(p + 3) << 24)
      @pos = p + 4
      v
    end

    def bytes(n)
      raise Error, "read past end of data at #{@pos} (+#{n})" if @pos + n > @size
      s = @data.byteslice(@pos, n)
      @pos += n
      s
    end

    # Reads `n` raw bytes as an Array of Integers.
    def byte_values(n)
      bytes(n).bytes
    end

    # A length-prefixed, NUL-terminated string: u32 byte count (including the
    # terminator), then the text. The editor never writes a zero count.
    def str
      n = int
      raise Error, "invalid string length #{n} at #{@pos - 4}" if n <= 0
      raw = bytes(n)
      raise Error, "string not NUL-terminated at #{@pos - 1}" unless raw.getbyte(n - 1) == 0
      body = raw.byteslice(0, n - 1)
      @utf8 ? Wolf.utf8(body) : Wolf.sjis_to_utf8(body)
    end

    def str_array
      n = int
      raise Error, "invalid string array length #{n}" if n < 0
      a = []
      n.times { a.push str }
      a
    end

    def int_array
      n = int
      raise Error, "invalid int array length #{n}" if n < 0
      a = []
      n.times { a.push int }
      a
    end

    def byte_array
      n = int
      raise Error, "invalid byte array length #{n}" if n < 0
      byte_values(n)
    end

    # Fail loudly on a mismatched marker byte: every record in these files is
    # bracketed by such bytes, so a wrong read surfaces at once instead of a
    # few fields later as nonsense.
    def expect_u8(want, what)
      got = u8
      return got if got == want
      raise Error, sprintf("%s: expected 0x%02x, got 0x%02x at %d", what, want, got, @pos - 1)
    end

    def expect_bytes(want, what)
      got = bytes(want.bytesize)
      return got if got == want
      raise Error, "#{what}: expected #{want.bytes.inspect}, got #{got.bytes.inspect} at #{@pos - want.bytesize}"
    end
  end

  # The LZ4 *block* format (no frame header), which 3.5+ files wrap their body
  # in. Implemented natively (mruby-wolf/src/lz4.cxx) rather than in Ruby: an
  # interpreted, allocation-per-token decoder measured 3.3 seconds against the
  # editor's own bundled CommonEvent.dat (106,477 tokens for 1.3 MB -- WOLF RPG
  # Editor's bytecode-like event data compresses to many *short* matches, not
  # few long ones), and an earlier byte-at-a-time version of its overlapping-
  # match copy exhausted LVGL's heap outright (`NoMemoryError`) on the same
  # file. `Wolf::LZ4.decompress(src, dst_size)` is the one native method this
  # gem defines; everything else here and in data.rb stays in the
  # mruby/CRuby common subset. scripts/wolf_testbed_check.rb supplies an
  # equivalent pure-Ruby stand-in for the CRuby host check, the same way it
  # stands in for LCF.cp932_to_utf8.
  module LZ4
    MIN_MATCH = 4
  end

  module Crypt
    # The 2.x editor's optional scrambling of Game.dat and *DataBase.dat: when
    # the first byte is non-zero, the first 10 bytes are a key header and the
    # rest is XORed with three MSVC-`rand()` keystreams (LCG 214013 / 2531011,
    # bits 28..30 of the state) seeded from three header bytes, each stream
    # touching every 1st / 2nd / 5th byte respectively. Which header bytes seed
    # the streams differs per file (GameDat::SEEDS, Database::SEEDS).
    INTERVALS = [1, 2, 5]
    HEADER_SIZE = 10

    def self.v2(data, seeds)
      bytes = data.bytes
      size = bytes.size
      seeds.each_with_index do |seed, s|
        step = INTERVALS[s]
        i = 0
        while i < size
          seed = (seed * 0x343FD + 0x269EC3) & 0xFFFF_FFFF
          bytes[i] ^= (seed >> 28) & 7
          i += step
        end
      end
      bytes.pack("C*")
    end

    # Pro-edition protection (3.1+) marks a file with 0x50 in its second
    # byte. Refused up front, with a message that says so -- see the file
    # header's note on why this reader does not decrypt Pro-protected data.
    def self.protected?(data)
      data.bytesize > 5 && data.getbyte(1) == 0x50
    end

    def self.refuse_protected!(data, what)
      return unless protected?(data)
      raise Error, "#{what} is Pro-protected (byte 1 == 0x50); protected games are not supported"
    end
  end

  # Peel the (optionally v2-encrypted) envelope off a BasicData file: returns
  # [reader, encrypted]. A plain file starts with a 0 indicator byte followed
  # by its magic; the reader is left just past the indicator so the caller can
  # verify the magic and learn the string encoding. An encrypted file has no
  # magic at all (it is v2, so Shift_JIS), and the reader starts at its first
  # field.
  def self.open_envelope(data, seeds, what)
    Crypt.refuse_protected!(data, what)
    indicator = data.getbyte(0)
    raise Error, "#{what}: empty file" if indicator.nil?
    if indicator == 0 || seeds.nil?
      r = Reader.new(data, true)
      r.skip(1)
      [r, false]
    else
      header = data.byteslice(0, Crypt::HEADER_SIZE).bytes
      body = Crypt.v2(data.byteslice(Crypt::HEADER_SIZE, data.bytesize - Crypt::HEADER_SIZE),
                      seeds.map { |i| header[i] })
      [Reader.new(body, false), true]
    end
  end

  # Verify a 9-byte BasicData magic ("W\0\0OL?FM\0"-shaped, where one of the
  # NULs is 0x55 in a UTF-8 file) and set the reader's encoding from it.
  # `utf8_index` is which byte of the 9 carries the marker.
  def self.read_magic(r, magic, utf8_index, what)
    got = r.bytes(magic.bytesize)
    expect = magic.bytes
    gb = got.bytes
    utf8 = gb[utf8_index] == UTF8_MARK
    expect[utf8_index] = UTF8_MARK if utf8
    unless gb == expect
      raise Error, "#{what}: bad magic #{gb.inspect} (expected #{magic.bytes.inspect})"
    end
    r.utf8 = utf8
    utf8
  end

  # Replace the rest of a reader with the LZ4 body that starts at its position
  # (u32 decompressed size, u32 compressed size, block): the bytes before stay
  # as they are, so positions in the header keep meaning the same thing. Returns
  # a new Reader at the same position.
  def self.unpack_body(r, what)
    start = r.pos
    dec_size = r.int
    enc_size = r.int
    if dec_size < 0 || enc_size < 0 || enc_size > r.remaining
      raise Error, "#{what}: bad LZ4 envelope (decoded #{dec_size}, packed #{enc_size}, #{r.remaining} left)"
    end
    body = LZ4.decompress(r.bytes(enc_size), dec_size)
    unless r.eof?
      raise Error, "#{what}: #{r.remaining} bytes trail the LZ4 block"
    end
    nr = Reader.new(r.data.byteslice(0, start) + body, r.utf8)
    nr.pos = start
    nr
  end
end

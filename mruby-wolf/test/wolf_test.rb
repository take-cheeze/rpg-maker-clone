# Unit tests for mruby-wolf's byte-level primitives: the Reader, the LZ4 block
# decoder and the v2 XOR cipher, plus the bit-field decoders (TileFlags, Page
# option/condition bytes) that a hand-written blob can exercise directly.
#
# The full file formats (Game.dat, the databases, CommonEvent.dat, .mps) are
# validated against a real project instead of synthetic fixtures here --
# scripts/wolf_testbed_check.rb drives this exact mrblib source under CRuby
# over the sample game scripts/download-wolfrpg-sample.bash fetches, the way
# scripts/lcf_testbed_check.rb does for the LCF (RPG2000/2003) layer.

# ---- Reader -----------------------------------------------------------------

assert "Wolf::Reader reads little-endian signed/unsigned ints" do
  r = Wolf::Reader.new("\xff\xff\xff\xff\x01\x00\x00\x00")
  assert_equal(-1, r.int)
  assert_equal 1, r.int
  assert_true r.eof?
end

assert "Wolf::Reader#uint keeps the top bit as data" do
  r = Wolf::Reader.new("\x00\x00\x00\x80")
  assert_equal 0x8000_0000, r.uint
end

assert "Wolf::Reader#str reads a length-prefixed NUL-terminated string" do
  data = "\x04\x00\x00\x00abc\x00"
  r = Wolf::Reader.new(data, true)
  assert_equal "abc", r.str
  assert_true r.eof?
end

assert "Wolf::Reader#str rejects a missing NUL terminator" do
  data = "\x03\x00\x00\x00abX"
  r = Wolf::Reader.new(data, true)
  assert_raise(Wolf::Error) { r.str }
end

assert "Wolf::Reader#str_array / #int_array read a count then that many elements" do
  data = "\x02\x00\x00\x00" \
         "\x02\x00\x00\x00A\x00" \
         "\x02\x00\x00\x00B\x00"
  assert_equal %w[A B], Wolf::Reader.new(data, true).str_array

  ints = "\x02\x00\x00\x00\x05\x00\x00\x00\xff\xff\xff\xff"
  assert_equal [5, -1], Wolf::Reader.new(ints).int_array
end

assert "Wolf::Reader#expect_u8 / #expect_bytes raise on mismatch" do
  r = Wolf::Reader.new("\x01")
  assert_raise(Wolf::Error) { r.expect_u8(0x02, "marker") }

  r = Wolf::Reader.new("ab")
  assert_raise(Wolf::Error) { r.expect_bytes("cd", "tag") }
  r2 = Wolf::Reader.new("ab")
  assert_equal "ab", r2.expect_bytes("ab", "tag")
end

assert "Wolf::Reader raises rather than reading past the end" do
  r = Wolf::Reader.new("\x01\x02")
  assert_raise(Wolf::Error) { r.int }
end

# ---- LZ4 block decoder ------------------------------------------------------

assert "Wolf::LZ4.decompress handles a literals-only block" do
  # token (4 literals, no match) + 4 literal bytes; the last sequence in an
  # LZ4 block carries literals only.
  src = [0x40, 0x41, 0x42, 0x43, 0x44].pack("C*")
  assert_equal "ABCD", Wolf::LZ4.decompress(src, 4)
end

assert "Wolf::LZ4.decompress handles an overlapping match" do
  # 4 literal 'A's, then a match of length 6 at offset 1 -- copies the 'A'
  # just written, six times over, the classic run-length-via-LZ4 case.
  src = [0x42, 0x41, 0x41, 0x41, 0x41, 0x01, 0x00].pack("C*")
  assert_equal "AAAAAAAAAA", Wolf::LZ4.decompress(src, 10)
end

assert "Wolf::LZ4.decompress handles a non-overlapping match" do
  # "ABAB" then a match of length 4 (nibble 0 + MIN_MATCH 4) at offset 4,
  # copying the whole run just written a second time.
  src = [0x40, 0x41, 0x42, 0x41, 0x42, 0x04, 0x00].pack("C*")
  assert_equal "ABABABAB", Wolf::LZ4.decompress(src, 8)
end

assert "Wolf::LZ4.decompress extends a length past 14 via 0xff continuation bytes" do
  # 15 in the nibble plus a single 0xff-terminated extra byte: 15 + 5 = 20
  # literal bytes. (255 would mean "add another 255 and keep reading".)
  src = ([0xF0, 5] + Array.new(20, 0x58)).pack("C*")
  assert_equal("X" * 20, Wolf::LZ4.decompress(src, 20))
end

assert "Wolf::LZ4.decompress handles a long overlapping run without per-byte allocation" do
  # A single 4-byte literal then one match copying it 50,000 times over
  # (offset 4, encoded length nibble 15 + extension bytes for 200000 - 4):
  # the doubling-copy path this exercises is what keeps a real CommonEvent.dat
  # (whose bodies routinely LZ4-encode long repeated runs) from allocating one
  # String per output byte under mruby's GC.
  match_len = 200_000 - 4 - Wolf::LZ4::MIN_MATCH
  extra = match_len - 15
  ext_bytes = []
  remaining = extra
  while remaining >= 255
    ext_bytes << 255
    remaining -= 255
  end
  ext_bytes << remaining
  src = ([0x4F, 0x41, 0x42, 0x43, 0x44, 0x04, 0x00] + ext_bytes).pack("C*")
  out = Wolf::LZ4.decompress(src, 200_000)
  assert_equal 200_000, out.bytesize
  assert_equal "ABCD" * 50_000, out
end

assert "Wolf::LZ4.decompress raises on a size mismatch" do
  src = [0x10, 0x41].pack("C*")
  assert_raise(Wolf::Error) { Wolf::LZ4.decompress(src, 2) }
end

# ---- v2 XOR cipher -----------------------------------------------------------

assert "Wolf::Crypt.v2 is its own inverse for a fixed seed set" do
  plain = "the quick brown fox jumps over the lazy dog" * 3
  seeds = [0x12, 0x34, 0x56]
  encrypted = Wolf::Crypt.v2(plain, seeds)
  assert_not_equal plain, encrypted
  assert_equal plain, Wolf::Crypt.v2(encrypted, seeds)
end

assert "Wolf::Crypt.protected? detects the Pro-protection marker" do
  assert_true Wolf::Crypt.protected?("\x00\x50\x00\x00\x00\x57")
  assert_false Wolf::Crypt.protected?("\x00\x57\x00\x00\x4f\x4c")
end

# ---- Wolf::DataWolf (Data.wolf packed-release reader) ------------------------
#
# Mostly unit-level here (a hand-built archive, via .pack -- data_wolf.rb's
# own fixture builder). The much stronger cross-check for everything *except*
# the compressed-header path below -- .pack applied to a real, 660-file
# project and read back through the *whole* Wolf::Project pipeline -- is
# scripts/wolf_data_wolf_check.rb, run separately against the downloaded
# sample game the way scripts/wolf_testbed_check.rb already is (`.pack` never
# writes a compressed table, so that round trip alone could never exercise
# `.huffman_decode`/`.dxa_lz_decode`).
#
# The three fixtures below (`HUFFMAN_SMALL_*`, `LZ_REPEAT_*`/`LZ_OVERLAP_*`,
# `COMPRESSED_HEADER_ARCHIVE_BYTES`) are real compressed output, not
# hand-crafted bytes: generated by compiling the actual vendored
# `Huffman_Encode`/`DXArchive::Encode` (3rd/../WolfDec's own reference
# sources this reader is ported from) against known plaintext and dumping
# the result, so these prove `.huffman_decode`/`.dxa_lz_decode` agree with
# DxLib's own encoder rather than only with each other.

assert "Wolf::DataWolf.crc32 matches the standard CRC-32/ISO-HDLC check value" do
  # The textbook check value for this exact variant (poly 0xEDB88320,
  # reflected, init/final 0xFFFFFFFF) -- independent of anything WOLF- or
  # DXA-specific, so this alone catches a wrong polynomial or a reflection
  # mistake before it ever touches a real key derivation.
  assert_equal 0xCBF4_3926, Wolf::DataWolf.crc32("123456789")
end

assert "Wolf::DataWolf round-trips nested directories, an empty file and a file spanning CHUNK" do
  big = (0..255).to_a.pack("C*") * 900 # 230400 bytes, over CHUNK (65536)
  files = [
    ["BasicData/Game.dat", "hello world " * 100],
    ["MapData/Deep/Nested/Map001.mps", big],
    ["MapData/Deep/other.mps", "sibling"],
    ["SystemFile/Empty.bin", ""]
  ]
  archive = Wolf::DataWolf.pack(files)
  a = Wolf::DataWolf.new(archive)

  assert_equal files.map(&:first).sort, a.names.sort
  files.each do |name, bytes|
    assert_equal bytes.bytesize, a.entry_size(name)
    # Compare via #bytesize/== rather than #bytes for `big` (230400 bytes):
    # #bytes would materialise an Array past mruby's MRB_ARY_LENGTH_MAX
    # (131072) -- the same reason rgssad_test's own over-cap check does the
    # same (mruby-rpgxp/test/rpgxp_test.rb).
    got = a.read(name)
    assert_equal bytes.bytesize, got.bytesize
    assert_true bytes == got
  end
  assert_true a.include?("MapData/Deep/Nested/Map001.mps")
  assert_false a.include?("MapData/Missing.mps")
  assert_true a.read("MapData/Missing.mps").nil?
end

assert "Wolf::DataWolf.open (auto-detect) finds whichever known key .pack used" do
  files = [["BasicData/Game.dat", "abc"]]
  # Index 4 ("One Way Heroics Plus"), deliberately not .pack's own default
  # (index 2), so this only passes if key detection genuinely tries more
  # than one candidate rather than happening to match the default.
  archive = Wolf::DataWolf.pack(files, key_string: Wolf::DataWolf::KNOWN_KEYS[4])
  a = Wolf::DataWolf.new(archive)
  assert_equal Wolf::DataWolf::KNOWN_KEYS[4], a.key_string
  assert_equal "abc".bytes, a.read("BasicData/Game.dat").bytes
end

assert "Wolf::DataWolf reads a no_key archive with no key at all" do
  files = [["BasicData/Game.dat", "no key here"]]
  archive = Wolf::DataWolf.pack(files, no_key: true)
  a = Wolf::DataWolf.new(archive)
  assert_true a.key_string.nil?
  assert_equal "no key here".bytes, a.read("BasicData/Game.dat").bytes
end

assert "Wolf::DataWolf.new(key_string:) forces one exact key rather than auto-detecting" do
  files = [["f.bin", "x"]]
  archive = Wolf::DataWolf.pack(files, key_string: Wolf::DataWolf::KNOWN_KEYS[1])
  a = Wolf::DataWolf.new(archive, key_string: Wolf::DataWolf::KNOWN_KEYS[1])
  assert_equal "x".bytes, a.read("f.bin").bytes
end

assert "Wolf::DataWolf rejects a bad header, an unsupported version, and an unknown key" do
  assert_raise(Wolf::Error) { Wolf::DataWolf.new("NOTDXA\x00\x00\x00\x00\x00\x00\x00\x00") }

  archive = Wolf::DataWolf.pack([["f.bin", "x"]]).dup
  archive.setbyte(2, 7) # Version byte, LSB: 8 -> 7
  assert_raise(Wolf::Error) { Wolf::DataWolf.new(archive) }

  unknown = Wolf::DataWolf.pack([["f.bin", "x"]], key_string: "not one of the known keys at all")
  assert_raise(Wolf::Error) { Wolf::DataWolf.new(unknown) }
end

HUFFMAN_SMALL_PLAIN = "Hello, WOLF RPG Editor!"
HUFFMAN_SMALL_COMPRESSED = [
  18, 226, 52, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 3, 33, 100, 213, 144, 238, 200, 64, 0, 0, 0, 0, 0, 0,
  171, 33, 187, 33, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 42, 200, 64, 0, 11, 178, 16, 0, 171, 33, 187, 33, 2, 172, 132, 11, 178, 26, 178,
  27, 178, 16, 0, 2, 172, 134, 236, 132, 0, 0, 0, 0, 0, 0, 0, 0, 171, 33, 2,
  236, 132, 0, 42, 200, 110, 200, 64, 197, 144, 181, 100, 32, 49, 100, 45, 89, 8, 10, 178,
  27, 178, 26, 178, 27, 178, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 135, 171, 122, 4, 223, 93, 129, 191, 51, 73,
  172, 213, 3
].freeze

LZ_REPEAT_PLAIN = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
LZ_REPEAT_COMPRESSED = [98, 0, 0, 0, 14, 0, 0, 0, 255, 97, 255, 236, 2, 0].freeze
LZ_OVERLAP_PLAIN = "ABABABABABABABABABABABABABABABABABABABABAB"
LZ_OVERLAP_COMPRESSED = [42, 0, 0, 0, 15, 0, 0, 0, 255, 65, 66, 255, 36, 1, 1].freeze

# A full, real archive (`f.bin` -> "hello") whose header table is genuinely
# Huffman(LZ(table))-compressed, produced the same cross-validated way (see
# the section comment above) and then XOR-encrypted with KNOWN_KEYS[2] --
# the exact bytes a real compressed `Data.wolf` would have.
COMPRESSED_HEADER_ARCHIVE_BYTES = [
  68, 88, 8, 0, 124, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 69, 0, 0, 0,
  0, 0, 0, 0, 20, 0, 0, 0, 0, 0, 0, 0, 92, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 213, 0, 193, 190, 5, 40, 20, 160, 10, 18, 193, 143, 212, 176, 192, 91,
  206, 28, 88, 217, 209, 31, 122, 17, 202, 40, 63, 5, 249, 238, 222, 80, 161, 113, 69, 249,
  238, 247, 30, 198, 108, 158, 170, 126, 247, 30, 204, 22, 75, 144, 160, 153, 130, 76, 63, 5,
  249, 238, 247, 30, 204, 63, 47, 101, 64, 107, 158, 105, 6, 176, 192, 238, 247, 30, 105, 6,
  176, 192, 238, 247, 30, 204, 63, 5, 251, 122, 17, 202, 40, 63, 44, 183, 131, 185, 94, 105,
  6, 176, 192, 238, 247, 55, 130, 82, 75, 185, 238, 247, 30, 204, 63, 47, 101, 64, 107, 158,
  204, 63, 5, 249, 238, 222, 80, 161, 113, 69, 251, 122, 17, 202, 40, 53, 86, 98, 189, 103,
  30, 206, 171, 227, 45, 10, 247, 30, 206, 171, 227, 45, 10, 247, 30, 204, 63, 44, 183, 131,
  185, 94, 204, 63, 5, 249, 238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204, 63, 5, 249,
  238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204, 63, 5,
  249, 238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204, 63,
  5, 249, 238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204,
  63, 5, 249, 238, 247, 30, 204, 63, 5, 249, 238, 247, 30, 204, 63, 5, 249, 220, 190, 51,
  177, 91, 239, 22, 17, 111, 33, 62, 47, 150, 102, 151, 61, 219, 93, 201, 47, 148, 67, 164,
  144, 39, 221, 31, 98, 236, 247
].freeze

assert "Wolf::DataWolf.huffman_decode matches DxLib's own Huffman_Decode " \
       "(cross-validated by compiling the vendored Huffman.cpp/Huffman_Encode " \
       "and feeding its real output here)" do
  compressed = HUFFMAN_SMALL_COMPRESSED.pack("C*")
  assert_equal HUFFMAN_SMALL_PLAIN.bytes, Wolf::DataWolf.huffman_decode(Wolf.bin(compressed)).bytes
end

assert "Wolf::DataWolf.dxa_lz_decode matches DXArchive::Decode " \
       "(cross-validated the same way, against the vendored DXArchive::Encode)" do
  assert_equal LZ_REPEAT_PLAIN.bytes,
               Wolf::DataWolf.dxa_lz_decode(LZ_REPEAT_COMPRESSED.pack("C*")).bytes
  # This one specifically exercises the self-overlapping-copy branch
  # (back-reference distance shorter than the run length, needing the
  # doubling loop rather than a plain memcpy) -- see .dxa_lz_decode's own
  # comment for why that case needs its own code path at all.
  assert_equal LZ_OVERLAP_PLAIN.bytes,
               Wolf::DataWolf.dxa_lz_decode(LZ_OVERLAP_COMPRESSED.pack("C*")).bytes
end

assert "Wolf::DataWolf reads a real compressed (Huffman+LZ) header table" do
  # A full, real archive: `f.bin` -> "hello", built by hand from the same
  # private building blocks the "rejects a compressed entry" test below
  # uses, except the table itself is genuinely Huffman(LZ(table)))-compressed
  # -- produced by compiling the vendored `DXArchive::Encode`/`Huffman_Encode`
  # against this exact plaintext table and hex-dumping the result, not by
  # this reader's own (decode-only, see data_wolf.rb's file header) code.
  # Data comes before the table in this fixture, matching a real compressed
  # archive's own layout (`OpenArchiveFile`'s `HuffHeadSize = FileSize -
  # ftell(FileNameTableStartAddress)` only makes sense if the table is the
  # last thing in the file) -- unlike this reader's own always-uncompressed
  # `.pack`, which puts the (exactly-sized, so order doesn't matter) table
  # before the data instead.
  archive = COMPRESSED_HEADER_ARCHIVE_BYTES.pack("C*")
  a = Wolf::DataWolf.new(archive, key_string: Wolf::DataWolf::KNOWN_KEYS[2])
  assert_equal ["f.bin"], a.names
  assert_equal "hello".bytes, a.read("f.bin").bytes
end

assert "Wolf::DataWolf#read rejects a compressed entry rather than mis-decoding it" do
  # Hand-assembled from the same private building blocks .pack itself uses
  # (bare `private` in data_wolf.rb only covers the instance methods, not
  # these -- see the file's own comment above them), with PressDataSize set
  # to a real (non-sentinel) value on purpose.
  key_string = Wolf::DataWolf::KNOWN_KEYS[2]
  key = Wolf::DataWolf.key_create(key_string)
  name_table = Wolf::DataWolf.encode_name_entry("f.bin")
  data = "hello"
  fkey = Wolf::DataWolf.key_create(key_string + Wolf::DataWolf.upper_name_bytes("f.bin"))
  enc = Wolf::DataWolf.xor_cycle(data, fkey, data.bytesize)
  file_table = Wolf::DataWolf.filehead_bytes(0, 0, 0, data.bytesize, 3, Wolf::DataWolf::SENTINEL64)
  dir_table = Wolf::DataWolf.dir_record_bytes(0, Wolf::DataWolf::SENTINEL64, 1, 0)
  head_size = name_table.bytesize + file_table.bytesize + dir_table.bytesize
  head = Wolf::DataWolf.darc_head_bytes(head_size, 64 + head_size, 64,
                                         name_table.bytesize, name_table.bytesize + file_table.bytesize,
                                         Wolf::DataWolf::FLAG_NO_HEAD_PRESS)
  table_blob = Wolf::DataWolf.xor_cycle(name_table + file_table + dir_table, key, 0)

  a = Wolf::DataWolf.new(head + table_blob + enc, key_string: key_string)
  assert_true a.include?("f.bin")
  assert_raise(Wolf::Error) { a.read("f.bin") }
end

assert "Wolf::Project.project? also recognizes a packed Data.wolf" do
  dir = "tmp_wolf_test_data_wolf_detect"
  Dir.mkdir(dir) unless FileTest.directory?(dir)
  begin
    assert_false Wolf::Project.project?(dir)
    File.open("#{dir}/Data.wolf", "wb") { |f| f.write(Wolf::DataWolf.pack([["f.bin", "x"]])) }
    assert_true Wolf::Project.project?(dir)
    assert_equal "#{dir}/Data.wolf", Wolf::DataWolf.find(dir)
  ensure
    File.delete("#{dir}/Data.wolf") if File.exist?("#{dir}/Data.wolf")
    Dir.delete(dir) if FileTest.directory?(dir)
  end
end

# ---- Bit-field decoders ------------------------------------------------------

assert "Wolf::TileFlags decodes passability and priority bits" do
  blocked = Wolf::TileFlags.new(0x0f, 3)
  assert_true blocked.impassable?
  assert_false blocked.passable?
  assert_equal 3, blocked.tag

  passable = Wolf::TileFlags.new(0x00, 0)
  assert_true passable.passable?
  assert_false passable.blocked_down?

  above = Wolf::TileFlags.new(0x10, 0)
  assert_true above.above_characters?
  assert_true above.passable?

  conceal = Wolf::TileFlags.new(0x100, 0)
  assert_true conceal.conceal_behind?
  assert_true conceal.passable?
end

assert "Wolf::Page::Condition#enabled? is bit 0 of the operator byte alone" do
  # A disabled row still carries a real-looking variable reference (the
  # "変数呼び出し値" widget always stores *some* value): 1,000,000 --
  # map-event self-variable 0 of event 0 -- is what the sample game's own
  # untouched condition slots carry, confirmed by dumping real Page bytes
  # (scripts/wolf_interpreter_check.rb's own soak target). Trusting
  # variable/value non-zero-ness as "enabled" (an earlier, unvalidated
  # version of this method did) would treat every one of those as a real
  # condition instead of a blank row.
  off = Wolf::Page::Condition.new(0x20, 1_000_000, 0)
  assert_false off.enabled?

  # The sample game's own treasure-chest page 2 condition: bit 0 set, same
  # otherwise-blank-looking variable, but a non-default value -- real and
  # enabled.
  on = Wolf::Page::Condition.new(0x21, 1_000_000, 1)
  assert_true on.enabled?
  assert_equal 2, on.compare_operator # high nibble: OP_EQ
end

# ---- Map autotile value decoding --------------------------------------------

assert "Wolf::Map.autotile? / .autotile_slot / .autotile_shape split a layer value" do
  assert_false Wolf::Map.autotile?(41)
  assert_true Wolf::Map.autotile?(100000)
  assert_equal 0, Wolf::Map.autotile_slot(100000)
  assert_equal 1, Wolf::Map.autotile_slot(200000)
  assert_equal 1234, Wolf::Map.autotile_shape(101234)
end

# ---- Wolf::ValueRef ----------------------------------------------------------

assert "Wolf::ValueRef.decode resolves the documented value-reference bands" do
  assert_equal [:literal, 5], Wolf::ValueRef.decode(5)
  assert_equal [:literal, -5], Wolf::ValueRef.decode(-5)
  assert_equal [:literal, 999_999], Wolf::ValueRef.decode(999_999)
  assert_equal [:map_event_self, 3, 4], Wolf::ValueRef.decode(1_000_000 + 10 * 3 + 4)
  assert_equal [:this_map_event_self, 2], Wolf::ValueRef.decode(1_100_002)
  assert_equal [:this_common_event_self, 7], Wolf::ValueRef.decode(1_600_007)
  assert_equal [:variable, 0], Wolf::ValueRef.decode(2_000_000)
  assert_equal [:variable, 100_003], Wolf::ValueRef.decode(2_100_003) # reserve bank 1, slot 3
  assert_equal [:string, 12], Wolf::ValueRef.decode(3_000_012)
  assert_equal [:random, 6], Wolf::ValueRef.decode(8_000_006)
  assert_equal [:system_variable, 9], Wolf::ValueRef.decode(9_000_009)
  assert_equal [:system_string, 1], Wolf::ValueRef.decode(9_900_001)
  assert_equal [:common_event_self, 5, 42], Wolf::ValueRef.decode(15_000_000 + 100 * 5 + 42)
  assert_equal [:event_position, 0, 5], Wolf::ValueRef.decode(9_100_005) # event 0, field 5 (shadow number)
  assert_equal [:party_position, 3, 6], Wolf::ValueRef.decode(9_180_036) # who=3 (companion 3), field 6 (direction)
  assert_equal [:this_event_position, 1], Wolf::ValueRef.decode(9_190_001) # field 1 (mapY)
end

assert "Wolf::ValueRef.decode splits the DB triple as 10-AA-BBBB-CC" do
  # User DB type 3 / data 7 / field 2.
  assert_equal [:db, :user, 3, 7, 2], Wolf::ValueRef.decode(1_000_000_000 + 3_000_000 + 700 + 2)
  assert_equal [:db, :changeable, 0, 0, 0], Wolf::ValueRef.decode(1_100_000_000)
  assert_equal [:db, :system, 1, 2, 3], Wolf::ValueRef.decode(1_300_000_000 + 1_000_000 + 200 + 3)
end

assert "Wolf::ValueRef.common_event_self_string? matches the documented 5-9 quintet" do
  assert_false Wolf::ValueRef.common_event_self_string?(4)
  (5..9).each { |i| assert_true Wolf::ValueRef.common_event_self_string?(i) }
  assert_false Wolf::ValueRef.common_event_self_string?(10)
end

# ---- Wolf::VarStore -----------------------------------------------------------

class WolfTestFakeProject
  def databases; {}; end
  # Wolf::Interpreter#update always scans project.common_events.events, even
  # when a test only cares about map events -- an empty stand-in keeps that
  # scan a no-op instead of a NoMethodError.
  def common_events; @common_events ||= Struct.new(:events).new([]); end
  # Wolf::Interpreter#exec_sound_track_db_entry's own lookup, and
  # #exec_database's own (:system/:user/:changeable) -- a plain Hash (type
  # id => a WolfTestFakeSoundTable/WolfTestFakeDBType) mirrors
  # Wolf::Database#[]'s own by-index access closely enough for those.
  def system_db; @system_db ||= {}; end
  def user_db; @user_db ||= {}; end
  def changeable_db; @changeable_db ||= {}; end
  # Wolf::SaveData#path_for's own project-root anchor, for SaveVariable
  # (222)/LoadVariable(221)'s own tests -- a relative scratch directory
  # each of those tests creates and removes itself (mirroring mruby-
  # rpgxp's own "Dir.glob covers..." test), not a fixture.
  def dir; "tmp_wolf_test_save_project"; end
end

# Mirrors Wolf::CommonEvent's own surface Wolf::Interpreter#update needs
# (#id/#run_condition/#auto?/#parallel?/#commands) -- for
# #exec_save_load's own "Load stops every active Run" test, which needs a
# real always-on Common Event driven through #update, not just a bare
# #exec_save_load call.
class WolfTestFakeCommonEvent
  def initialize(id, commands, auto: false)
    @id = id
    @commands = commands
    @auto = auto
  end

  attr_reader :id, :commands

  # Always-met (#condition_met?'s own RUN_PARALLEL_ALWAYS short-circuit,
  # regardless of `auto`) so this never needs a fake condition_variable/
  # value/operator of its own; `auto`/`parallel?` (queried separately, by
  # #start_common_run's own `blocking: ce.auto?`) still pick which of the
  # two real trigger kinds a given instance stands in for.
  def run_condition; Wolf::CommonEvent::RUN_PARALLEL_ALWAYS; end
  def auto?; @auto; end
  def parallel?; !@auto; end
end

# Mirrors Wolf::DBType#value(datum_index, field_index)'s own surface, for
# Wolf::Interpreter#exec_sound_track_db_entry's own BGM/BGS-by-database-
# entry tests.
class WolfTestFakeSoundTable
  def initialize(entries); @entries = entries; end
  def value(datum_index, field_index)
    row = @entries[datum_index]
    row && row[field_index]
  end
end

# Mirrors Wolf::DBField#string?'s own surface.
class WolfTestFakeDBField
  def initialize(string); @string = string; end
  def string?; @string; end
end

# Mirrors Wolf::DBType#field/#value/#set_value's own surface, for
# Wolf::Interpreter#exec_database's own read/write tests. `rows` a Hash of
# datum index => a mutable Hash of field index => value; `fields` a Hash of
# field index => :number/:string (Wolf::DBField#string?'s own surface) -- an
# index missing from `fields` mirrors a real out-of-range field (nil),
# #exec_database's own "log and skip" path for it.
class WolfTestFakeDBType
  def initialize(rows, fields)
    @rows = rows
    @fields = fields
  end
  def field(field_index)
    kind = @fields[field_index]
    kind && WolfTestFakeDBField.new(kind == :string)
  end
  def value(datum_index, field_index)
    row = @rows[datum_index]
    row && row[field_index]
  end
  def set_value(datum_index, field_index, value)
    (@rows[datum_index] ||= {})[field_index] = value
  end
end

assert "Wolf::VarStore reads and writes plain variables/strings" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  assert_equal 0, store.number(2_000_000)
  store.set_number(2_000_000, 42)
  assert_equal 42, store.number(2_000_000)

  assert_equal "", store.string(3_000_005)
  store.set_string(3_000_005, "hello")
  assert_equal "hello", store.string(3_000_005)

  store.set_number(9_000_001, 7)
  assert_equal 7, store.number(9_000_001)
end

assert "Wolf::VarStore keeps each map event's self-variables independent" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(1_000_000 + 10 * 0 + 1, 5) # map event 0, self-var 1
  store.set_number(1_000_000 + 10 * 1 + 1, 9) # map event 1, self-var 1
  assert_equal 5, store.number(1_000_000 + 10 * 0 + 1)
  assert_equal 9, store.number(1_000_000 + 10 * 1 + 1)
end

assert "Wolf::VarStore keys map event self-variables by current_map_id too, not event id alone" do
  # Two different maps' own event id spaces both start from small numbers
  # (0/1/2) and would otherwise collide -- the same reasoning
  # Wolf::Interpreter#event_position's own identical fix (ADR 0089)
  # already applies to a map event's runtime position.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.current_map_id = 100
  store.set_number(1_000_000 + 10 * 0 + 1, 5) # map 100's own event 0, self-var 1

  store.current_map_id = 200
  assert_equal 0, store.number(1_000_000 + 10 * 0 + 1) # map 200's own event 0, untouched
  store.set_number(1_000_000 + 10 * 0 + 1, 7) # map 200's own event 0, self-var 1

  store.current_map_id = 100
  assert_equal 5, store.number(1_000_000 + 10 * 0 + 1) # map 100's own value survived the round trip
end

assert "Wolf::VarStore resolves \"this common event\" self-variables against the running one" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.current_common_event_id = 3
  store.set_number(1_600_002, 11) # this common event's self-var 2
  assert_equal 11, store.common_event_self_bank(3)[2]
  assert_equal 11, store.number(1_600_002)
end

# ---- Wolf::Interpreter --------------------------------------------------------

def wolf_test_cmd(code, args = [], strings = [], indent = 0)
  Wolf::Command.new(code, args, strings, indent)
end

def wolf_test_run(store, commands)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  run = Wolf::Interpreter::Run.new(interp, commands)
  count = 0
  while !run.done && count < 10_000
    run.step
    count += 1
  end
  run
end

assert "Wolf::Interpreter runs SetVariable assignment and addition" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    # V[0] = 5 (calc "nothing" 0xf uses the right side directly, assign "=" 0x0)
    wolf_test_cmd(121, [2_000_000, 0, 5, 0xf000]),
    # V[0] += 3 (calc "nothing" 0xf -- computed is just the right side --
    # assign "+=" 0x1, which adds that to the target's *current* value)
    wolf_test_cmd(121, [2_000_000, 0, 3, 0xf100]),
  ]
  wolf_test_run(store, commands)
  assert_equal 8, store.number(2_000_000)
end

assert "Wolf::Interpreter takes the true branch of a VariableCondition and skips the else" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_000, 1)
  commands = [
    # if V[0] == 1 (case_count=1, no else)
    wolf_test_cmd(111, [0x01, 2_000_000, 1, 2], [], 0),
    wolf_test_cmd(401, [0], [], 0),                  # ChoiceCase 0
    wolf_test_cmd(121, [2_000_001, 0, 111, 0xf000], [], 1), # V[1] = 111 (true branch)
    wolf_test_cmd(420, [0], [], 0),                  # ElseCase
    wolf_test_cmd(121, [2_000_001, 0, 222, 0xf000], [], 1), # V[1] = 222 (false branch)
    wolf_test_cmd(499, [], [], 0),                   # BranchEnd
    wolf_test_cmd(121, [2_000_002, 0, 999, 0xf000], [], 0), # V[2] = 999 (after the branch)
  ]
  wolf_test_run(store, commands)
  assert_equal 111, store.number(2_000_001)
  assert_equal 999, store.number(2_000_002)
end

assert "Wolf::Interpreter takes the else branch when a VariableCondition is false" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_000, 0)
  commands = [
    wolf_test_cmd(111, [0x11, 2_000_000, 1, 2], [], 0), # case_count=1, else_case bit set
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_001, 0, 111, 0xf000], [], 1),
    wolf_test_cmd(420, [0], [], 0),
    wolf_test_cmd(121, [2_000_001, 0, 222, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 222, store.number(2_000_001)
end

assert "Wolf::Interpreter's StartLoop/BreakLoop/LoopEnd repeats until broken" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(170, [], [], 0),                             # StartLoop
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100], [], 1), # V[0] += 1
    # if V[0] >= 3, break
    wolf_test_cmd(111, [0x01, 2_000_000, 3, 1], [], 1),
    wolf_test_cmd(401, [0], [], 1),
    wolf_test_cmd(171, [], [], 2), # BreakLoop
    wolf_test_cmd(499, [], [], 1),
    wolf_test_cmd(498, [], [], 0), # LoopEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 3, store.number(2_000_000)
end

assert "Wolf::Interpreter's SetLabel/JumpLabel jumps by name" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(213, [], ["skip"], 0),                        # JumpLabel "skip"
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 0),       # never runs
    wolf_test_cmd(212, [], ["skip"], 0),                        # SetLabel "skip"
    wolf_test_cmd(121, [2_000_000, 0, 2, 0xf000], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 2, store.number(2_000_000)
end

assert "Wolf::Interpreter's Wait suspends the Run across #step calls" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(180, [3], [], 0), # Wait 3 frames
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 0),
  ]
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  run = Wolf::Interpreter::Run.new(interp, commands)
  3.times do
    run.step
    assert_equal 0, store.number(2_000_000)
  end
  run.step
  assert_equal 1, store.number(2_000_000)
  assert_true run.done
end

assert "Wolf::Interpreter's VariableCondition falls through to a sibling command when no case matches and there is no else" do
  # Regression test for a real hang found against the sample game's own
  # "メッセージウィンドウ" Common Event: a VariableCondition with a single
  # case, no ElseCase, whose condition is false must resume execution right
  # after its own BranchEnd -- not keep scanning for some other branch
  # marker further down and skip whatever sibling commands (here, the
  # increment) sit between BranchEnd and the next real marker.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(111, [0x01, 2_000_000, 1, 2], [], 0), # if V[0] == 1 (false; V[0] starts at 0)
    wolf_test_cmd(401, [0], [], 0),                      # ChoiceCase 0
    wolf_test_cmd(121, [2_000_001, 0, 111, 0xf000], [], 1), # never runs
    wolf_test_cmd(499, [], [], 0),                       # BranchEnd
    wolf_test_cmd(121, [2_000_002, 0, 999, 0xf000], [], 0), # sibling command after BranchEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 0, store.number(2_000_001)
  assert_equal 999, store.number(2_000_002)
end

assert "Wolf::Interpreter takes the true branch of a StringCondition (literal Equals)" do
  # Real data (33 calls) confirms `arg(0)`'s low nibble is the case count,
  # a lone condition's own literal comparison text sits at string slot 0,
  # and every real call leaves `value_is_variable` (the packed word's own
  # low bit) unset -- see #exec_string_condition's own comment.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_string(3_000_000, "hello")
  commands = [
    # if S[0] == "hello" (case_count=1, no else, Equals)
    wolf_test_cmd(112, [0x01, 3_000_000], ["hello"], 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 111, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 111, store.number(2_000_000)
end

assert "Wolf::Interpreter takes the else branch when a StringCondition is false" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_string(3_000_000, "hello")
  commands = [
    # if S[0] == "goodbye" (false; case_count=1, else_case bit set)
    wolf_test_cmd(112, [0x11, 3_000_000], ["goodbye"], 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 111, 0xf000], [], 1),
    wolf_test_cmd(420, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 222, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 222, store.number(2_000_000)
end

assert "Wolf::Interpreter's StringCondition falls through when no case matches and there is no else" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_string(3_000_000, "hello")
  commands = [
    wolf_test_cmd(112, [0x01, 3_000_000], ["goodbye"], 0), # S[0] == "goodbye" -- false
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 111, 0xf000], [], 1), # never runs
    wolf_test_cmd(499, [], [], 0),
    wolf_test_cmd(121, [2_000_001, 0, 999, 0xf000], [], 0), # sibling command after BranchEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 0, store.number(2_000_000)
  assert_equal 999, store.number(2_000_001)
end

assert "Wolf::Interpreter's StringCondition picks the second of two real cases" do
  # Mirrors CE#94's own real 2-condition shape (case_count=2): each
  # condition's own literal comparison text reads from the condition's own
  # string slot (0 and 1), not a string-only running counter shared with
  # any `value_is_variable` condition -- confirmed here by making only the
  # *second* condition's own literal match.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_string(3_000_000, "hello")
  commands = [
    wolf_test_cmd(112, [0x02, 3_000_000, 3_000_000], ["wrong", "hello"], 0),
    wolf_test_cmd(401, [0], [], 0), # ChoiceCase 0: S[0] == "wrong" -- false
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 1), # never runs
    wolf_test_cmd(401, [1], [], 0), # ChoiceCase 1: S[0] == "hello" -- true
    wolf_test_cmd(121, [2_000_000, 0, 2, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 2, store.number(2_000_000)
end

assert "Wolf::Interpreter's StringCondition Includes/StartsWith operators" do
  # Not exercised by any real call in the sample game (every real call is
  # Equals/NotEquals) but implemented from the same `CompareOperator` enum
  # the crate's own struct documents; tested directly rather than left
  # unconfirmed.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_string(3_000_000, "hello world")
  includes_var = (2 << 28) | 3_000_000 # CompareOperator::Includes
  commands = [
    wolf_test_cmd(112, [0x01, includes_var], ["lo wor"], 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)

  store2 = Wolf::VarStore.new(WolfTestFakeProject.new)
  store2.set_string(3_000_000, "hello world")
  starts_with_var = (3 << 28) | 3_000_000 # CompareOperator::StartsWith
  commands2 = [
    wolf_test_cmd(112, [0x01, starts_with_var], ["hello"], 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store2, commands2)
  assert_equal 1, store2.number(2_000_000)
end

assert "Wolf::Interpreter's StringCondition resolves \"this common event\" self-var strings" do
  # Real data's own dominant shape (32 of 33 calls): a lone condition
  # comparing `1_600_00X` (this common event's own self-var string band,
  # 5-9) against a literal.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.current_common_event_id = 7
  store.set_string(1_600_007, "picked") # self-var 7 (string band), this common event
  commands = [
    wolf_test_cmd(112, [0x01, 1_600_007], ["picked"], 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
end

assert "Wolf::Interpreter's StringCondition value_is_variable compares two string variables" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_string(3_000_000, "match")
  store.set_string(3_000_001, "match")
  # top byte: value_is_variable bit (0x01) set, CompareOperator::Equals (0x00 nibble)
  packed = (0x01 << 24) | 3_000_000
  commands = [
    wolf_test_cmd(112, [0x01, packed, 3_000_001], [], 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
end

assert "Wolf::Interpreter's GotoLoopStart(176) restarts the loop without running the rest of the iteration" do
  # Cross-confirmed as "return to loop start" (04ev_control.html) against
  # WolfTL's Command.hpp (StartLoop2 = 176) and the wolfrpg-map-parser
  # crate's own signature table (GotoLoopStart = 0x01b0_0000 = code 176).
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(170, [], [], 0),                              # StartLoop
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100], [], 1),  # V[0] += 1
    wolf_test_cmd(111, [0x01, 2_000_000, 3, 1], [], 1),          # if V[0] >= 3
    wolf_test_cmd(401, [0], [], 1),
    wolf_test_cmd(171, [], [], 2),                               # BreakLoop
    wolf_test_cmd(499, [], [], 1),
    wolf_test_cmd(176, [], [], 1),                               # GotoLoopStart: skip the line below every iteration
    wolf_test_cmd(121, [2_000_001, 0, 1, 0xf100], [], 1),  # V[1] += 1; should never run
    wolf_test_cmd(498, [], [], 0),                               # LoopEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 3, store.number(2_000_000)
  assert_equal 0, store.number(2_000_001)
end

assert "Wolf::Interpreter's BreakEvent(172) stops the rest of the event's own commands" do
  # "イベント処理中断" (04ev_control.html): "以降のイベントコマンドを無視
  # して、イベントを終了します" [ignores every subsequent event command
  # and ends the event]. 303 real calls, every one a bare `args=[],
  # strings=[]` marker -- no packed layout to get wrong.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 0),
    wolf_test_cmd(172, [], [], 0), # BreakEvent
    wolf_test_cmd(121, [2_000_000, 0, 2, 0xf000], [], 0), # never runs
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
end

assert "Wolf::Interpreter's BreakEvent(172) ends the whole event even from inside a nested loop/branch" do
  # The manual's own wording is "ends the event," not "ends the current
  # loop/branch" -- confirmed here by nesting BreakEvent three levels deep
  # (StartLoop > VariableCondition > BreakEvent) and checking that nothing
  # after any of those constructs' own closing markers runs either.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(170, [], [], 0),                        # StartLoop
    wolf_test_cmd(111, [0x01, 2_000_000, 0, 2], [], 1),    # if V[0] == 0 (true)
    wolf_test_cmd(401, [0], [], 1),
    wolf_test_cmd(172, [], [], 2),                         # BreakEvent
    wolf_test_cmd(121, [2_000_000, 0, 111, 0xf000], [], 2), # never runs
    wolf_test_cmd(499, [], [], 1),                          # BranchEnd
    wolf_test_cmd(498, [], [], 0),                          # LoopEnd
    wolf_test_cmd(121, [2_000_000, 0, 222, 0xf000], [], 0), # never runs either
  ]
  wolf_test_run(store, commands)
  assert_equal 0, store.number(2_000_000)
end

assert "Wolf::Interpreter's Blank(0) is a no-op that does not disturb its siblings" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 0),
    wolf_test_cmd(0, [], [], 0), # Blank
    wolf_test_cmd(121, [2_000_001, 0, 2, 0xf000], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
  assert_equal 2, store.number(2_000_001)
end

assert "Wolf::Interpreter's Checkpoint(99) is a no-op regardless of its own \"特モード\" argument" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 0),
    wolf_test_cmd(99, [0], [], 0), # Checkpoint
    wolf_test_cmd(99, [1], [], 0), # Checkpoint, "特モード"
    wolf_test_cmd(121, [2_000_001, 0, 2, 0xf000], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
  assert_equal 2, store.number(2_000_001)
end

assert "Wolf::Interpreter's WaitForMove(202) is a no-op, since SetMoveRoute already applies instantly" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 0),
    wolf_test_cmd(202, [], [], 0), # WaitForMove
    wolf_test_cmd(121, [2_000_001, 0, 2, 0xf000], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
  assert_equal 2, store.number(2_000_001)
end

# ---- Wolf::Interpreter LoopTimes(179) ----------------------------------------

assert "Wolf::Interpreter's LoopTimes(179) repeats exactly the configured (possibly variable-held) count" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_002, 3)
  commands = [
    wolf_test_cmd(179, [2_000_002], [], 0),                     # LoopTimes V[2] (3)
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100], [], 1), # V[0] += 1
    wolf_test_cmd(498, [], [], 0),                               # LoopEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 3, store.number(2_000_000)
end

assert "Wolf::Interpreter's LoopTimes(179) never runs its body for 0 (or fewer) iterations" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(179, [0], [], 0),                              # LoopTimes 0
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100], [], 1),
    wolf_test_cmd(498, [], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 0, store.number(2_000_000)
end

assert "Wolf::Interpreter's BreakLoop exits a LoopTimes loop early, clearing its remaining count" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(179, [5], [], 0),                              # LoopTimes 5
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100], [], 1),  # V[0] += 1
    wolf_test_cmd(111, [0x01, 2_000_000, 2, 1], [], 1),          # if V[0] >= 2
    wolf_test_cmd(401, [0], [], 1),
    wolf_test_cmd(171, [], [], 2),                               # BreakLoop
    wolf_test_cmd(499, [], [], 1),
    wolf_test_cmd(498, [], [], 0),                               # LoopEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 2, store.number(2_000_000)
end

assert "Wolf::Interpreter's GotoLoopStart consumes one LoopTimes iteration, matching reaching LoopEnd" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(179, [3], [], 0),                              # LoopTimes 3
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100], [], 1),  # V[0] += 1
    wolf_test_cmd(176, [], [], 1),                               # GotoLoopStart
    wolf_test_cmd(121, [2_000_001, 0, 1, 0xf100], [], 1),  # V[1] += 1; should never run
    wolf_test_cmd(498, [], [], 0),                               # LoopEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 3, store.number(2_000_000)
  assert_equal 0, store.number(2_000_001)
end

assert "Wolf::Interpreter's JumpLabel landing inside a LoopTimes body from outside it runs exactly once" do
  # 04ev_control.html's own documented gotcha: a label jump into a
  # count-loop from outside never initializes its own remaining-count
  # tracking, so the loop ends after one iteration regardless of the
  # configured count.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(213, [], ["go"], 0),                           # JumpLabel "go"
    wolf_test_cmd(179, [5], [], 1),                              # LoopTimes 5
    wolf_test_cmd(212, [], ["go"], 2),                           # SetLabel "go"
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100], [], 2),  # V[0] += 1
    wolf_test_cmd(498, [], [], 1),                               # LoopEnd
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
end

# ---- Wolf::Interpreter map events ----------------------------------------

# Minimal doubles for Wolf::Page/Wolf::Event: Interpreter only ever reads
# id/x/y/pages off an event and trigger/conditions/commands/auto?/parallel?/
# slip_through?/above_hero? off a page, so these mirror just that surface
# rather than round-tripping real Reader-parsed objects through this test.
WolfTestPage = Struct.new(:trigger, :conditions, :commands, :opts, :move_type, :move_frequency, :route, :route_options) do
  def auto?; trigger == Wolf::Page::TRIGGER_AUTO; end
  def parallel?; trigger == Wolf::Page::TRIGGER_PARALLEL; end
  def slip_through?; (opts || 0) & Wolf::Page::OPT_SLIP_THROUGH != 0; end
  def above_hero?; (opts || 0) & Wolf::Page::OPT_ABOVE_HERO != 0; end
end
WolfTestEvent = Struct.new(:id, :x, :y, :pages)
WolfTestMap = Struct.new(:events)
# Mirrors Wolf::RouteCommand's own attr_reader :id, :args surface.
WolfTestRouteCommand = Struct.new(:id, :args)

def wolf_test_page(trigger, conditions: [], commands: [], opts: 0,
                    move_type: Wolf::Page::MOVE_NONE, move_frequency: 3, route: [], route_options: 0)
  WolfTestPage.new(trigger, conditions, commands, opts, move_type, move_frequency, route, route_options)
end

def wolf_test_cond(operator, variable, value)
  Wolf::Page::Condition.new(operator, variable, value)
end

assert "Wolf::Interpreter#active_page picks the last page whose conditions all hold" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  page0 = wolf_test_page(Wolf::Page::TRIGGER_CONFIRM)
  page1 = wolf_test_page(Wolf::Page::TRIGGER_CONFIRM,
                          conditions: [wolf_test_cond(0x21, 2_000_000, 1)]) # enabled: V[0] == 1
  event = WolfTestEvent.new(0, 3, 4, [page0, page1])

  idx, page = interp.active_page(event)
  assert_equal 0, idx
  assert_equal page0, page

  store.set_number(2_000_000, 1)
  idx, page = interp.active_page(event)
  assert_equal 1, idx
  assert_equal page1, page
end

assert "Wolf::Interpreter#active_page returns nil when no page's conditions hold" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  page0 = wolf_test_page(Wolf::Page::TRIGGER_CONFIRM,
                          conditions: [wolf_test_cond(0x21, 2_000_000, 1)])
  event = WolfTestEvent.new(0, 0, 0, [page0])
  assert_nil interp.active_page(event)
end

assert "Wolf::Interpreter#update restarts a Parallel map event page every time it finishes" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL,
                         commands: [wolf_test_cmd(121, [2_000_000, 0, 1, 0xf100])]) # V[0] += 1
  event = WolfTestEvent.new(0, 1, 1, [page])
  interp.current_map = WolfTestMap.new([event])

  interp.update
  assert_equal 1, store.number(2_000_000)
  interp.update
  assert_equal 2, store.number(2_000_000)
end

assert "Wolf::Interpreter#blocking? is true only while a non-Parallel map event page is running" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  waiting_page = wolf_test_page(Wolf::Page::TRIGGER_AUTO, commands: [wolf_test_cmd(180, [5])])
  event = WolfTestEvent.new(0, 1, 1, [waiting_page])
  interp.current_map = WolfTestMap.new([event])

  assert_false interp.blocking?
  interp.update # starts the Auto page; it Waits immediately, so it is still live
  assert_true interp.blocking?

  parallel_page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL, commands: [wolf_test_cmd(180, [5])])
  event2 = WolfTestEvent.new(1, 2, 2, [parallel_page])
  interp2 = Wolf::Interpreter.new(WolfTestFakeProject.new, Wolf::VarStore.new(WolfTestFakeProject.new))
  interp2.current_map = WolfTestMap.new([event2])
  interp2.update
  assert_false interp2.blocking?
end

assert "Wolf::Interpreter#trigger_confirm/#trigger_touch start their page only on demand, not via #update" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  confirm_page = wolf_test_page(Wolf::Page::TRIGGER_CONFIRM,
                                 commands: [wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000])])
  touch_page = wolf_test_page(Wolf::Page::TRIGGER_PLAYER_TOUCH,
                               commands: [wolf_test_cmd(121, [2_000_001, 0, 1, 0xf000])])
  confirm_event = WolfTestEvent.new(0, 1, 1, [confirm_page])
  touch_event = WolfTestEvent.new(1, 2, 2, [touch_page])
  interp.current_map = WolfTestMap.new([confirm_event, touch_event])

  interp.update # a Confirm/Player-Touch page must never run just from #update
  assert_equal 0, store.number(2_000_000)
  assert_equal 0, store.number(2_000_001)

  assert_true interp.trigger_confirm(confirm_event)
  assert_equal 1, store.number(2_000_000)

  found_event, found_page = interp.event_at(2, 2)
  assert_equal touch_event, found_event
  assert_equal touch_page, found_page
  assert_true interp.trigger_touch(touch_event)
  assert_equal 1, store.number(2_000_001)

  assert_nil interp.event_at(9, 9)
end

# ---- Wolf::Interpreter event movement ---------------------------------------

# Records calls instead of touching RGSS (unavailable under this CRuby test
# harness) -- exactly the seam Wolf::Interpreter#current_scene exists for.
# Also stands in for WolfRPG::MapScene's own hero-position/passability
# surface (#x/#y/#passable?/#hero_at?/#hero_pos/#hero_pos=), which
# Interpreter's event-movement code reads and writes.
class WolfTestFakeScene
  attr_reader :shown, :shown_files, :shown_shapes, :moved, :erased, :played_se, :played_tracks, :stopped_tracks,
              :shifted, :tinted, :changed_colors, :flickered, :flashed, :shaken, :character_flashed,
              :character_shaken
  attr_accessor :x, :y, :blocked, :choice_inputs, :keys_down

  def initialize
    @shown = []
    @shown_files = []
    @shown_shapes = []
    @moved = []
    @erased = []
    @x = 0
    @y = 0
    @facing = :down
    @blocked = []
    @choice_inputs = []
    @played_se = []
    @played_tracks = []
    @stopped_tracks = []
    @keys_down = []
    @shifted = []
    @tinted = []
    @changed_colors = []
    @flickered = []
    @flashed = []
    @shaken = []
    @character_flashed = []
    @character_shaken = []
  end

  def show_string_picture(*args); @shown << args; end
  def show_file_picture(*args); @shown_files << args; end
  def show_shape_picture(*args); @shown_shapes << args; end
  def move_picture(*args); @moved << args; end
  def erase_picture(number); @erased << number; end
  # Wolf::Interpreter#exec_effect's own Picture-target seam.
  def shift_picture(number, dx, dy); @shifted << [number, dx, dy]; end
  def tint_picture(number, r, g, b); @tinted << [number, r, g, b]; end
  def set_picture_flicker(number, interval, r, g, b); @flickered << [number, interval, r, g, b]; end
  def flash_picture(number, r, g, b, duration); @flashed << [number, r, g, b, duration]; end
  def set_picture_shake(number, interval, dx, dy, count); @shaken << [number, interval, dx, dy, count]; end
  def flash_character(sprite_key, r, g, b, duration); @character_flashed << [sprite_key, r, g, b, duration]; end
  def shake_character(sprite_key, interval, dx, dy, count)
    @character_shaken << [sprite_key, interval, dx, dy, count]
  end
  # Wolf::Interpreter#exec_change_color's own seam.
  def change_color(r, g, b, flash, duration); @changed_colors << [r, g, b, flash, duration]; end
  # Wolf::Interpreter::Run#exec_choices' own input seam -- a caller queues
  # the sequence of key presses to hand back, one per call, `nil` (nothing
  # queued) standing in for a frame nothing was pressed.
  def choice_input; @choice_inputs.shift; end
  def play_se(*args); @played_se << args; end
  def play_track(*args); @played_tracks << args; end
  def stop_track(operation); @stopped_tracks << operation; end
  # Wolf::Interpreter::Run#exec_input_key's own input seam -- a caller sets
  # `keys_down` to whichever symbols (:up/:down/:left/:right/:confirm/
  # :cancel/:subkey) should currently read as pressed.
  def input_key_pressed?(kind); @keys_down.include?(kind); end

  def passable?(x, y); !@blocked.include?([x, y]); end
  def hero_at?(x, y); x == @x && y == @y; end
  def hero_pos; { x: @x, y: @y, direction: @facing }; end
  def hero_pos=(pos); @x = pos[:x]; @y = pos[:y]; @facing = pos[:direction]; end
end

assert "Wolf::Interpreter#run_route_commands moves/faces/turns per the confirmed RouteCommand ids" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  pos = { x: 5, y: 5, direction: :down }
  interp.run_route_commands(pos, [
    WolfTestRouteCommand.new(2, []),  # MoveRight
    WolfTestRouteCommand.new(9, []),  # FaceLeft
    WolfTestRouteCommand.new(22, []), # TurnRight: left -> up (help/Ev_routeset.png's own cycle)
    WolfTestRouteCommand.new(19, []), # StepForward, in the now-"up" facing
  ])
  assert_equal 6, pos[:x]
  assert_equal 4, pos[:y]
  assert_equal :up, pos[:direction]
end

assert "Wolf::Interpreter#run_route_commands skips a RouteCommand id this reader could not cross-confirm" do
  # Real command dumps from the sample game carry ids (e.g. 47) this reader
  # could not place in the wolfrpg-map-parser crate's own MoveType table --
  # logged and skipped rather than guessed (interpreter.rb's own comment).
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  pos = { x: 1, y: 1, direction: :down }
  interp.run_route_commands(pos, [WolfTestRouteCommand.new(47, [2])])
  assert_equal 1, pos[:x]
  assert_equal 1, pos[:y]
  assert_equal :down, pos[:direction]
end

assert "Wolf::Interpreter#update_event_movement applies a Custom page's own route once, on activation" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL,
                         move_type: Wolf::Page::MOVE_CUSTOM,
                         route: [WolfTestRouteCommand.new(0, [])]) # MoveDown
  event = WolfTestEvent.new(0, 3, 3, [page])

  idx, active = interp.active_page(event)
  interp.update_event_movement(event, idx, active)
  pos = interp.event_position(event)
  assert_equal 4, pos[:y]

  # The page is still the active one on the next frame; its route must not
  # re-apply just because #update_event_movement is called again.
  interp.update_event_movement(event, idx, active)
  assert_equal 4, pos[:y]
end

assert "Wolf::Interpreter#update_event_movement re-triggers a repeating Custom route " \
       "from its start on a move_frequency cadence, forever" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.current_scene = WolfTestFakeScene.new
  page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL,
                         move_type: Wolf::Page::MOVE_CUSTOM,
                         route: [WolfTestRouteCommand.new(0, [])], # MoveDown
                         move_frequency: 3,
                         route_options: 0x01) # "動作を繰り返す" (repeat)
  event = WolfTestEvent.new(0, 3, 3, [page])
  idx, active = interp.active_page(event)
  pos = interp.event_position(event)

  # Activation runs the route once immediately, same as a non-repeating one.
  interp.update_event_movement(event, idx, active)
  assert_equal 4, pos[:y]

  # #move_pause_frames(3) = 8: the route must not re-run before the pause
  # elapses (the same "N.times then one more" cadence the TowardHero test
  # above already exercises for #tick_ambient_move -- not a fresh guess),
  # then re-runs from its start once it does -- not just once, and not on
  # every frame.
  8.times { interp.update_event_movement(event, idx, active) }
  assert_equal 4, pos[:y] # still paused

  interp.update_event_movement(event, idx, active)
  assert_equal 5, pos[:y] # the pause elapsed; the route ran again

  8.times { interp.update_event_movement(event, idx, active) }
  assert_equal 5, pos[:y] # paused again
  interp.update_event_movement(event, idx, active)
  assert_equal 6, pos[:y] # and again
end

assert "Wolf::Interpreter#update_event_movement does not repeat a non-repeating Custom route" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.current_scene = WolfTestFakeScene.new
  page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL,
                         move_type: Wolf::Page::MOVE_CUSTOM,
                         route: [WolfTestRouteCommand.new(0, [])],
                         route_options: 0) # no repeat bit
  event = WolfTestEvent.new(0, 3, 3, [page])
  idx, active = interp.active_page(event)
  pos = interp.event_position(event)

  interp.update_event_movement(event, idx, active)
  assert_equal 4, pos[:y]

  20.times { interp.update_event_movement(event, idx, active) }
  assert_equal 4, pos[:y] # never repeats, however many frames pass
end

assert "Wolf::Interpreter#update_event_movement steps a TowardHero page toward the hero on a move_frequency cadence" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.x = 10
  scene.y = 0
  interp.current_scene = scene
  page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL, move_type: Wolf::Page::MOVE_TOWARD_HERO, move_frequency: 3)
  event = WolfTestEvent.new(0, 0, 0, [page])
  idx, active = interp.active_page(event)
  pos = interp.event_position(event)

  # A newly-active page's own move_timer starts at 0, so the very first call
  # steps immediately; #move_pause_frames(3) = 8 then holds it for 8 frames
  # (interpreter.rb's own comment: not a decoded constant, a reasonable
  # decreasing-interval stand-in).
  interp.update_event_movement(event, idx, active)
  assert_equal 1, pos[:x]
  assert_equal :right, pos[:direction]

  8.times { interp.update_event_movement(event, idx, active) }
  assert_equal 1, pos[:x] # still paused

  interp.update_event_movement(event, idx, active)
  assert_equal 2, pos[:x] # the pause elapsed; one more step
end

assert "Wolf::Interpreter#update_event_movement's Random movement respects the map's own passable tiles" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.blocked = [[1, 0], [-1, 0], [0, 1], [0, -1]] # every neighbour of (0, 0) is blocked
  interp.current_scene = scene
  page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL, move_type: Wolf::Page::MOVE_RANDOM, move_frequency: 7)
  event = WolfTestEvent.new(0, 0, 0, [page])
  idx, active = interp.active_page(event)
  pos = interp.event_position(event)

  # Whichever direction #random_step_delta happens to sample, every
  # neighbour is blocked -- the event must stay put no matter how many
  # attempts it gets.
  20.times { interp.update_event_movement(event, idx, active) }
  assert_equal 0, pos[:x]
  assert_equal 0, pos[:y]
end

assert "Wolf::Interpreter#exec_set_move_route resolves \"this event\"/an explicit event id/the hero as SetMoveRoute(201)'s target" do
  # help/04ev_movesettingB.html's own documented target convention: >=0 an
  # event id, -1 this event, -2 the hero, -3..-7 a party member (no party
  # system exists yet, so that last band is logged and skipped).
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  self_event = WolfTestEvent.new(3, 1, 1, [])
  other_event = WolfTestEvent.new(7, 5, 5, [])
  interp.current_map = WolfTestMap.new([self_event, other_event])
  store.current_map_event_id = 3

  self_cmd = wolf_test_cmd(201, [-1])
  self_cmd.route = [WolfTestRouteCommand.new(0, [])] # MoveDown
  interp.exec_set_move_route(self_cmd)
  assert_equal 2, interp.event_position(self_event)[:y]

  other_cmd = wolf_test_cmd(201, [7])
  other_cmd.route = [WolfTestRouteCommand.new(2, [])] # MoveRight
  interp.exec_set_move_route(other_cmd)
  assert_equal 6, interp.event_position(other_event)[:x]

  hero_cmd = wolf_test_cmd(201, [-2])
  hero_cmd.route = [WolfTestRouteCommand.new(3, [])] # MoveUp
  interp.exec_set_move_route(hero_cmd)
  assert_equal(-1, scene.y)

  party_cmd = wolf_test_cmd(201, [-3])
  party_cmd.route = [WolfTestRouteCommand.new(0, [])]
  interp.exec_set_move_route(party_cmd) # must not raise
  assert_equal 0, scene.x
end

assert "Wolf::Interpreter#event_position keys by [current_map_id, event.id], not event.id alone" do
  # Two different maps' own event id spaces both start from small numbers
  # (0/1/2) and would otherwise collide -- Teleport(130)/SaveLoad(220)'s
  # own Load both replace current_map/current_map_id without clearing
  # @event_positions, so a revisited map must find its own events exactly
  # where they were left, not some *other* map's same-id event's position.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)

  event_a = WolfTestEvent.new(5, 1, 1, [])
  interp.current_map = WolfTestMap.new([event_a])
  interp.current_map_id = 100
  pos_a = interp.event_position(event_a)
  pos_a[:x] = 9 # moved on map 100

  event_b = WolfTestEvent.new(5, 2, 2, []) # same event id, a different map
  interp.current_map = WolfTestMap.new([event_b])
  interp.current_map_id = 200
  pos_b = interp.event_position(event_b)
  assert_equal 2, pos_b[:x] # its own real starting x, unaffected by map 100's own move

  interp.current_map = WolfTestMap.new([event_a])
  interp.current_map_id = 100
  assert_equal 9, interp.event_position(event_a)[:x] # map 100's own move survived the round trip
  assert_equal 100, store.current_map_id # Interpreter#current_map_id= also keeps VarStore in sync
end

# ---- Wolf::Interpreter#exec_set_variable_ex (SetVariableEx(124)) ------------

def wolf_test_var_ex_header(assign_op: 0, var_type: Wolf::Interpreter::SET_VAR_EX_TYPE_CHARACTER)
  ((assign_op & 0x0f) << 8) | ((var_type & 0x0f) << 12)
end

assert "Wolf::Interpreter#exec_set_variable_ex reads standard/precise X/Y and direction off an explicit event id" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  event = WolfTestEvent.new(7, 5, 6, [])
  interp.current_map = WolfTestMap.new([event])
  pos = interp.event_position(event)
  pos[:direction] = :left

  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_000, wolf_test_var_ex_header, 7, 0])) # StandardX
  assert_equal 5, store.number(2_000_000)
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_001, wolf_test_var_ex_header, 7, 1])) # StandardY
  assert_equal 6, store.number(2_000_001)
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_002, wolf_test_var_ex_header, 7, 2])) # PreciseX
  assert_equal 10, store.number(2_000_002)
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_003, wolf_test_var_ex_header, 7, 3])) # PreciseY
  assert_equal 11, store.number(2_000_003)
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_004, wolf_test_var_ex_header, 7, 5])) # Direction
  assert_equal 4, store.number(2_000_004) # numpad 4 = left
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_005, wolf_test_var_ex_header, 7, 10])) # EventId
  assert_equal 7, store.number(2_000_005)
end

assert "Wolf::Interpreter#exec_set_variable_ex resolves \"this event\" and the hero the same way SetMoveRoute(201) does" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.x = 3
  scene.y = 4
  interp.current_scene = scene
  self_event = WolfTestEvent.new(9, 1, 1, [])
  interp.current_map = WolfTestMap.new([self_event])
  store.current_map_event_id = 9

  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_000, wolf_test_var_ex_header, -1, 0])) # self, StandardX
  assert_equal 1, store.number(2_000_000)

  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_001, wolf_test_var_ex_header, -2, 0])) # hero, StandardX
  assert_equal 3, store.number(2_000_001)
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_002, wolf_test_var_ex_header, -2, 10])) # hero has no event id
  assert_equal(-1, store.number(2_000_002))
end

assert "Wolf::Interpreter#exec_set_variable_ex applies the shared assignment-operator word, matching a real DivideEquals call" do
  # map1 ev#23's own "メッセージウィンドウ" Common Event carries exactly this
  # combination for real: PictureNumber type with assign_op DivideEquals --
  # unimplemented here (only Character type is), but the operator itself
  # (shared with SetVariable(121) via #apply_assign_op) is exercised here
  # against a Character-type field instead, so the real 4/=-style call this
  # reader *can* answer is still covered end to end.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_000, 20)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  event = WolfTestEvent.new(1, 4, 0, [])
  interp.current_map = WolfTestMap.new([event])

  header = wolf_test_var_ex_header(assign_op: 4) # /=
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_000, header, 1, 0])) # StandardX = 4
  assert_equal 5, store.number(2_000_000) # 20 / 4
end

assert "Wolf::Interpreter#exec_set_variable_ex skips a variable type/field/argument-count/target it does not understand" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  event = WolfTestEvent.new(1, 0, 0, [])
  interp.current_map = WolfTestMap.new([event])

  other_type = wolf_test_var_ex_header(var_type: 3) # Other, not implemented
  interp.exec_set_variable_ex(wolf_test_cmd(124, [2_000_000, other_type, 1, 0]))
  assert_equal 0, store.number(2_000_000)

  unknown_field = wolf_test_cmd(124, [2_000_001, wolf_test_var_ex_header, 1, 4]) # HeightOffGround, not implemented
  interp.exec_set_variable_ex(unknown_field)
  assert_equal 0, store.number(2_000_001)

  odd_argc = wolf_test_cmd(124, [2_000_002, wolf_test_var_ex_header, 1])
  interp.exec_set_variable_ex(odd_argc)
  assert_equal 0, store.number(2_000_002)

  no_such_event = wolf_test_cmd(124, [2_000_003, wolf_test_var_ex_header, 99, 0])
  interp.exec_set_variable_ex(no_such_event)
  assert_equal 0, store.number(2_000_003)
end

# ---- Wolf::Interpreter#exec_choices (Choices(102)) --------------------------

def wolf_test_choice_options(selected:, cancel: Wolf::Interpreter::CHOICE_CANCEL_SEPARATE, extra: 0)
  (selected & 0x0f) | ((cancel & 0x0f) << 4) | ((extra & 0x07) << 8)
end

# A two-choice Choices with a separate CancelCase branch -- the exact shape
# `map1 ev#23`'s own real Choices command has (opt=2: selected=2, cancel=0
# "separate", extra=0), cross-checked by hand against what actually follows
# it in the sample game's own data (two ChoiceCase(401) markers, each own
# body ending in a real command, then a CancelCase(421), then BranchEnd).
def wolf_test_choice_commands(cancel: Wolf::Interpreter::CHOICE_CANCEL_SEPARATE, texts: ["A", "B"])
  options = wolf_test_choice_options(selected: texts.size, cancel: cancel)
  [
    wolf_test_cmd(102, [options], texts, 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 1), # V[0] = 1 (choice A)
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 2, 0xf000], [], 1), # V[0] = 2 (choice B)
    wolf_test_cmd(421, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 3, 0xf000], [], 1), # V[0] = 3 (canceled)
    wolf_test_cmd(499, [], [], 0),
    wolf_test_cmd(121, [2_000_001, 0, 9, 0xf000], [], 0), # after the whole construct
  ]
end

assert "Wolf::Interpreter#exec_choices waits for a Fiber.yield-driven confirm and dispatches the chosen ChoiceCase" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  run = Wolf::Interpreter::Run.new(interp, wolf_test_choice_commands)

  run.step # dispatches Choices(102); its own first Fiber.yield returns here without polling input yet
  assert_equal 0, store.number(2_000_000) # still waiting; nothing ran yet

  scene.choice_inputs = [:confirm] # confirm on the default cursor (choice A)
  count = 0
  run.step while !run.done && (count += 1) < 20
  assert_equal 1, store.number(2_000_000)
  assert_equal 9, store.number(2_000_001) # falls through past the whole construct afterward
end

assert "Wolf::Interpreter#exec_choices moves the cursor with up/down before confirming" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  run = Wolf::Interpreter::Run.new(interp, wolf_test_choice_commands)

  run.step
  scene.choice_inputs = [:down, :confirm] # move to choice B, then pick it
  count = 0
  run.step while !run.done && (count += 1) < 20
  assert_equal 2, store.number(2_000_000)
end

assert "Wolf::Interpreter#exec_choices cancel (\"separate\" behaviour) runs the CancelCase branch" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  run = Wolf::Interpreter::Run.new(interp, wolf_test_choice_commands(cancel: Wolf::Interpreter::CHOICE_CANCEL_SEPARATE))

  run.step
  scene.choice_inputs = [:cancel]
  count = 0
  run.step while !run.done && (count += 1) < 20
  assert_equal 3, store.number(2_000_000)
end

assert "Wolf::Interpreter#exec_choices ignores the cancel key when cancel is disabled" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  run = Wolf::Interpreter::Run.new(interp, wolf_test_choice_commands(cancel: Wolf::Interpreter::CHOICE_CANCEL_DISABLED))

  run.step
  scene.choice_inputs = [:cancel, :cancel, :confirm] # both cancels are no-ops; confirm still picks choice A
  count = 0
  run.step while !run.done && (count += 1) < 20
  assert_equal 1, store.number(2_000_000)
end

assert "Wolf::Interpreter#exec_choices' \"cancel acts as choice N\" behaviour needs no CancelCase marker" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  # cancel_word 3 => "act as choice 3-2 = 1" (choice B), matching the real
  # sample game's own map1 ev#9/map2 ev#5/map3 ev#1 shape (opt=50: cancel=3)
  # -- no CancelCase marker at all needed for this behaviour, so this run's
  # own command list omits one entirely (unlike wolf_test_choice_commands'
  # default shape).
  commands = [
    wolf_test_cmd(102, [wolf_test_choice_options(selected: 2, cancel: 3)], ["A", "B"], 0),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 1),
    wolf_test_cmd(401, [0], [], 0),
    wolf_test_cmd(121, [2_000_000, 0, 2, 0xf000], [], 1),
    wolf_test_cmd(499, [], [], 0),
  ]
  run = Wolf::Interpreter::Run.new(interp, commands)
  run.step
  scene.choice_inputs = [:cancel]
  count = 0
  run.step while !run.done && (count += 1) < 20
  assert_equal 2, store.number(2_000_000) # cancel behaved exactly like choosing B
end

assert "Wolf::Interpreter#exec_choices skips a blank choice slot's own body but still counts its marker" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  # help/04ev_select.html: a blank choice string is removed from what the
  # player can pick, but the manual is explicit its ChoiceCase marker still
  # exists -- so with slot 0 blank, the *first* visible choice is really
  # slot 1, and confirming immediately (no down-press needed) must land on
  # slot 1's own body, not slot 0's.
  run = Wolf::Interpreter::Run.new(interp, wolf_test_choice_commands(texts: ["", "B"]))
  run.step
  scene.choice_inputs = [:confirm]
  count = 0
  run.step while !run.done && (count += 1) < 20
  assert_equal 2, store.number(2_000_000)
end

assert "Wolf::Interpreter#exec_choices skips the whole construct when every choice slot is blank" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  run = Wolf::Interpreter::Run.new(interp, wolf_test_choice_commands(texts: ["", ""]))
  count = 0
  run.step while !run.done && (count += 1) < 20 # never actually waits; nothing to pick
  assert_equal 0, store.number(2_000_000)
  assert_equal 9, store.number(2_000_001)
end

assert "Wolf::Interpreter#exec_choices skips a left/right-key or forced-interrupt variant rather than guessing" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.current_scene = WolfTestFakeScene.new
  commands = wolf_test_choice_commands
  commands[0] = wolf_test_cmd(102, [wolf_test_choice_options(selected: 2, extra: 1)], ["A", "B"], 0)
  run = Wolf::Interpreter::Run.new(interp, commands)
  count = 0
  run.step while !run.done && (count += 1) < 20
  assert_equal 0, store.number(2_000_000)
  assert_equal 9, store.number(2_000_001)
end

# ---- Wolf::Interpreter#exec_sound (Sound(140)) ------------------------------

def wolf_test_sound_header(process: Wolf::Interpreter::SOUND_PROCESS_PLAYBACK,
                            operation: Wolf::Interpreter::SOUND_OP_SE,
                            sound_type: Wolf::Interpreter::SOUND_TYPE_FILENAME,
                            systemdb_entry: 0)
  (process & 0x0f) | ((operation & 0x0f) << 4) | ((systemdb_entry & 0xffff) << 8) | ((sound_type & 0xff) << 24)
end

assert "Wolf::Interpreter#exec_sound plays an SE by filename, reading volume/pitch from the confirmed argument slots" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  # The real sample game's own map1 ev#19 carries exactly this shape: a
  # non-default volume/pitch pair, proving those are real argument slots
  # rather than always-100 placeholders.
  cmd = wolf_test_cmd(140, [wolf_test_sound_header, 0, 0, 0, 60, 70], ["SE/Effect_Bomb1_panop.ogg"])
  interp.exec_sound(cmd)

  assert_equal 1, scene.played_se.size
  path, volume, pitch = scene.played_se.first
  assert_equal "SE/Effect_Bomb1_panop.ogg", path
  assert_equal 60, volume
  assert_equal 70, pitch
end

assert "Wolf::Interpreter#exec_sound accepts the real 7-argument variant with a trailing extra field" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  cmd = wolf_test_cmd(140, [wolf_test_sound_header, 0, 0, 0, 100, 100, 0], ["SystemFile/SE_Get.ogg"])
  interp.exec_sound(cmd)

  assert_equal 1, scene.played_se.size
end

assert "Wolf::Interpreter#exec_sound resolves volume/pitch through variable references, not just literals" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_000, 42)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  cmd = wolf_test_cmd(140, [wolf_test_sound_header, 0, 0, 0, 2_000_000, 100], ["SE/Foo.ogg"])
  interp.exec_sound(cmd)

  assert_equal 42, scene.played_se.first[1]
end

assert "Wolf::Interpreter#exec_sound skips BGM/BGS and non-filename sound sources rather than guessing" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  bgm = wolf_test_cmd(140, [wolf_test_sound_header(operation: 0), 0, 0, 0, 100, 100], ["BGM/Foo.ogg"]) # operation 0 = BGM
  interp.exec_sound(bgm)

  db_entry = wolf_test_cmd(140, [wolf_test_sound_header(sound_type: 0), 0, 0, 0])
  interp.exec_sound(db_entry)

  odd_argc = wolf_test_cmd(140, [wolf_test_sound_header, 0, 0, 0, 100, 100, 0, 1_100_000], ["Pan/Demo.ogg"])
  interp.exec_sound(odd_argc)

  assert_equal 0, scene.played_se.size
end

assert "Wolf::Interpreter#exec_sound skips a string-interpolated filename rather than guessing" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  cmd = wolf_test_cmd(140, [wolf_test_sound_header, 0, 0, 0, 100, 100], ["\\cself[9]"])
  interp.exec_sound(cmd)

  assert_equal 0, scene.played_se.size
end

assert "Wolf::Interpreter#exec_sound tolerates a nil #current_scene" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  cmd = wolf_test_cmd(140, [wolf_test_sound_header, 0, 0, 0, 100, 100], ["SE/Foo.ogg"])
  interp.exec_sound(cmd) # must not raise
end

assert "Wolf::Interpreter#exec_sound plays a BGM database entry, matching the sample game's own staff-roll track" do
  project = WolfTestFakeProject.new
  # Mirrors map1 ev#13's own real entry 1 -- name "スタッフロール" (staff
  # roll), volume 100, frequency 100.
  project.system_db[Wolf::Project::SYS_BGM_LIST] = WolfTestFakeSoundTable.new(1 => ["BGM/Piece01_Takumi.mid", 100, 100])
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  header = wolf_test_sound_header(operation: Wolf::Interpreter::SOUND_OP_BGM, sound_type: Wolf::Interpreter::SOUND_TYPE_DB_ENTRY, systemdb_entry: 1)
  interp.exec_sound(wolf_test_cmd(140, [header, 10, 0, 0]))

  assert_equal 1, scene.played_tracks.size
  operation, path, volume, pitch = scene.played_tracks.first
  assert_equal Wolf::Interpreter::SOUND_OP_BGM, operation
  assert_equal "BGM/Piece01_Takumi.mid", path
  assert_equal 100, volume
  assert_equal 100, pitch
end

assert "Wolf::Interpreter#exec_sound treats a 0%% database volume/frequency as \"use the file's own default\"" do
  project = WolfTestFakeProject.new
  project.system_db[Wolf::Project::SYS_BGM_LIST] = WolfTestFakeSoundTable.new(0 => ["BGM/Town01_Takumi.mid", 0, 0])
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  header = wolf_test_sound_header(operation: Wolf::Interpreter::SOUND_OP_BGM, sound_type: Wolf::Interpreter::SOUND_TYPE_DB_ENTRY, systemdb_entry: 0)
  interp.exec_sound(wolf_test_cmd(140, [header, 10, 0, 0]))

  _operation, _path, volume, pitch = scene.played_tracks.first
  assert_equal 100, volume
  assert_equal 100, pitch
end

assert "Wolf::Interpreter#exec_sound stops the BGM on the database \"(停止)\" sentinel, matching map1 ev#13" do
  project = WolfTestFakeProject.new
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  header = wolf_test_sound_header(operation: Wolf::Interpreter::SOUND_OP_BGM, sound_type: Wolf::Interpreter::SOUND_TYPE_DB_ENTRY, systemdb_entry: -1)
  interp.exec_sound(wolf_test_cmd(140, [header, 10, 0, 0]))

  assert_equal [Wolf::Interpreter::SOUND_OP_BGM], scene.stopped_tracks
  assert_equal 0, scene.played_tracks.size
end

assert "Wolf::Interpreter#exec_sound plays a BGS database entry the same way, through #play_track" do
  project = WolfTestFakeProject.new
  project.system_db[Wolf::Project::SYS_BGS_LIST] = WolfTestFakeSoundTable.new(2 => ["BGS/Wind.ogg", 80, 100])
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  header = wolf_test_sound_header(operation: Wolf::Interpreter::SOUND_OP_BGS, sound_type: Wolf::Interpreter::SOUND_TYPE_DB_ENTRY, systemdb_entry: 2)
  interp.exec_sound(wolf_test_cmd(140, [header, 10, 0, 0]))

  operation, path, volume, = scene.played_tracks.first
  assert_equal Wolf::Interpreter::SOUND_OP_BGS, operation
  assert_equal "BGS/Wind.ogg", path
  assert_equal 80, volume
end

assert "Wolf::Interpreter#exec_sound skips a database entry with no matching row rather than raising" do
  project = WolfTestFakeProject.new
  project.system_db[Wolf::Project::SYS_BGM_LIST] = WolfTestFakeSoundTable.new({})
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  header = wolf_test_sound_header(operation: Wolf::Interpreter::SOUND_OP_BGM, sound_type: Wolf::Interpreter::SOUND_TYPE_DB_ENTRY, systemdb_entry: 99)
  interp.exec_sound(wolf_test_cmd(140, [header, 10, 0, 0]))

  assert_equal 0, scene.played_tracks.size
end

assert "Wolf::Interpreter#exec_sound skips a BGM/BGS database entry with an unrecognised argument count" do
  project = WolfTestFakeProject.new
  project.system_db[Wolf::Project::SYS_BGM_LIST] = WolfTestFakeSoundTable.new(1 => ["BGM/Piece01_Takumi.mid", 100, 100])
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  header = wolf_test_sound_header(operation: Wolf::Interpreter::SOUND_OP_BGM, sound_type: Wolf::Interpreter::SOUND_TYPE_DB_ENTRY, systemdb_entry: 1)
  interp.exec_sound(wolf_test_cmd(140, [header, 10, 0])) # only 3 arguments

  assert_equal 0, scene.played_tracks.size
end

# ---- Wolf::Interpreter::Run#exec_input_key (InputKey(123)) ------------------

def wolf_test_input_key_options(direction: 0, confirm: false, cancel: false, subkey: false, wait: false)
  (direction & 0x0f) | (confirm ? 0x10 : 0) | (cancel ? 0x20 : 0) | (subkey ? 0x40 : 0) | (wait ? 0x80 : 0)
end

assert "Wolf::Interpreter::Run#exec_input_key reports 0 immediately when nothing configured is down" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  options = wolf_test_input_key_options(confirm: true, cancel: true)
  run = Wolf::Interpreter::Run.new(interp, [wolf_test_cmd(123, [2_000_000, options])])
  run.step
  assert_true run.done
  assert_equal 0, store.number(2_000_000)
end

assert "Wolf::Interpreter::Run#exec_input_key reports the confirm code immediately when it's held" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.keys_down = [:confirm]
  interp.current_scene = scene
  options = wolf_test_input_key_options(confirm: true, cancel: true)
  run = Wolf::Interpreter::Run.new(interp, [wolf_test_cmd(123, [2_000_000, options])])
  run.step
  assert_true run.done
  assert_equal 10, store.number(2_000_000)
end

assert "Wolf::Interpreter::Run#exec_input_key reports the cancel code when confirm isn't down but cancel is" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.keys_down = [:cancel]
  interp.current_scene = scene
  options = wolf_test_input_key_options(confirm: true, cancel: true)
  run = Wolf::Interpreter::Run.new(interp, [wolf_test_cmd(123, [2_000_000, options])])
  run.step
  assert_equal 11, store.number(2_000_000)
end

assert "Wolf::Interpreter::Run#exec_input_key waits (yielding every frame) until a configured key is pressed" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  options = wolf_test_input_key_options(confirm: true, cancel: true, wait: true)
  run = Wolf::Interpreter::Run.new(interp, [wolf_test_cmd(123, [2_000_000, options])])

  5.times do
    run.step
    assert_false run.done
    assert_equal 0, store.number(2_000_000)
  end
  scene.keys_down = [:confirm]
  run.step
  assert_true run.done
  assert_equal 10, store.number(2_000_000)
end

assert "Wolf::Interpreter::Run#exec_input_key checks the direction keys, returning the numpad-style code for whichever is down" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.keys_down = [:left]
  interp.current_scene = scene
  options = wolf_test_input_key_options(direction: 1) # Dir4: all four cardinal
  run = Wolf::Interpreter::Run.new(interp, [wolf_test_cmd(123, [2_000_000, options])])
  run.step
  assert_equal 4, store.number(2_000_000) # left's own numpad code
end

assert "Wolf::Interpreter::Run#exec_input_key's UpDown/LeftRight direction pairs ignore the other axis" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.keys_down = [:left] # LeftRight mode should catch this; UpDown mode should not
  interp.current_scene = scene

  updown = wolf_test_cmd(123, [2_000_000, wolf_test_input_key_options(direction: 7)])
  Wolf::Interpreter::Run.new(interp, [updown]).step
  assert_equal 0, store.number(2_000_000)

  leftright = wolf_test_cmd(123, [2_000_001, wolf_test_input_key_options(direction: 8)])
  Wolf::Interpreter::Run.new(interp, [leftright]).step
  assert_equal 4, store.number(2_000_001)
end

assert "Wolf::Interpreter::Run#exec_input_key skips an unconfirmed direction mode rather than guessing" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.keys_down = [:up]
  interp.current_scene = scene
  options = wolf_test_input_key_options(direction: 2) # Dir8: not cross-checked against any real example
  run = Wolf::Interpreter::Run.new(interp, [wolf_test_cmd(123, [2_000_000, options])])
  run.step
  assert_equal 0, store.number(2_000_000) # untouched (VarStore's own zero default)
end

assert "Wolf::Interpreter::Run#exec_input_key skips a call whose argument count doesn't match the confirmed Basic-mode layout" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.keys_down = [:confirm]
  interp.current_scene = scene
  options = wolf_test_input_key_options(confirm: true)
  run = Wolf::Interpreter::Run.new(interp, [wolf_test_cmd(123, [2_000_000, options, 100])]) # 3 args
  run.step
  assert_equal 0, store.number(2_000_000)
end

# ---- Wolf::Interpreter#exec_picture -----------------------------------------

def wolf_test_picture_options(operation:, display_type: 0, blend: 0, anchor: 0, zoom_mode: 0, range: 0, free_transform: 0)
  operation | (display_type << 4) | (blend << 8) | (anchor << 12) |
    (zoom_mode << 20) | (range << 24) | (free_transform << 26)
end

assert "Wolf::Interpreter#exec_picture shows a text picture through #current_scene" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  # show, text, blend=Add(1), anchor=Center(1); picture#5 at (50,60), 80%
  # opacity, 150% zoom, 30 degrees, text "Hello".
  options = wolf_test_picture_options(operation: 0, display_type: 2, blend: 1, anchor: 1)
  cmd = wolf_test_cmd(150, [options, 5, 0, 0, 0, 0, 200, 50, 60, 150, 30], ["Hello"])
  interp.exec_picture(cmd)

  assert_equal 1, scene.shown.size
  number, text, x, y, opacity, zoom, angle, anchor, blend = scene.shown.first
  assert_equal 5, number
  assert_equal "Hello", text
  assert_equal 50, x
  assert_equal 60, y
  assert_equal 200, opacity
  assert_equal 1.5, zoom
  assert_equal 30, angle
  assert_equal 1, anchor
  assert_equal 1, blend
end

assert "Wolf::Interpreter#exec_picture erases a picture regardless of display type" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_picture_options(operation: 2)
  interp.exec_picture(wolf_test_cmd(150, [options, 7]))

  assert_equal [7], scene.erased
  assert_equal 0, scene.shown.size
end

assert "Wolf::Interpreter#exec_picture leaves zoom/blend alone on their \"same as current\" codes" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_picture_options(operation: 1, display_type: 2, blend: 0xf, zoom_mode: 4)
  interp.exec_picture(wolf_test_cmd(150, [options, 1, 0, 0, 0, 0, 255, 0, 0, 999, 0], ["hi"]))

  _number, _text, _x, _y, _opacity, zoom, _angle, _anchor, blend = scene.shown.first
  assert_nil zoom
  assert_nil blend
end

assert "Wolf::Interpreter#exec_picture no-ops for the range/free-transform variants and an unrecognised argument count" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  range_options = wolf_test_picture_options(operation: 0, display_type: 2, range: 1)
  interp.exec_picture(wolf_test_cmd(150, [range_options, 1], ["hi"]))

  # A real 13-argument Move (this reader has not reverse-engineered what
  # the extra argument means for a non-"Normal" zoom mode) must not be
  # guessed at, even though its argument count is close to the confirmed
  # 11/12-argument "Base" shapes.
  odd_argc_options = wolf_test_picture_options(operation: 1, display_type: 0, zoom_mode: 4)
  interp.exec_picture(wolf_test_cmd(150, [odd_argc_options, 1, 4, 0, 0, -1_000_000, 255, 1, 1, -1_000_000, -1_000_000, 0, 16_777_216]))

  assert_equal 0, scene.shown.size
  assert_equal 0, scene.shown_files.size
  assert_equal 0, scene.moved.size
end

assert "Wolf::Interpreter#exec_picture shows a real file picture, cropping to one sprite-sheet cell" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_picture_options(operation: 0, display_type: 0, anchor: 2)
  # div_w=6, div_h=4 (a character sheet), pattern=10, at (20, 20), 300% zoom.
  cmd = wolf_test_cmd(150, [options, 1, 0, 6, 4, 10, 255, 20, 20, 300, 0], ["CharaChip/Special_Tiga.png"])
  interp.exec_picture(cmd)

  assert_equal 1, scene.shown_files.size
  number, path, div_w, div_h, pattern, x, y, opacity, zoom, angle, anchor, blend = scene.shown_files.first
  assert_equal 1, number
  assert_equal "CharaChip/Special_Tiga.png", path
  assert_equal 6, div_w
  assert_equal 4, div_h
  assert_equal 10, pattern
  assert_equal 20, x
  assert_equal 20, y
  assert_equal 255, opacity
  assert_equal 3.0, zoom
  assert_equal 0, angle
  assert_equal 2, anchor
  assert_equal 0, blend
end

assert "Wolf::Interpreter#exec_picture skips a file picture whose content is a special directive" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_picture_options(operation: 0, display_type: 0)
  cmd = wolf_test_cmd(150, [options, 1, 0, 1, 1, 1, 255, 0, 0, 100, 0], ["<SCREENSHOT>"])
  interp.exec_picture(cmd)

  assert_equal 0, scene.shown_files.size
end

assert "Wolf::Interpreter#parse_shape_tag decodes <SQUARE>, <GRADX/Y-...> and <LINE> per the manual" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)

  assert_equal({ kind: :square, frame: false }, interp.parse_shape_tag("<SQUARE>"))
  assert_equal({ kind: :square, frame: true }, interp.parse_shape_tag("<SQUARE>FRAME"))
  assert_equal({ kind: :line, thickness: 1 }, interp.parse_shape_tag("<LINE>"))
  assert_equal({ kind: :line, thickness: 11 }, interp.parse_shape_tag("<LINE-11>"))

  grad = interp.parse_shape_tag("<GRADX-000-999>")
  assert_equal :gradient, grad[:kind]
  assert_equal :x, grad[:axis]
  assert_equal [0, 0, 0], grad[:color1]
  assert_equal [255, 255, 255], grad[:color2]

  # The manual's own "090" example: green at full (digit 9) intensity.
  green = interp.parse_shape_tag("<GRADY-090-000>")
  assert_equal :y, green[:axis]
  assert_equal [0, 255, 0], green[:color1]

  assert_nil interp.parse_shape_tag("<CIRCLE>")
  assert_nil interp.parse_shape_tag("SystemFile/WindowBase.png")
end

assert "Wolf::Interpreter#exec_picture draws a <SQUARE> window picture as a shape, not a file" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_picture_options(operation: 0, display_type: 3)
  cmd = wolf_test_cmd(150, [options, 3, 10, 30, 7, 1, 255, 5, 6, 100, 0], ["<GRADY-779-111>"])
  interp.exec_picture(cmd)

  assert_equal 0, scene.shown_files.size
  assert_equal 1, scene.shown_shapes.size
  number, shape, width, height, x, y, opacity, zoom, blend = scene.shown_shapes.first
  assert_equal 3, number
  assert_equal :gradient, shape[:kind]
  assert_equal 30, width
  assert_equal 7, height
  assert_equal 5, x
  assert_equal 6, y
  assert_equal 255, opacity
end

assert "Wolf::Interpreter#exec_picture skips a window picture whose content is not a recognised shape" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_picture_options(operation: 0, display_type: 3)
  cmd = wolf_test_cmd(150, [options, 3, 10, 1, 1, 1, 255, 0, 0, 100, 0], ["SystemFile/WindowBase.png"])
  interp.exec_picture(cmd)

  assert_equal 0, scene.shown_shapes.size
end

assert "Wolf::Interpreter#exec_picture Move only updates transform, never re-showing content" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  move_options = wolf_test_picture_options(operation: 1, display_type: 0)
  cmd = wolf_test_cmd(150, [move_options, 9, 10, 0, 0, 1, 255, 50, 60, 150, 45])
  interp.exec_picture(cmd)

  assert_equal 0, scene.shown_files.size
  assert_equal 1, scene.moved.size
  number, x, y, opacity, zoom, angle, blend = scene.moved.first
  assert_equal 9, number
  assert_equal 50, x
  assert_equal 60, y
  assert_equal 255, opacity
  assert_equal 1.5, zoom
  assert_equal 45, angle
end

assert "Wolf::Interpreter#exec_picture tolerates a nil #current_scene" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  options = wolf_test_picture_options(operation: 0, display_type: 2)
  interp.exec_picture(wolf_test_cmd(150, [options, 1, 0, 0, 0, 0, 255, 0, 0, 100, 0], ["hi"]))
  options = wolf_test_picture_options(operation: 2)
  interp.exec_picture(wolf_test_cmd(150, [options, 1]))
end

# ---- Wolf::Interpreter#exec_database (Database(250)) ------------------------

def wolf_test_db_packed(db_op:, section:, assign_op: 0, use_var_ref: 0)
  section_nibble = { changeable: 0, system: 1, user: 2 }[section]
  assignment_byte = ((assign_op & 0x0f) << 4) | (use_var_ref & 1)
  options_byte = ((db_op & 0x0f) << 4) | section_nibble
  assignment_byte | (options_byte << 8)
end

assert "Wolf::Interpreter#exec_database reads a numeric field into the target, matching CE#0's own real item-count read" do
  project = WolfTestFakeProject.new
  project.user_db[2] = WolfTestFakeDBType.new({ 3 => { 1 => 42 } }, 0 => :string, 1 => :number)
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)

  packed = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_READ, section: :user)
  interp.exec_database(wolf_test_cmd(250, [2, 3, 1, packed, 2_000_000]))
  assert_equal 42, store.number(2_000_000)
end

assert "Wolf::Interpreter#exec_database writes a numeric field, applying the assignment operator against the DB's own current value" do
  # Mirrors map1's own "メンバーの増減" Common Event, which decrements an
  # invoker-tracking changeable-DB field by 1 (MinusEquals) rather than
  # overwriting it outright.
  project = WolfTestFakeProject.new
  project.changeable_db[14] = WolfTestFakeDBType.new({ 5 => { 0 => 9 } }, 0 => :number)
  store = Wolf::VarStore.new(project)
  store.set_number(2_000_000, 1)
  interp = Wolf::Interpreter.new(project, store)

  packed = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_WRITE, section: :changeable, assign_op: 2) # -=
  interp.exec_database(wolf_test_cmd(250, [14, 5, 0, packed, 2_000_000]))
  assert_equal 8, project.changeable_db[14].value(5, 0)
end

assert "Wolf::Interpreter#exec_database reads a string field into the target, matching CE#0's own real item-name read" do
  project = WolfTestFakeProject.new
  project.user_db[2] = WolfTestFakeDBType.new({ 3 => { 0 => "Potion" } }, 0 => :string)
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)

  packed = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_READ, section: :user)
  interp.exec_database(wolf_test_cmd(250, [2, 3, 0, packed, 3_000_000]))
  assert_equal "Potion", store.string(3_000_000)
end

assert "Wolf::Interpreter#exec_database writes a string field from the command's own lone string, the real 4-argument shape" do
  # Mirrors map1's own "お店内部情報更新" Common Event, whose own `data`
  # argument (1600022) is itself "this common event's self-var 22" -- the
  # same value-reference addressing every other numeric slot uses.
  project = WolfTestFakeProject.new
  project.changeable_db[19] = WolfTestFakeDBType.new({}, 5 => :string)
  store = Wolf::VarStore.new(project)
  store.current_common_event_id = 86
  store.set_number(1_600_022, 3)
  interp = Wolf::Interpreter.new(project, store)

  packed = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_WRITE, section: :changeable)
  interp.exec_database(wolf_test_cmd(250, [19, 1_600_022, 5, packed], ["------"]))
  assert_equal "------", project.changeable_db[19].value(3, 5)
end

assert "Wolf::Interpreter#exec_database concatenates a string field with PlusEquals" do
  project = WolfTestFakeProject.new
  project.user_db[7] = WolfTestFakeDBType.new({ 0 => { 2 => "Hello, " } }, 2 => :string)
  store = Wolf::VarStore.new(project)
  store.set_string(3_000_000, "world!")
  interp = Wolf::Interpreter.new(project, store)

  packed = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_WRITE, section: :user, assign_op: 1) # +=
  interp.exec_database(wolf_test_cmd(250, [7, 0, 2, packed, 3_000_000]))
  assert_equal "Hello, world!", project.user_db[7].value(0, 2)
end

assert "Wolf::Interpreter#exec_database skips what it does not understand: db type selector/name-lookup/argument count/db type/field/4-arg-read" do
  project = WolfTestFakeProject.new
  project.user_db[2] = WolfTestFakeDBType.new({ 0 => { 0 => 5 } }, 0 => :number)
  store = Wolf::VarStore.new(project)
  interp = Wolf::Interpreter.new(project, store)

  bad_section = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_READ, section: :user) | (1 << 8) # selector 3
  interp.exec_database(wolf_test_cmd(250, [2, 0, 0, bad_section, 2_000_000]))
  assert_equal 0, store.number(2_000_000)

  name_lookup = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_READ, section: :user, use_var_ref: 1)
  interp.exec_database(wolf_test_cmd(250, [2, 0, 0, name_lookup, 2_000_001]))
  assert_equal 0, store.number(2_000_001)

  odd_argc = wolf_test_cmd(250, [2, 0, 0])
  interp.exec_database(odd_argc)

  packed = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_READ, section: :user)
  no_such_type = wolf_test_cmd(250, [99, 0, 0, packed, 2_000_002])
  interp.exec_database(no_such_type)
  assert_equal 0, store.number(2_000_002)

  no_such_field = wolf_test_cmd(250, [2, 0, 9, packed, 2_000_003])
  interp.exec_database(no_such_field)
  assert_equal 0, store.number(2_000_003)

  four_arg_read = wolf_test_db_packed(db_op: Wolf::Interpreter::DB_OP_READ, section: :user)
  interp.exec_database(wolf_test_cmd(250, [2, 0, 0, four_arg_read], ["nope"]))
  assert_equal 5, project.user_db[2].value(0, 0) # untouched
end

# ---- Wolf::Interpreter#exec_effect (Effect(290)) -----------------------------

def wolf_test_effect_options(target:, effect_type:)
  (target & 0x0f) | ((effect_type & 0x0f) << 4)
end

assert "Wolf::Interpreter#exec_effect shifts a picture's own draw position by a real, possibly variable-held delta" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_DRAW_POSITION_SHIFT)
  cmd = wolf_test_cmd(290, [options, 0, 3, 3, 10, -5, 0])
  interp.exec_effect(cmd)
  assert_equal [[3, 10, -5]], scene.shifted
end

assert "Wolf::Interpreter#exec_effect applies a shift/tint across a real contiguous picture-number range" do
  # Mirrors a real store-display Common Event's own ColorCorrect call,
  # which applies one command across six picture numbers at once.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_COLOR_CORRECT)
  cmd = wolf_test_cmd(290, [options, 0, 21, 26, -100, -100, -100])
  interp.exec_effect(cmd)
  assert_equal [[21, -100, -100, -100], [22, -100, -100, -100], [23, -100, -100, -100],
                [24, -100, -100, -100], [25, -100, -100, -100], [26, -100, -100, -100]],
               scene.tinted
end

assert "Wolf::Interpreter#exec_effect tolerates a nil #current_scene" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_DRAW_POSITION_SHIFT)
  interp.exec_effect(wolf_test_cmd(290, [options, 0, 1, 1, 0, 0, 0]))
end

assert "Wolf::Interpreter#exec_effect skips a target/effect-type/duration/argument-count it does not understand" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  map_target = wolf_test_effect_options(target: 2, effect_type: 0)
  interp.exec_effect(wolf_test_cmd(290, [map_target, 0, 0, 0, 100, 0, 0])) # Map Zoom, not implemented

  unconfirmed_character_type = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_CHARACTER,
                                                          effect_type: 8) # pixel movement, no independent source
  interp.exec_effect(wolf_test_cmd(290, [unconfirmed_character_type, 0, -2, 0, 0, 0, 0]))

  unresolvable_character = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_CHARACTER,
                                                      effect_type: Wolf::Interpreter::EFFECT_CHARACTER_FLASH)
  interp.exec_effect(wolf_test_cmd(290, [unresolvable_character, 0, -3, 0, 100, 100, 100])) # party, no party system

  unknown_type = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE, effect_type: 4)
  interp.exec_effect(wolf_test_cmd(290, [unknown_type, 0, 1, 1, 0, 0, 0])) # Zoom, not implemented

  delayed = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_DRAW_POSITION_SHIFT)
  interp.exec_effect(wolf_test_cmd(290, [delayed, 20, 1, 1, 10, 10, 0]))

  odd_argc = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                       effect_type: Wolf::Interpreter::EFFECT_PICTURE_DRAW_POSITION_SHIFT)
  interp.exec_effect(wolf_test_cmd(290, [odd_argc, 0, 1]))

  assert_equal [], scene.shifted
  assert_equal [], scene.tinted
  assert_equal [], scene.character_flashed
  assert_equal [], scene.character_shaken
end

assert "Wolf::Interpreter#exec_effect's Flash reads the 'duration' field as the flash's own decay length, matching a real call" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_FLASH)
  # A real call: 25-frame flash, picture 21 only, RGB +200/-100/-100.
  interp.exec_effect(wolf_test_cmd(290, [options, 25, 21, 21, 200, -100, -100]))
  assert_equal [[21, 200, -100, -100, 25]], scene.flashed
end

assert "Wolf::Interpreter#exec_effect's Flash applies across a real contiguous picture-number range and tolerates a nil #current_scene" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_FLASH)
  interp.exec_effect(wolf_test_cmd(290, [options, 10, 5, 7, 100, 100, 100]))
  assert_equal [[5, 100, 100, 100, 10], [6, 100, 100, 100, 10], [7, 100, 100, 100, 10]], scene.flashed

  interp.current_scene = nil
  interp.exec_effect(wolf_test_cmd(290, [options, 10, 1, 1, 100, 100, 100]))
end

assert "Wolf::Interpreter#exec_effect's Shake reads value1/value2/value3 as dx/dy/count, matching the one real call" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_SHAKE)
  # The one real call's own field shape: 30-frame interval, a single
  # picture, dx=0 dy=1, an effectively-infinite count (999999, matching the
  # manual's own "10万回以上で無限" note). The real call's own picture-
  # number and save-slot fields are common-event self-variable references
  # (VarStore-decoded, needing a running common event); this uses plain
  # literals instead, the same simplification every other Effect(290) test
  # here already makes.
  interp.exec_effect(wolf_test_cmd(290, [options, 30, 21, 21, 0, 1, 999999]))
  assert_equal [[21, 30, 0, 1, 999999]], scene.shaken
end

assert "Wolf::Interpreter#exec_effect's Shake applies across a real contiguous picture-number range and tolerates a nil #current_scene" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_SHAKE)
  interp.exec_effect(wolf_test_cmd(290, [options, 5, 10, 11, 3, -2, 4]))
  assert_equal [[10, 5, 3, -2, 4], [11, 5, 3, -2, 4]], scene.shaken

  interp.current_scene = nil
  interp.exec_effect(wolf_test_cmd(290, [options, 5, 1, 1, 3, -2, 4]))
end

assert "Wolf::Interpreter#exec_effect's Character Flash resolves \"this event\" the same way SetMoveRoute(201) does, matching the one real call's own shape" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  self_event = WolfTestEvent.new(9, 1, 1, [])
  interp.current_map = WolfTestMap.new([self_event])
  store.current_map_event_id = 9

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_CHARACTER,
                                      effect_type: Wolf::Interpreter::EFFECT_CHARACTER_FLASH)
  # The one real call's own shape: 40-frame flash, RGB +100/+100/+100, "this event".
  interp.exec_effect(wolf_test_cmd(290, [options, 40, -1, 0, 100, 100, 100]))
  assert_equal [[9, 100, 100, 100, 40]], scene.character_flashed
end

assert "Wolf::Interpreter#exec_effect's Character Shake resolves an explicit event id and the hero, and tolerates a nil #current_scene" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  other_event = WolfTestEvent.new(7, 5, 5, [])
  interp.current_map = WolfTestMap.new([other_event])

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_CHARACTER,
                                      effect_type: Wolf::Interpreter::EFFECT_CHARACTER_SHAKE)
  # The one real call's own shape (1-frame interval, dx=2 dy=0, count=100,
  # "this event") exercised on an explicit event id and the hero instead,
  # the same target convention SetMoveRoute(201) shares.
  interp.exec_effect(wolf_test_cmd(290, [options, 1, 7, 0, 2, 0, 100]))
  assert_equal [[7, 1, 2, 0, 100]], scene.character_shaken

  interp.exec_effect(wolf_test_cmd(290, [options, 1, -2, 0, 2, 0, 100]))
  assert_equal [[7, 1, 2, 0, 100], [:hero, 1, 2, 0, 100]], scene.character_shaken

  interp.current_scene = nil
  interp.exec_effect(wolf_test_cmd(290, [options, 1, -2, 0, 2, 0, 100])) # must not raise
end

assert "Wolf::Interpreter#exec_effect's SwitchFlicker reads the 'duration' field as a toggle interval, matching a real active call" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_SWITCH_FLICKER)
  # A real store-display Common Event's own call: 20-frame interval, picture
  # 21 only, RGB +100/+100/+100.
  interp.exec_effect(wolf_test_cmd(290, [options, 20, 21, 21, 100, 100, 100]))
  assert_equal [[21, 20, 100, 100, 100]], scene.flickered
end

assert "Wolf::Interpreter#exec_effect's SwitchFlicker applies across a real contiguous picture-number range" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_SWITCH_FLICKER)
  # A real stop call: zero interval *and* zero RGB, across a real range.
  interp.exec_effect(wolf_test_cmd(290, [options, 0, 21, 26, 0, 0, 0]))
  assert_equal [[21, 0, 0, 0, 0], [22, 0, 0, 0, 0], [23, 0, 0, 0, 0],
                [24, 0, 0, 0, 0], [25, 0, 0, 0, 0], [26, 0, 0, 0, 0]],
               scene.flickered
end

assert "Wolf::Interpreter#exec_effect's SwitchFlicker is not gated by the other Picture effect kinds' delay-must-be-zero rule" do
  # Real SwitchFlicker calls use a genuinely non-zero "duration" (the
  # toggle interval), unlike DrawPositionShift/ColorCorrect where a
  # non-zero value means an unsupported delay -- must not fall into that
  # shared gate.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  options = wolf_test_effect_options(target: Wolf::Interpreter::EFFECT_TARGET_PICTURE,
                                      effect_type: Wolf::Interpreter::EFFECT_PICTURE_SWITCH_FLICKER)
  interp.exec_effect(wolf_test_cmd(290, [options, 3, 5, 5, -100, -100, -100]))
  assert_equal [[5, 3, -100, -100, -100]], scene.flickered
end

# ---- Wolf::Interpreter#exec_change_color (ChangeColor(151)) -----------------

def wolf_test_change_color_packed(red:, green:, blue:, flash: false)
  (red & 0xff) | ((green & 0xff) << 8) | ((blue & 0xff) << 16) | ((flash ? 1 : 0) << 24)
end

assert "Wolf::Interpreter#exec_change_color decodes red/green/blue/flash/duration, matching a real flash call" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  packed = wolf_test_change_color_packed(red: 150, green: 200, blue: 150, flash: true)
  interp.exec_change_color(wolf_test_cmd(151, [packed, 20]))
  assert_equal [[150, 200, 150, true, 20]], scene.changed_colors
end

assert "Wolf::Interpreter#exec_change_color reads a real variable-held duration" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_000, 15)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene

  packed = wolf_test_change_color_packed(red: 30, green: 30, blue: 40)
  interp.exec_change_color(wolf_test_cmd(151, [packed, 2_000_000]))
  assert_equal [[30, 30, 40, false, 15]], scene.changed_colors
end

assert "Wolf::Interpreter#exec_change_color tolerates a nil #current_scene and skips a bad argument count" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  packed = wolf_test_change_color_packed(red: 100, green: 100, blue: 100)
  interp.exec_change_color(wolf_test_cmd(151, [packed, 10]))
  interp.exec_change_color(wolf_test_cmd(151, [packed]))
end

# ---- Wolf::Interpreter#exec_teleport (Teleport(130)) -------------------------

assert "Wolf::Interpreter#exec_teleport records a pending teleport for the hero target" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_teleport(wolf_test_cmd(130, [-2, 15, 21, 1, 32]))
  assert_equal [1, 15, 21], interp.pending_teleport
end

assert "Wolf::Interpreter#exec_teleport reads a real variable-held map/x/y" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_000, 7)
  store.set_number(2_000_001, 27)
  store.set_number(2_000_002, 3)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_teleport(wolf_test_cmd(130, [-2, 2_000_000, 2_000_001, 2_000_002, 16]))
  assert_equal [3, 7, 27], interp.pending_teleport
end

assert "Wolf::Interpreter#exec_teleport skips a target/precise-coordinates/argument-count it does not understand" do
  # Real sample-game data uses target -1 ("this event") exclusively --
  # relocating a non-hero event across maps, which this reader cannot
  # support (see #exec_teleport's own comment) -- so this is the actual
  # real-data shape, not a synthetic edge case.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)

  interp.exec_teleport(wolf_test_cmd(130, [-1, 7, 27, 3, 32]))
  assert_nil interp.pending_teleport

  interp.exec_teleport(wolf_test_cmd(130, [-2, 7, 27, 3, 33])) # precise coordinates bit set
  assert_nil interp.pending_teleport

  interp.exec_teleport(wolf_test_cmd(130, [-2, 7, 27, 3]))
  assert_nil interp.pending_teleport
end

# ---- Wolf::Interpreter#exec_party (Party(270)) -------------------------------

assert "Wolf::Interpreter's Party(270) Special EraseAllCharacters/WarpPartyToHero still no-op on an empty roster, matching two of the sample game's own three real Special calls" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  commands = [
    wolf_test_cmd(121, [2_000_000, 0, 1, 0xf000], [], 0),
    wolf_test_cmd(270, [20], [], 0), # Special: EraseAllCharacters (CE#80's own real value)
    wolf_test_cmd(270, [36], [], 0), # Special: WarpPartyToHero (CE#39's own real value)
    wolf_test_cmd(121, [2_000_001, 0, 2, 0xf000], [], 0),
  ]
  wolf_test_run(store, commands)
  assert_equal 1, store.number(2_000_000)
  assert_equal 2, store.number(2_000_001)
end

assert "Wolf::Interpreter#exec_party Insert seeds a new companion at the hero's current position, matching the sample game's own real CE#80 call shape" do
  # CE#80's own real args ([257, 1600010, 1600009]): options 0x101 decodes
  # to Insert+graphics_is_variable, member/graphics both variable-held (in
  # CE#80's own case, this-common-event-self addresses, unresolvable
  # statically) -- this exercises the identical 3-argument shape with the
  # flat variable/string banks instead, so no common-event context is
  # needed just to set the fixture up.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  store.set_number(2_000_000, 1) # member: 1人目
  store.set_string(3_000_000, "hero_walk.png")
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.x = 5
  scene.y = 7
  interp.current_scene = scene

  interp.exec_party(wolf_test_cmd(270, [257, 2_000_000, 3_000_000]))

  assert_equal({ graphic: "hero_walk.png" }, interp.party_members[0])
  assert_nil interp.party_members[1]
  assert_equal 5, interp.party_position(0)[:x]
  assert_equal 7, interp.party_position(0)[:y]
end

assert "Wolf::Interpreter#exec_party Insert with a literal graphics string shifts later members back" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["first.png"])) # Insert at slot 1, literal
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["second.png"])) # Insert before slot 1 again
  assert_equal({ graphic: "second.png" }, interp.party_members[0])
  assert_equal({ graphic: "first.png" }, interp.party_members[1])
  assert_nil interp.party_members[2]
end

assert "Wolf::Interpreter#exec_party Remove closes the slot and shifts the rest forward" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"]))
  interp.exec_party(wolf_test_cmd(270, [1, 2], ["b.png"]))
  interp.exec_party(wolf_test_cmd(270, [0, 1])) # Remove 1人目 ("a.png")
  assert_equal({ graphic: "b.png" }, interp.party_members[0])
  assert_nil interp.party_members[1]
end

assert "Wolf::Interpreter#exec_party Replace changes a slot's own graphic without moving it" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"]))
  interp.exec_party(wolf_test_cmd(270, [2, 1], ["a2.png"])) # Replace 1人目
  assert_equal({ graphic: "a2.png" }, interp.party_members[0])
end

assert "Wolf::Interpreter#exec_party RemoveGraphic removes every matching slot regardless of position" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["dupe.png"]))
  interp.exec_party(wolf_test_cmd(270, [1, 2], ["keep.png"]))
  interp.exec_party(wolf_test_cmd(270, [1, 3], ["dupe.png"]))
  interp.exec_party(wolf_test_cmd(270, [3], ["dupe.png"])) # RemoveGraphic, literal
  assert_nil interp.party_members[0]
  assert_equal({ graphic: "keep.png" }, interp.party_members[1])
  assert_nil interp.party_members[2]
end

assert "Wolf::Interpreter#exec_party Special PushCharactersToFront compacts gaps left by Remove/RemoveGraphic" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"]))
  interp.exec_party(wolf_test_cmd(270, [1, 2], ["gap.png"]))
  interp.exec_party(wolf_test_cmd(270, [1, 3], ["c.png"]))
  interp.exec_party(wolf_test_cmd(270, [3], ["gap.png"])) # leaves slot 1 empty
  push_to_front = 4 | (0 << 4) # Special: PushCharactersToFront
  interp.exec_party(wolf_test_cmd(270, [push_to_front]))
  assert_equal({ graphic: "a.png" }, interp.party_members[0])
  assert_equal({ graphic: "c.png" }, interp.party_members[1])
  assert_nil interp.party_members[2]
end

assert "Wolf::Interpreter#exec_party Special WarpPartyToHero resets every occupied slot's own position" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.x = 1
  scene.y = 1
  interp.current_scene = scene
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"])) # seeded at (1, 1)
  scene.x = 9
  scene.y = 4
  interp.exec_party(wolf_test_cmd(270, [36])) # Special: WarpPartyToHero
  assert_equal 9, interp.party_position(0)[:x]
  assert_equal 4, interp.party_position(0)[:y]
end

assert "Wolf::Interpreter#exec_party Special EraseAllCharacters clears a real roster, not just an empty one" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"]))
  interp.exec_party(wolf_test_cmd(270, [20])) # Special: EraseAllCharacters
  assert_nil interp.party_members[0]
  assert_nil interp.party_position(0)
end

assert "Wolf::Interpreter#party_advance chains occupied slots one step behind the slot ahead of them, matching help/04ev_party.html's own \"Y回前\" wording" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.x = 0
  scene.y = 0
  interp.current_scene = scene
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"])) # slot 0, seeded at (0, 0)
  interp.exec_party(wolf_test_cmd(270, [1, 2], ["b.png"])) # slot 1, seeded at (0, 0)

  # The hero steps (0,0) -> (1,0) -> (2,0) -> (3,0); each #party_advance
  # call passes the position the hero just left.
  interp.party_advance({ x: 0, y: 0, direction: :down })
  interp.party_advance({ x: 1, y: 0, direction: :down })
  interp.party_advance({ x: 2, y: 0, direction: :down })

  assert_equal 2, interp.party_position(0)[:x] # one step behind the hero's own (3,0)
  assert_equal 1, interp.party_position(1)[:x] # one step behind slot 0's own previous (2,0)
end

assert "Wolf::Interpreter#party_advance does nothing once TurnOffPartyFollowing runs, and resumes after TurnOnPartyFollowing" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"]))

  turn_off = 4 | (0x0a << 4) # Special: TurnOffPartyFollowing
  interp.exec_party(wolf_test_cmd(270, [turn_off]))
  interp.party_advance({ x: 5, y: 5, direction: :down })
  assert_equal 0, interp.party_position(0)[:x] # unchanged -- following is off

  turn_on = 4 | (0x09 << 4) # Special: TurnOnPartyFollowing
  interp.exec_party(wolf_test_cmd(270, [turn_on]))
  interp.party_advance({ x: 6, y: 6, direction: :down })
  assert_equal 6, interp.party_position(0)[:x]
end

assert "Wolf::Interpreter#exec_party skips an out-of-range member, a still-unimplemented Special sub-operation, and an argument count that does not match the real shape" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)

  interp.exec_party(wolf_test_cmd(270, [1, 6], ["a.png"])) # member 6: no 6th companion slot
  assert_nil interp.party_members[0]

  synchro_start = (4 & 0x0f) | (3 << 4) # Special: StartHeroPartySynchro -- still unimplemented (0 real calls)
  interp.exec_party(wolf_test_cmd(270, [synchro_start]))

  interp.exec_party(wolf_test_cmd(270, [])) # no operation nibble to even read
  interp.exec_party(wolf_test_cmd(270, [20, 0])) # real Special shape never carries a second argument
  interp.exec_party(wolf_test_cmd(270, [1, 1])) # Insert with no graphics argument at all
end

# ---- Wolf::VarStore position-addressing (9100000/9180000/9190000) -----------

assert "Wolf::VarStore#number/#set_number read/write the hero's own tile position and facing through 9180000+10*0+X (the sample game's own real \"who=0\" shape)" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  scene.x = 3
  scene.y = 5
  interp.current_scene = scene

  assert_equal 3, store.number(9_180_000) # who=0 field=0: hero mapX
  assert_equal 5, store.number(9_180_001) # who=0 field=1: hero mapY
  assert_equal 6, store.number(9_180_002) # who=0 field=2: hero preciseX (3*2)
  assert_equal 9, store.number(9_180_003) # who=0 field=3: hero preciseY (5*2-1)
  assert_equal 2, store.number(9_180_006) # who=0 field=6: hero facing, numpad "down"

  store.set_number(9_180_000, 7)
  store.set_number(9_180_001, 8)
  assert_equal 7, scene.x
  assert_equal 8, scene.y

  store.set_number(9_180_006, 8) # numpad "up"
  assert_equal :up, scene.hero_pos[:direction]
end

assert "Wolf::VarStore#number/#set_number read/write a companion's own position through 9180000+10*Y+X, Y=1..5" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_party(wolf_test_cmd(270, [1, 1], ["a.png"])) # slot 0 ("1人目"), seeded at (0, 0)

  assert_equal 0, store.number(9_180_010) # who=1 (companion 1) field=0

  store.set_number(9_180_010, 4) # who=1 field=0: companion 1's own mapX
  store.set_number(9_180_011, 6) # who=1 field=1: mapY
  assert_equal 4, interp.party_position(0)[:x]
  assert_equal 6, interp.party_position(0)[:y]

  # who=2 (companion 2): no member in that slot -- reads 0, writes are a no-op.
  assert_equal 0, store.number(9_180_020)
  store.set_number(9_180_020, 99) # must not raise
  assert_nil interp.party_members[1]
end

assert "Wolf::VarStore#number degrades to 0/no-op with no Interpreter attached, and logs an unimplemented field rather than guessing" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new) # no Interpreter constructed at all
  assert_equal 0, store.number(9_180_000)
  store.set_number(9_180_000, 5) # must not raise

  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  scene = WolfTestFakeScene.new
  interp.current_scene = scene
  assert_equal 0, store.number(9_180_004) # field 4: pixel height, not implemented
  store.set_number(9_180_007, 12) # field 7: pixel offset X, not implemented -- must not raise
end

assert "Wolf::Interpreter#resolve_position_ref resolves a real map event through 9100000+10*Y+X and this-event through 9190000+X" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  event = WolfTestEvent.new(3, 2, 2, [])
  interp.current_map = WolfTestMap.new([event])

  assert_equal 2, store.number(9_100_030) # event id 3, field 0 (9100000+10*3+0)
  store.set_number(9_100_031, 9) # event id 3, field 1 (mapY)
  assert_equal 9, interp.event_position(event)[:y]

  store.current_map_event_id = 3
  assert_equal 9, store.number(9_190_001) # this event's own field 1 (mapY)

  assert_equal 0, store.number(9_100_990) # event id 99: no such event
end

# ---- Wolf::Interpreter#exec_save_load (SaveLoad(220)) -----------------------

assert "Wolf::Interpreter#exec_save_load round-trips variables/strings/map/hero-position through a real save file" do
  root = "tmp_wolf_test_save_project"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    store = Wolf::VarStore.new(WolfTestFakeProject.new)
    store.set_number(2_000_040, 111)
    store.set_string(3_000_040, "hello full save")
    store.set_number(9_000_040, 222) # a system variable
    interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
    interp.current_map_id = 4
    scene = WolfTestFakeScene.new
    scene.x = 7
    scene.y = 8
    interp.current_scene = scene
    interp.exec_save_load(wolf_test_cmd(220, [0, 20])) # Save to slot 20

    store2 = Wolf::VarStore.new(WolfTestFakeProject.new)
    interp2 = Wolf::Interpreter.new(WolfTestFakeProject.new, store2)
    interp2.exec_save_load(wolf_test_cmd(220, [1, 20])) # Load slot 20
    assert_equal 111, store2.number(2_000_040)
    assert_equal "hello full save", store2.string(3_000_040)
    assert_equal 222, store2.number(9_000_040)
    assert_equal [4, 7, 8], interp2.pending_teleport
  ensure
    File.delete("#{root}/Save/SaveData20.sav") if File.exist?("#{root}/Save/SaveData20.sav")
    Dir.delete("#{root}/Save") if FileTest.directory?("#{root}/Save")
    Dir.delete(root) if FileTest.directory?(root)
  end
end

assert "Wolf::Interpreter#exec_save_load's Load is a no-op (help/04ev_file.html's own documented default) when no save exists" do
  root = "tmp_wolf_test_save_project"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    store = Wolf::VarStore.new(WolfTestFakeProject.new)
    store.set_number(2_000_041, 999)
    interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
    # save_number 21 is never written by any test in this file.
    interp.exec_save_load(wolf_test_cmd(220, [1, 21]))
    assert_equal 999, store.number(2_000_041) # untouched
    assert_nil interp.pending_teleport
  ensure
    Dir.delete(root) if FileTest.directory?(root)
  end
end

assert "Wolf::Interpreter#exec_save_load gates on argument count and an unknown operation" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.exec_save_load(wolf_test_cmd(220, [0]))
  assert_nil interp.pending_teleport
  interp.exec_save_load(wolf_test_cmd(220, [2, 22])) # neither Save(0) nor Load(1)
  assert_nil interp.pending_teleport
end

assert "Wolf::Interpreter#exec_save_load's Load stops the Run that issued it early and drops every other active Run" do
  root = "tmp_wolf_test_save_project"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    store = Wolf::VarStore.new(WolfTestFakeProject.new)
    store.set_number(2_000_040, 111)
    project = WolfTestFakeProject.new
    interp = Wolf::Interpreter.new(project, store)
    interp.exec_save_load(wolf_test_cmd(220, [0, 23])) # Save to slot 23

    store.set_number(2_000_040, 999) # drift after the save

    # An Auto Common Event that Waits far longer than this test ever steps
    # it -- still "active" (not #done) for the whole test, so #blocking?
    # can prove it, then prove it gone, without needing it to ever finish.
    blocker = WolfTestFakeCommonEvent.new(1, [wolf_test_cmd(180, [999_999])], auto: true)
    loader = WolfTestFakeCommonEvent.new(2, [
      wolf_test_cmd(121, [2_000_041, 0, 55, 0xf000]), # SetVariable literal 55 -- set, then
      # wiped by the Load's own #restore below (a real Load discards *any*
      # change since the save, even one this exact run just made a moment
      # before triggering it), unlike #exec_save_load's own return-early
      # "missing save" case, which leaves already-live state untouched.
      wolf_test_cmd(220, [1, 23]), # Load slot 23
      wolf_test_cmd(121, [2_000_042, 0, 66, 0xf000]) # must never run
    ])
    project.common_events.events = [blocker]
    interp.update
    assert_true interp.blocking?

    project.common_events.events = [blocker, loader]
    interp.update # loader starts and runs this same frame; its own Load fires mid-step
    assert_equal 0, store.number(2_000_041) # wiped by the restore, see above
    assert_equal 0, store.number(2_000_042) # the Run stopped before this command ever ran
    assert_equal 111, store.number(2_000_040) # restored from the Save above
    assert_false interp.blocking? # every Run, including the still-active blocker, was dropped
  ensure
    File.delete("#{root}/Save/SaveData23.sav") if File.exist?("#{root}/Save/SaveData23.sav")
    Dir.delete("#{root}/Save") if FileTest.directory?("#{root}/Save")
    Dir.delete(root) if FileTest.directory?(root)
  end
end

# ---- Wolf::Interpreter#exec_load_variable / #exec_save_variable (LoadVariable(221)/SaveVariable(222)) ----

assert "Wolf::Interpreter#exec_save_variable/#exec_load_variable round-trip a number and a string through a real save file" do
  root = "tmp_wolf_test_save_project"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    store = Wolf::VarStore.new(WolfTestFakeProject.new)
    store.set_number(2_000_010, 99)
    store.set_string(3_000_010, "hello save")
    interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
    # save_number 7 (a literal), keys 9_000_050/9_000_051 (arbitrary raw
    # ids -- only the live variable's own kind, not the key's, decides
    # number vs. string; see #exec_save_variable's own comment).
    interp.exec_save_variable(wolf_test_cmd(222, [2_000_010, 7, 9_000_050, 0]))
    interp.exec_save_variable(wolf_test_cmd(222, [3_000_010, 7, 9_000_051, 0]))

    # A fresh VarStore/Interpreter -- this must come from the file, not
    # from any in-process state the first two calls left behind.
    store2 = Wolf::VarStore.new(WolfTestFakeProject.new)
    interp2 = Wolf::Interpreter.new(WolfTestFakeProject.new, store2)
    interp2.exec_load_variable(wolf_test_cmd(221, [2_000_020, 7, 9_000_050, 0]))
    interp2.exec_load_variable(wolf_test_cmd(221, [3_000_020, 7, 9_000_051, 0]))
    assert_equal 99, store2.number(2_000_020)
    assert_equal "hello save", store2.string(3_000_020)
  ensure
    File.delete("#{root}/Save/SaveData07.sav") if File.exist?("#{root}/Save/SaveData07.sav")
    Dir.delete("#{root}/Save") if FileTest.directory?("#{root}/Save")
    Dir.delete(root) if FileTest.directory?(root)
  end
end

assert "Wolf::Interpreter#exec_load_variable defaults to 0/\"\" for a save file or key that does not exist" do
  root = "tmp_wolf_test_save_project"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    store = Wolf::VarStore.new(WolfTestFakeProject.new)
    interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
    # save_number 8 is never written by any test in this file.
    interp.exec_load_variable(wolf_test_cmd(221, [2_000_021, 8, 9_000_060, 0]))
    interp.exec_load_variable(wolf_test_cmd(221, [3_000_021, 8, 9_000_061, 0]))
    assert_equal 0, store.number(2_000_021)
    assert_equal "", store.string(3_000_021)
  ensure
    Dir.delete(root) if FileTest.directory?(root)
  end
end

assert "Wolf::Interpreter#exec_load_variable special-cases system variable 24 to the save file's own existence" do
  # help/06systemvalue.html's own Sys24: "[読]ｾｰﾌﾞﾃﾞｰﾀ読込判定(1=成功
  # 0=失敗)" -- confirmed by real data (CE#94's own save/load screen
  # renderer reads it first, before any other slot preview info).
  root = "tmp_wolf_test_save_project"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    store = Wolf::VarStore.new(WolfTestFakeProject.new)
    interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)

    # save_number 9 does not exist yet.
    interp.exec_load_variable(wolf_test_cmd(221, [2_000_022, 9, 9_000_024, 0]))
    assert_equal 0, store.number(2_000_022)

    # Any write at all brings the file (and so Sys24) into existence.
    interp.exec_save_variable(wolf_test_cmd(222, [2_000_023, 9, 9_000_070, 0]))
    interp.exec_load_variable(wolf_test_cmd(221, [2_000_022, 9, 9_000_024, 0]))
    assert_equal 1, store.number(2_000_022)
  ensure
    File.delete("#{root}/Save/SaveData09.sav") if File.exist?("#{root}/Save/SaveData09.sav")
    Dir.delete("#{root}/Save") if FileTest.directory?("#{root}/Save")
    Dir.delete(root) if FileTest.directory?(root)
  end
end

assert "Wolf::Interpreter#exec_save_variable/#exec_load_variable can name the save file directly via a string variable" do
  root = "tmp_wolf_test_save_project"
  Dir.mkdir(root) unless FileTest.directory?(root)
  begin
    store = Wolf::VarStore.new(WolfTestFakeProject.new)
    store.set_string(3_000_030, "custom_save.sav")
    store.set_number(2_000_030, 42)
    interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
    interp.exec_save_variable(wolf_test_cmd(222, [2_000_030, 3_000_030, 9_000_080, 0]))
    assert_true File.exist?("#{root}/custom_save.sav")

    store2 = Wolf::VarStore.new(WolfTestFakeProject.new)
    store2.set_string(3_000_030, "custom_save.sav")
    interp2 = Wolf::Interpreter.new(WolfTestFakeProject.new, store2)
    interp2.exec_load_variable(wolf_test_cmd(221, [2_000_031, 3_000_030, 9_000_080, 0]))
    assert_equal 42, store2.number(2_000_031)

    # help/04ev_file.html's own documented Ver3.00+ path-traversal
    # rejection: an unsafe name never reaches the filesystem at all.
    store2.set_string(3_000_031, "../escape.sav")
    interp2.exec_save_variable(wolf_test_cmd(222, [2_000_030, 3_000_031, 9_000_080, 0]))
    assert_false File.exist?("../escape.sav")
  ensure
    File.delete("#{root}/custom_save.sav") if File.exist?("#{root}/custom_save.sav")
    Dir.delete(root) if FileTest.directory?(root)
  end
end

assert "Wolf::Interpreter#exec_load_variable/#exec_save_variable skip an indirect (is_pointer) ref or the wrong argument count" do
  # Neither call ever touches the filesystem for these -- both gates are
  # checked before #exec_save_variable/#exec_load_variable resolve a
  # save file path at all.
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)

  interp.exec_load_variable(wolf_test_cmd(221, [2_000_040, 1, 9_000_090, 1])) # is_pointer
  assert_equal 0, store.number(2_000_040)

  interp.exec_save_variable(wolf_test_cmd(222, [2_000_041, 1, 9_000_091, 1])) # is_pointer

  interp.exec_load_variable(wolf_test_cmd(221, [2_000_042, 1, 9_000_092])) # 3 arguments
  assert_equal 0, store.number(2_000_042)

  interp.exec_save_variable(wolf_test_cmd(222, [2_000_043, 1, 9_000_093])) # 3 arguments
end

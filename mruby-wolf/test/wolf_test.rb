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

assert "Wolf::Page::Condition#enabled? follows the operator/variable/value bits" do
  off = Wolf::Page::Condition.new(0, 0, 0)
  assert_false off.enabled?

  on = Wolf::Page::Condition.new(0x20, 1000000, 1)
  assert_true on.enabled?
end

# ---- Map autotile value decoding --------------------------------------------

assert "Wolf::Map.autotile? / .autotile_slot / .autotile_shape split a layer value" do
  assert_false Wolf::Map.autotile?(41)
  assert_true Wolf::Map.autotile?(100000)
  assert_equal 0, Wolf::Map.autotile_slot(100000)
  assert_equal 1, Wolf::Map.autotile_slot(200000)
  assert_equal 1234, Wolf::Map.autotile_shape(101234)
end

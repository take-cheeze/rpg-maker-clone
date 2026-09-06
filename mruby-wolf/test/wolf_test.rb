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
  assert_equal [:unsupported, 9_100_005], Wolf::ValueRef.decode(9_100_005)
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

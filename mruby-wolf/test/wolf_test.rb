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
  # Wolf::Interpreter#update always scans project.common_events.events, even
  # when a test only cares about map events -- an empty stand-in keeps that
  # scan a no-op instead of a NoMethodError.
  def common_events; @common_events ||= Struct.new(:events).new([]); end
  # Wolf::Interpreter#exec_sound_track_db_entry's own lookup -- a plain Hash
  # (type id => a WolfTestFakeSoundTable) mirrors Wolf::Database#[]'s own
  # by-index access closely enough for that one caller.
  def system_db; @system_db ||= {}; end
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
  attr_reader :shown, :shown_files, :shown_shapes, :moved, :erased, :played_se, :played_tracks, :stopped_tracks
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
  end

  def show_string_picture(*args); @shown << args; end
  def show_file_picture(*args); @shown_files << args; end
  def show_shape_picture(*args); @shown_shapes << args; end
  def move_picture(*args); @moved << args; end
  def erase_picture(number); @erased << number; end
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

assert "Wolf::Interpreter#update_event_movement skips a repeating Custom route rather than applying it forever" do
  store = Wolf::VarStore.new(WolfTestFakeProject.new)
  interp = Wolf::Interpreter.new(WolfTestFakeProject.new, store)
  interp.current_scene = WolfTestFakeScene.new
  page = wolf_test_page(Wolf::Page::TRIGGER_PARALLEL,
                         move_type: Wolf::Page::MOVE_CUSTOM,
                         route: [WolfTestRouteCommand.new(0, [])],
                         route_options: 0x01) # "動作を繰り返す" (repeat)
  event = WolfTestEvent.new(0, 3, 3, [page])

  idx, active = interp.active_page(event)
  interp.update_event_movement(event, idx, active)
  assert_equal 3, interp.event_position(event)[:y]
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

assert 'Read BER number' do
  [
    [0x7f, "\x7f"],
    [0x80, "\x81\x00"],
    [-1, "\x8f\xff\xff\xff\x7f"],
  ].each do |num, data|
    s = StringIO.new(data)
    assert_equal num, LCF.read_ber(s)
    assert_true s.eof?
  end
end

assert 'Read BER number folds the sign without pack' do
  # Every value with bit 31 set overflows a 32-bit `mrb_int` while it is being
  # accumulated, so on the browser/Emscripten build (and Wio, and PSP) it is a
  # bignum by the time the sign is folded in. Folding it with
  # `[ret].pack('L').unpack1('l')` raised `RangeError: integer out of range`
  # there -- New Game died on the first command list carrying a -1 parameter,
  # which is every real project -- so the fold is plain arithmetic instead.
  assert_equal(-1, LCF.read_ber(StringIO.new("\x8f\xff\xff\xff\x7f")))
  assert_equal(-2, LCF.read_ber(StringIO.new("\x8f\xff\xff\xff\x7e")))
  # The extremes of the signed 32-bit range the format stores.
  assert_equal(-2147483648, LCF.read_ber(StringIO.new("\x88\x80\x80\x80\x00")))
  assert_equal(2147483647, LCF.read_ber(StringIO.new("\x87\xff\xff\xff\x7f")))
  # Only the low 32 bits are significant, exactly as the pack fold behaved: a
  # (malformed) encoding wider than five groups keeps its bottom 32 bits rather
  # than growing without bound.
  assert_equal 1, LCF.read_ber(StringIO.new("\x81\x80\x80\x80\x80\x01"))
end

assert "cp932 to unicode" do
  assert_equal "あ", LCF.cp932_to_utf8("\x82\xa0")
  assert_equal "あああ", LCF.cp932_to_utf8("\x82\xa0\x82\xa0\x82\xa0")
  assert_equal "AあA", LCF.cp932_to_utf8("A\x82\xa0A")
  assert_equal "LcfDataBase", LCF.cp932_to_utf8("LcfDataBase")
end

assert "cp932 to unicode degrades on unmappable bytes instead of crashing" do
  # A truncated double-byte sequence (lead byte 0x82 with no trailing byte)
  # must not abort the process; it decodes to the replacement character.
  assert_equal "�", LCF.cp932_to_utf8("\x82")
  assert_equal "A�", LCF.cp932_to_utf8("A\x82")
  # A lead byte followed by more text consumes its (invalid) trailing byte so
  # the rest of the string is still decoded correctly.
  assert_equal "�あ", LCF.cp932_to_utf8("\x82\x00\x82\xa0")
end

# ---- LCF binary format encoders (mirror the on-disk layout) ----------------
# These let the parser be exercised against synthetic, self-consistent data.
def lcf_ber(n)
  n &= 0xFFFFFFFF
  out = [n & 0x7f]
  n >>= 7
  while n > 0
    out.unshift((n & 0x7f) | 0x80)
    n >>= 7
  end
  out.pack('C*')
end

def lcf_field(idx, bytes); lcf_ber(idx) + lcf_ber(bytes.bytesize) + bytes; end
def lcf_int_field(idx, v); lcf_field(idx, lcf_ber(v)); end
def lcf_str_field(idx, s); lcf_field(idx, s); end
def lcf_shorts_field(idx, arr); lcf_field(idx, arr.pack('v*')); end
def lcf_array1d(fields); fields.join + lcf_ber(0); end

def lcf_array2d(entries) # entries: array of [id, array1d_bytes]
  body = lcf_ber(entries.size)
  entries.each { |id, b| body += lcf_ber(id) + b }
  body
end

def lcf_tree(maps, selected)
  body = lcf_ber(maps.size)
  maps.each { |m| body += lcf_ber(m) }
  body + lcf_ber(selected)
end

def lcf_file(hdr, body); StringIO.new(lcf_ber(hdr.bytesize) + hdr + body); end

assert "LCF::Database nested Array2D actor table + int16_array status" do
  actor = lcf_array1d([lcf_str_field(1, "Hero"),
                       lcf_field(31, [10, 20, 30, 40, 50, 60].pack('v*'))])
  db = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(11, lcf_array2d([[1, actor]]))])))
  assert_equal "Hero", db.player[1].name
  st = db.player[1].status
  assert_equal 10, st[:max_hp]
  assert_equal 60, st[:agi]
end

assert "LCF::Database chipset passability table (int8_array)" do
  chip = lcf_array1d([lcf_str_field(2, "World"),
                      lcf_field(4, "\x0f\x00\x08")])
  db = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(20, lcf_array2d([[1, chip]]))])))
  assert_equal "World", db.chipset[1].chipset_name
  assert_equal [0x0f, 0x00, 0x08], db.chipset[1].passable_data_lower
end

assert "LCF::MapTree multi-part parse exposes start position" do
  props = lcf_array2d([[1, lcf_array1d([lcf_str_field(1, "MAP1")])]])
  tree = lcf_tree([1], 1)
  initial = lcf_array1d([lcf_int_field(1, 1), lcf_int_field(2, 5),
                         lcf_int_field(3, 7)])
  lmt = LCF::MapTree.new(lcf_file("LcfMapTree", props + tree + initial))
  assert_equal 1, lmt.initial.initial_map_id
  assert_equal 5, lmt.initial.initial_x
  assert_equal 7, lmt.initial.initial_y
  assert_equal [1], lmt.tree.maps
  assert_equal "MAP1", lmt.map_properties[1].name
end

assert "LCF::Database item armour option flags (chunks 25-28) and equip animation" do
  # 使用時アニメ (chunk 70) is an object list; its weapon fields (3/4/12) come
  # from the item page, so the shared BATTLER_ANIMATION union must decode them.
  equip_anim = lcf_array1d([lcf_int_field(3, 2), lcf_int_field(4, 5),
                            lcf_int_field(12, 4)])
  item = lcf_array1d([lcf_str_field(1, "Shield"),
                      lcf_field(25, "\x01"), lcf_field(26, "\x00"),
                      lcf_field(27, "\x01"), lcf_field(28, "\x01"),
                      lcf_field(70, lcf_array2d([[1, equip_anim]]))])
  db = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(13, lcf_array2d([[1, item]]))]))) # item = chunk 13
  assert_equal "Shield", db.item[1].name
  assert_true db.item[1].prevent_critical
  assert_false db.item[1].raise_evasion
  assert_true db.item[1].half_sp_cost
  assert_true db.item[1].no_terrain_damage
  a = db.item[1].animation_data[1]
  assert_equal 2, a.weapon_cba
  assert_equal 5, a.weapon
  assert_equal 4, a.speed
end

assert "LCF::Array1D#key? distinguishes an absent chunk from a present one" do
  row = LCF::Array1D.new(lcf_array1d([lcf_int_field(1, 5), lcf_int_field(3, 0)]),
                         { elements: { 1 => { name: :a, type: :int },
                                       3 => { name: :b, type: :int } } })
  assert_true row.key?(1)
  # Present but zero-valued: still counts as physically written.
  assert_true row.key?(3)
  assert_false row.key?(2)
end

assert "LCF::Array1D#int16_values reads a raw short array past a named accessor" do
  # Chunk 31 with a two-level parameter curve (six shorts per level); the named
  # `status` accessor only surfaces the first row, int16_values sees all of it.
  status = [10, 5, 3, 2, 1, 4, 20, 10, 6, 4, 2, 8]
  row = LCF::Array1D.new(
    lcf_array1d([lcf_shorts_field(31, status)]),
    { elements: { 31 => { name: :status, type: :int16_array,
                          order: [:max_hp, :max_mp, :atk, :def, :int, :agi] } } })
  assert_equal 10, row.status[:max_hp]        # named accessor: level 1 only
  assert_equal status, row.int16_values(31)   # raw: the whole curve
  assert_nil row.int16_values(99)             # absent chunk
  # A schema field name is reflected by respond_to?, so callers can probe for an
  # optional section (e.g. the item table) instead of rescuing a missing method.
  assert_true row.respond_to?(:status)
  assert_false row.respond_to?(:no_such_field)
end

assert "LCF absent-field defaults: a lambda default is evaluated, not returned raw" do
  row = LCF::Array1D.new(
    lcf_array1d([lcf_int_field(1, 7)]),
    { elements: { 1 => { name: :present, type: :int, default: 0 },
                  2 => { name: :lazy,    type: :int, default: -> { 42 } },
                  3 => { name: :static,  type: :int, default: 5 } } })
  assert_equal 7, row.present   # a present chunk decodes normally
  assert_equal 42, row.lazy     # absent + callable default -> its called value
  assert_equal 5, row.static    # absent + plain default -> the value itself
end

assert "LCF edition-dependent helpers are callable as module methods (used by lazy defaults)" do
  # The real schema uses `-> { LCF.level_max }` / `-> { LCF.exp_default }` etc.
  # as lazy defaults, so these must be reachable as `LCF.<name>` -- otherwise
  # evaluating an absent field's default raises NoMethodError for module LCF.
  assert_equal LCF::MODE == 2003 ? 99 : 50, LCF.level_max
  assert_equal LCF::MODE == 2003 ? 300 : 30, LCF.exp_default
  assert_equal LCF::MODE == 2003 ? 9_999_999 : 999_999, LCF.var_max
  assert_equal LCF::MODE == 2003 ? -9_999_999 : -999_999, LCF.var_min
  assert_equal LCF::MODE == 2003 ? 9999 : 999, LCF.pc_hp_max
  assert_equal LCF::MODE == 2003 ? 99_999 : 9999, LCF.npc_hp_max
end

assert "LCF::Database#maker detects RPG2003 by the Classes section (chunk 30)" do
  actor = lcf_array1d([lcf_str_field(1, "Hero"), lcf_int_field(57, 3)])
  klass = lcf_array1d([lcf_str_field(1, "Soldier")])
  db2003 = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(11, lcf_array2d([[1, actor]])),
                 lcf_field(30, lcf_array2d([[3, klass]]))])))
  assert_true db2003.rpg2003?
  assert_equal 2003, db2003.maker
  assert_equal "Soldier", db2003.job[3].name
  assert_equal 3, db2003.player[1].class_id

  db2000 = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(11, lcf_array2d([[1, lcf_array1d([lcf_str_field(1, "Hero")])]]))])))
  assert_false db2000.rpg2003?
  assert_equal 2000, db2000.maker
end

assert "LCF::Database skill switch/occasion chunks (13, 16, 18, 19)" do
  se = lcf_array1d([lcf_str_field(1, "Teleport"), lcf_int_field(3, 80)])
  skill = lcf_array1d([lcf_str_field(1, "Warp"), lcf_int_field(13, 7),
                       lcf_field(16, se), lcf_field(18, "\x01"),
                       lcf_field(19, "\x00")])
  db = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(12, lcf_array2d([[1, skill]]))]))) # skill = chunk 12
  assert_equal 7, db.skill[1].switch_id
  assert_equal "Teleport", db.skill[1].sound_effect.file
  assert_equal 80, db.skill[1].sound_effect.volume
  assert_true db.skill[1].occasion_field
  assert_false db.skill[1].occasion_battle
end

assert "LCF::Database battle_anime2 attack motion and pose object lists (chunks 2, 10, 11)" do
  base = lcf_array1d([lcf_str_field(1, "Swing"), lcf_str_field(2, "Sword"),
                      lcf_int_field(3, 1), lcf_int_field(4, 6)])
  weapon = lcf_array1d([lcf_str_field(1, "Blade"), lcf_str_field(2, "WpnGfx"),
                        lcf_int_field(3, 2)])
  anim = lcf_array1d([lcf_str_field(1, "Fighter"), lcf_int_field(2, 3),
                      lcf_field(10, lcf_array2d([[1, base]])),
                      lcf_field(11, lcf_array2d([[1, weapon]]))])
  db = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(32, lcf_array2d([[1, anim]]))]))) # battle_anime2 = chunk 32
  assert_equal "Fighter", db.battle_anime2[1].name
  assert_equal 3, db.battle_anime2[1].attack_motion
  b = db.battle_anime2[1].base_data[1]
  assert_equal "Sword", b.battler_name
  assert_equal 6, b.animation_id
  assert_equal "WpnGfx", db.battle_anime2[1].weapon_data[1].battler_name
end

assert "LCF decodes boolean chunks (1 byte 0/1)" do
  ce = lcf_array1d([lcf_int_field(11, 3), lcf_field(12, "\x01"),
                    lcf_int_field(13, 7)])
  db = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(25, lcf_array2d([[1, ce]]))]))) # common_event = chunk 25
  assert_true db.common_event[1].need_flag
  assert_equal 3, db.common_event[1].start_term
end

assert "LCF.parse_event_commands decodes an event command list" do
  def lcf_command(code, indent, str, params)
    lcf_ber(code) + lcf_ber(indent) + lcf_ber(str.bytesize) + str +
      lcf_ber(params.size) + params.map { |p| lcf_ber(p) }.join
  end
  blob = lcf_command(10110, 0, "Hi", [1, 2]) + lcf_command(10210, 1, "", [0, 3, 3, 0])
  cmds = LCF.parse_event_commands(blob)
  assert_equal 2, cmds.size
  assert_equal 10110, cmds[0].code
  assert_equal "Hi", cmds[0].string
  assert_equal [1, 2], cmds[0].parameters
  assert_equal 1, cmds[1].indent
  assert_equal 0, cmds[1].param(9) # missing parameters read as 0
end

assert "LCF.parse_move_commands decodes bare and parameterised commands" do
  # face_down (bare), switch_on + id, change_graphic + name/index,
  # play_sound + name/volume/tempo/balance, move_forward (bare).
  blob = lcf_ber(14)
  blob += lcf_ber(32) + lcf_ber(7)
  blob += lcf_ber(34) + lcf_ber("Hero".bytesize) + "Hero" + lcf_ber(2)
  blob += lcf_ber(35) + lcf_ber("bell".bytesize) + "bell" +
          lcf_ber(100) + lcf_ber(80) + lcf_ber(50)
  blob += lcf_ber(11)
  cmds = LCF.parse_move_commands(blob)
  assert_equal 5, cmds.size
  assert_equal 14, cmds[0].command_id
  assert_equal 0, cmds[0].parameter_a
  assert_equal '', cmds[0].parameter_string
  assert_equal 32, cmds[1].command_id
  assert_equal 7, cmds[1].parameter_a
  assert_equal "Hero", cmds[2].parameter_string
  assert_equal 2, cmds[2].parameter_a
  assert_equal "bell", cmds[3].parameter_string
  assert_equal 100, cmds[3].parameter_a
  assert_equal 80, cmds[3].parameter_b
  assert_equal 50, cmds[3].parameter_c
  assert_equal 11, cmds[4].command_id
end

assert "LCF map-tree scroll bars decode as ints, not booleans" do
  # These chunks (5/6) hold the editor's signed scrollbar positions; a real game
  # stores multi-byte BER ints here, which the old :bool schema could not read.
  props = lcf_array2d([[1, lcf_array1d([lcf_str_field(1, "MAP1"),
                                        lcf_int_field(5, 320),
                                        lcf_int_field(6, -48)])]])
  lmt = LCF::MapTree.new(lcf_file("LcfMapTree",
    props + lcf_tree([1], 1) +
    lcf_array1d([lcf_int_field(1, 1), lcf_int_field(2, 0), lcf_int_field(3, 0)])))
  assert_equal 320, lmt.map_properties[1].scrollbar_x
  assert_equal(-48, lmt.map_properties[1].scrollbar_y)
end

assert "LCF::MapUnit event page decodes a move route" do
  route = lcf_array1d([lcf_int_field(11, 2),
                       lcf_field(12, lcf_ber(14) + lcf_ber(11)),
                       lcf_field(21, "\x00"), lcf_field(22, "\x01")])
  page = lcf_array1d([lcf_str_field(21, "hero"), lcf_field(41, route)])
  event = lcf_array1d([lcf_str_field(1, "NPC"), lcf_int_field(2, 0),
                       lcf_int_field(3, 0),
                       lcf_field(5, lcf_array2d([[1, page]]))])
  body = lcf_array1d([lcf_int_field(1, 1), lcf_int_field(2, 1),
                      lcf_int_field(3, 1),
                      lcf_field(81, lcf_array2d([[1, event]]))])
  lmu = LCF::MapUnit.new(lcf_file("LcfMapUnit", body))
  mr = lmu.events[1].pages[1].move_route
  assert_false mr.repeat
  assert_true mr.skippable
  cmds = mr.commands
  assert_equal 2, cmds.size
  assert_equal 14, cmds[0].command_id
  assert_equal 11, cmds[1].command_id
end

assert "LCF::MapUnit parses layers, nested events and event commands" do
  cmds = lcf_ber(10110) + lcf_ber(0) + lcf_ber("Hi".bytesize) + "Hi" + lcf_ber(0)
  page = lcf_array1d([lcf_str_field(21, "hero"), lcf_int_field(23, 4),
                      lcf_int_field(33, 0), lcf_field(52, cmds)])
  event = lcf_array1d([lcf_str_field(1, "NPC"), lcf_int_field(2, 1),
                       lcf_int_field(3, 1),
                       lcf_field(5, lcf_array2d([[1, page]]))])
  body = lcf_array1d([lcf_int_field(1, 3), lcf_int_field(2, 4),
                      lcf_int_field(3, 2),
                      lcf_shorts_field(71, [1, 2, 3, 4, 5, 6, 7, 8]),
                      lcf_shorts_field(72, [0, 0, 0, 0, 0, 0, 0, 0]),
                      lcf_field(81, lcf_array2d([[1, event]]))])
  lmu = LCF::MapUnit.new(lcf_file("LcfMapUnit", body))
  assert_equal 3, lmu.chipset_id
  assert_equal 4, lmu.width
  assert_equal 2, lmu.height
  assert_equal [1, 2, 3, 4, 5, 6, 7, 8], lmu.lower_layer
  assert_equal "NPC", lmu.events[1].name
  page1 = lmu.events[1].pages[1]
  assert_equal "hero", page1.charset_name
  assert_equal 4, page1.direction
  assert_equal 10110, page1.event_commands[0].code
  assert_equal "Hi", page1.event_commands[0].string

  collected = []
  lmu.events.each { |id, ev| collected << [id, ev.name] }
  assert_equal [[1, "NPC"]], collected
end

assert "LCF::SaveData teleport targets, map events and pictures" do
  # Teleport targets (chunk 110): Array2D indexed by map id (0 = escape).
  target = lcf_array1d([lcf_int_field(1, 5), lcf_int_field(2, 3),
                        lcf_int_field(3, 7), lcf_field(4, "\x01"),
                        lcf_int_field(5, 12)])
  # Map events (chunk 111): field 11 is a per-event position table reusing the
  # movable layout; fields 21/22 are the packed tile-replacement blobs.
  event_pos = lcf_array1d([lcf_int_field(12, 4), lcf_int_field(13, 9),
                           lcf_str_field(73, "npc")])
  map_events = lcf_array1d([lcf_field(11, lcf_array2d([[1, event_pos]])),
                            lcf_field(21, "\x02\x03")])
  # Pictures (chunk 103): Array2D of picture state.
  picture = lcf_array1d([lcf_str_field(1, "Fog"), lcf_field(9, "\x01"),
                         lcf_int_field(33, 150), lcf_int_field(41, 20)])

  body = lcf_array1d([lcf_field(103, lcf_array2d([[1, picture]])),
                      lcf_field(110, lcf_array2d([[0, target]])),
                      lcf_field(111, map_events)])
  save = LCF::SaveData.new(lcf_file("LcfSaveData", body))

  assert_equal 5, save.targets[0].map_id
  assert_equal 3, save.targets[0].x
  assert_true save.targets[0].switch_on
  assert_equal 12, save.targets[0].switch_id

  ev = save.map_events.events[1]
  assert_equal 4, ev.x
  assert_equal 9, ev.y
  assert_equal "npc", ev.charset_name
  assert_equal [0x02, 0x03], save.map_events.chip_replacement_lower

  assert_equal "Fog", save.pictures[1].name
  assert_true save.pictures[1].visible
  assert_equal 150, save.pictures[1].zoom
  assert_equal 20, save.pictures[1].tone_red
end

assert "LCF::SaveData decodes bool_array switches, int32 variables and the double timestamp" do
  # System (chunk 101): a switch count + packed switch bytes (one byte per
  # boolean) and a variable count + packed little-endian int32 variables. These
  # only appear in a real Save<N>.lsd, so they exercise the :bool_array and the
  # save file's :int32_array/:double readers that synthetic database data never
  # reaches.
  # Chunk 111 (teleport_erase_transition) is a single raw byte, not a BER int:
  # a real save stores 0xff ("use database value"), which is invalid BER.
  system = lcf_array1d([lcf_int_field(31, 3),
                        lcf_field(32, "\x01\x00\x01"),
                        lcf_int_field(33, 2),
                        lcf_field(34, "\x07\x00\x00\x00\xfd\xff\xff\xff"),
                        lcf_field(111, "\xff")])
  # Title (chunk 100): field 1 is an 8-byte little-endian double (1.5 here).
  title = lcf_array1d([lcf_field(1, "\x00\x00\x00\x00\x00\x00\xf8\x3f"),
                       lcf_str_field(11, "Iris"), lcf_int_field(12, 7)])
  body = lcf_array1d([lcf_field(100, title), lcf_field(101, system)])
  save = LCF::SaveData.new(lcf_file("LcfSaveData", body))

  sys = save[101]
  assert_equal [true, false, true], sys.switches
  assert_equal [7, -3], sys.variables
  assert_equal 0xff, sys.teleport_erase_transition
  assert_equal "Iris", save.title.hero_name
  assert_equal 7, save.title.hero_level
  assert_equal 1.5, save.title.timestamp
end

assert "LCF::SaveData decodes the inventory, common-event and foreground-event chunks" do
  # Inventory (chunk 109): parallel item-id (int16) / count (uint8) arrays plus
  # gold, mirroring a real save's 薬草 x3 + 導きの書 x1 (ids 1 and 451) with 100G.
  inventory = lcf_array1d([lcf_int_field(11, 2),
                           lcf_shorts_field(12, [1, 451]),
                           lcf_field(13, "\x03\x01"),
                           lcf_field(14, "\x00\x00"),
                           lcf_int_field(21, 100)])
  # Common-event state (chunk 114): Array2D indexed by common-event id, each an
  # opaque per-event execution-state blob.
  common = lcf_array2d([[1, lcf_array1d([lcf_field(1, "\x01\x01\x00\x00")])]])
  # Foreground event (chunk 113): the running event's opaque exec-state blob.
  foreground = lcf_array1d([lcf_field(1, "\xab\xcd")])
  body = lcf_array1d([lcf_field(109, inventory),
                      lcf_field(113, foreground),
                      lcf_field(114, common)])
  save = LCF::SaveData.new(lcf_file("LcfSaveData", body))

  assert_equal 2, save.inventory.item_count
  assert_equal [1, 451], save.inventory.item_ids
  assert_equal [3, 1], save.inventory.item_counts
  assert_equal 100, save.inventory.gold
  assert_equal [0x01, 0x01, 0x00, 0x00], save.common_events[1].execution_state
  assert_equal [0xab, 0xcd], save.foreground_event.execution_state
end

assert "LCF::SaveData decodes per-actor level/exp/skills/HP/MP (chunk 108)" do
  # Mirrors a real save's actor 3 (L5, 307 exp, HP 56/MP 53, three skills) and
  # actor 1 (level-1 hero, HP 50/MP 0, no skills or states).
  a3 = lcf_array1d([lcf_int_field(31, 5), lcf_int_field(32, 307),
                    lcf_int_field(51, 3), lcf_shorts_field(52, [11, 12, 13]),
                    lcf_shorts_field(61, [82, 0, 128, 220, 0]),
                    lcf_int_field(71, 56), lcf_int_field(72, 53),
                    lcf_int_field(81, 25), lcf_shorts_field(82, [0] * 25)])
  a1 = lcf_array1d([lcf_int_field(31, 1), lcf_int_field(32, 0),
                    lcf_int_field(71, 50), lcf_int_field(72, 0)])
  body = lcf_array1d([lcf_field(108, lcf_array2d([[1, a1], [3, a3]]))])
  save = LCF::SaveData.new(lcf_file("LcfSaveData", body))

  assert_equal 5, save.actors[3].level
  assert_equal 307, save.actors[3].exp
  assert_equal 3, save.actors[3].skill_size
  assert_equal [11, 12, 13], save.actors[3].skills
  assert_equal [82, 0, 128, 220, 0], save.actors[3].equipment
  assert_equal 56, save.actors[3].hp
  assert_equal 53, save.actors[3].mp
  assert_equal 1, save.actors[1].level
  assert_equal 50, save.actors[1].hp
  assert_equal 0, save.actors[1].mp
  # Absent optional vitals read as nil, so the runtime restore leaves them alone.
  assert_nil save.actors[1].skills
end

# ---- LCF binary format WRITER (inverse of the readers, ADR 0018) -----------
# uni-algo stand-in for the reverse transcoder, mirroring the cp932_to_utf8 the
# harness relies on for reads; the writer only needs it for :string fields.
module LCF
  def utf8_to_cp932(s); s.dup; end
  module_function :utf8_to_cp932
end

assert 'LCF.write_ber matches the reference encoder and round-trips read_ber' do
  # write_ber is the exact inverse of read_ber; cross-check it against lcf_ber
  # (the test's own reference encoder) and prove read(write(n)) == n.
  [0, 1, 0x7f, 0x80, 0x3fff, 0x4000, 100, 200, 123_456, -1, -2, -1000].each do |n|
    assert_equal lcf_ber(n), LCF.write_ber(n)
    assert_equal n, LCF.read_ber(StringIO.new(LCF.write_ber(n)))
  end
  # The documented edge vectors, byte for byte (see the "Read BER number" test).
  assert_equal "\x7f", LCF.write_ber(0x7f)
  assert_equal "\x81\x00", LCF.write_ber(0x80)
  assert_equal "\x8f\xff\xff\xff\x7f", LCF.write_ber(-1)
end

assert 'Array1D#to_lcf reproduces its source bytes (terminated and not)' do
  body = lcf_array1d([lcf_int_field(12, 5), lcf_int_field(13, 7),
                      lcf_str_field(73, "chr")])
  a = LCF::Array1D.new(body, nil)
  # As embedded in an Array2D: keep the trailing 0 terminator.
  assert_equal body, a.to_lcf
  # As at the top level of a save file: no terminator.
  assert_equal body[0...-1], a.to_lcf(false)
end

assert 'Array1D#[]= re-encodes int and string fields through the schema' do
  schema = { elements: LCF::Schema::SAVE_MOVABLE }
  a = LCF::Array1D.new(lcf_array1d([lcf_int_field(12, 5), lcf_int_field(13, 7),
                                    lcf_str_field(73, "old")]), schema)
  assert_equal 5, a.x
  a[12] = 9                 # :int field
  a[73] = "newchr"          # :string field (exercises LCF.encode + utf8_to_cp932)
  assert_equal 9, a.x
  reread = LCF::Array1D.new(a.to_lcf, schema)
  assert_equal 9, reread.x
  assert_equal 7, reread.y             # untouched field preserved
  assert_equal "newchr", reread.charset_name
end

assert 'Array1D hands out one decoded nested table, and re-decodes after a write' do
  # Decoding a nested table re-parses the whole thing, and the runtime asks for
  # the same one over and over (Game::Actor#equip_bonus reads db.item thirty
  # times to build a party), so a container decode is kept. It must still be
  # dropped when the chunk underneath is rewritten or removed.
  learning = lcf_array2d([[1, lcf_array1d([lcf_int_field(1, 3)])]])
  schema = { elements: LCF::Schema::DATABASE[:elements][11][:elements] }
  a = LCF::Array1D.new(lcf_array1d([lcf_field(63, learning)]), schema)
  first = a[63]
  assert_true first.is_a?(LCF::Array2D)
  assert_true first.equal?(a[63]), "a nested table must be decoded once"
  # A scalar is cheap to decode and is not cached, so callers still get their
  # own object to do as they like with.
  a[63] = LCF::Array2D.new(lcf_array2d([[2, lcf_array1d([lcf_int_field(1, 9)])]]),
                           schema[:elements][63])
  assert_false first.equal?(a[63]), "a rewritten chunk must decode afresh"
  assert_nil a[63][1]
  a.delete 63
  assert_nil a[63]
end

assert 'Array2D#to_lcf reproduces its source bytes' do
  e1 = lcf_array1d([lcf_int_field(31, 1)])
  e3 = lcf_array1d([lcf_int_field(31, 5), lcf_int_field(32, 307)])
  body = lcf_array2d([[1, e1], [3, e3]])
  a = LCF::Array2D.new(body, { elements: LCF::Schema::SAVE_PARTY_ACTOR })
  assert_equal body, a.to_lcf
end

assert 'SaveData#to_lcf round-trips a whole file byte-for-byte' do
  # A real .lsd has no top-level terminator: the chunk list runs to EOF.
  title = lcf_array1d([lcf_str_field(11, "Hero"), lcf_int_field(12, 3)])
  sys   = lcf_array1d([lcf_int_field(131, 1)])
  hero  = lcf_array1d([lcf_int_field(12, 11), lcf_int_field(13, 7)])
  body  = lcf_field(100, title) + lcf_field(101, sys) + lcf_field(104, hero)
  file  = lcf_ber("LcfSaveData".bytesize) + "LcfSaveData" + body
  save  = LCF::SaveData.new(StringIO.new(file))
  assert_equal file, save.to_lcf
end

assert 'SaveData edit survives a write/reload round-trip' do
  sys   = lcf_array1d([lcf_int_field(131, 1)])
  hero  = lcf_array1d([lcf_int_field(12, 11), lcf_int_field(13, 7)])
  body  = lcf_field(101, sys) + lcf_field(104, hero)
  save  = LCF::SaveData.new(lcf_file("LcfSaveData", body))

  h = save[104]; h[12] = 42;               save[104] = h
  s = save[101]; s[131] = s.save_count + 1; save[101] = s

  reread = LCF::SaveData.new(StringIO.new(save.to_lcf))
  assert_equal 42, reread.hero.x
  assert_equal 7, reread.hero.y          # untouched field preserved
  assert_equal 2, reread[101].save_count
end

# ---- Build a save FROM SCRATCH (ADR 0019, Game::State#to_lsd) --------------
# The writer above edits a save parsed from bytes; these exercise assembling a
# save with no source file: int16 field encoding, an Array2D populated via #[]=,
# and an empty SaveData built up chunk by chunk and read straight back.

assert 'LCF.pack_int16 / encode :int16_array inverts the reader' do
  vals = [0, 1, 255, 256, 32767, 40000, 65535]
  bytes = LCF.pack_int16(vals)
  assert_equal LCF.encode(vals, :int16_array), bytes
  # unpack('s<*') reads these back as signed 16; masking to 16 bits recovers the
  # value written, so the low half round-trips exactly.
  assert_equal vals, bytes.unpack('s<*').map { |v| v & 0xffff }
  # Non-negative ids (equipment/skills/item ids) match the unsigned LE reference
  # the test helper uses to author int16 fields.
  assert_equal [10, 20, 0, 0, 5].pack('v*'), LCF.pack_int16([10, 20, 0, 0, 5])
end

assert 'LCF.pack_double / encode :double inverts unpack_double' do
  # The little-endian IEEE-754 bytes of 1.5 -- the same reference the reader test
  # above decodes -- must be exactly what pack_double emits.
  assert_equal "\x00\x00\x00\x00\x00\x00\xf8\x3f", LCF.pack_double(1.5)
  assert_equal LCF.pack_double(2.5), LCF.encode(2.5, :double)
  # The non-negative finite values a save timestamp actually takes round-trip
  # through unpack_double exactly (the reader's 63bit assembly holds this domain).
  [0.0, 1.0, 2.5, 0.5, 1234.0, 45000.5, 100.25].each do |v|
    assert_equal v, LCF.unpack_double(LCF.pack_double(v)), "double #{v}"
  end
end

assert 'SaveData title chunk + system message/bgm/access fields round-trip from scratch' do
  save = LCF::SaveData.new
  # Title (chunk 100): the :double timestamp exercises the pack_double encoder,
  # plus the leader name/level/HP and a face slot shown on the file screen.
  title = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_TITLE })
  title[1] = 45000.5
  title[11] = "Iris"; title[12] = 9; title[13] = 123
  title[21] = "FaceA"; title[22] = 2
  save[100] = title
  # System (chunk 101): message-window config, the player-transparent flag, a
  # nested current-BGM chunk and the access flags.
  sys = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_SYSTEM })
  sys[41] = 1; sys[42] = 0; sys[43] = false
  sys[51] = "MsgFace"; sys[52] = 4; sys[53] = 1; sys[54] = true
  sys[55] = true
  cur = LCF::Array1D.new('', { elements: LCF::Schema::BGM })
  cur[1] = "Field"; cur[3] = 80; cur[4] = 120
  sys[75] = cur
  sys[121] = true; sys[122] = false; sys[123] = false; sys[124] = true
  save[101] = sys

  reread = LCF::SaveData.new(StringIO.new(save.to_lcf))
  t = reread[100]
  assert_equal 45000.5, t.timestamp
  assert_equal "Iris", t.hero_name
  assert_equal 9, t.hero_level
  assert_equal 123, t.hero_hp
  assert_equal "FaceA", t.face1_name
  assert_equal 2, t.face1_index
  s = reread[101]
  assert_equal 1, s.message_transparent
  assert_equal 0, s.message_position
  assert_false s.message_prevent_overlap
  assert_equal "MsgFace", s.face_name
  assert_equal 4, s.face_index
  assert_equal 1, s.face_right_position
  assert_true s.face_flip
  assert_true s.transparent
  assert_equal "Field", s.current_bgm.file
  assert_equal 80, s.current_bgm.volume
  assert_equal 120, s.current_bgm.pitch
  assert_true s.teleport_allowed
  assert_false s.escape_allowed
  assert_false s.save_allowed
  assert_true s.menu_allowed
end

assert 'Array2D built from scratch serialises and reads back' do
  schema = { elements: LCF::Schema::SAVE_PARTY_ACTOR }
  a = LCF::Array2D.new('', schema)         # empty, writable table
  e = LCF::Array1D.new('', schema)
  e[31] = 5                                # level (:int)
  e[52] = [101, 102]                       # skills (:int16_array)
  e[61] = [1, 2, 0, 0, 0]                  # equipment (:int16_array)
  a[1] = e
  reread = LCF::Array2D.new(a.to_lcf, schema)
  assert_equal 5, reread[1].level
  assert_equal [101, 102], reread[1].skills
  assert_equal [1, 2, 0, 0, 0], reread[1].equipment
end

assert 'SaveData built from scratch round-trips through the reader' do
  save = LCF::SaveData.new                 # no io => empty, writable save
  hero = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_MOVABLE })
  hero[11] = 3; hero[12] = 8; hero[13] = 4; hero[22] = 1
  save[104] = hero
  sys = LCF::Array1D.new('', { elements: LCF::Schema::SAVE_SYSTEM })
  sys[32] = [false, true, false]           # switches (:bool_array)
  sys[34] = [0, 7, 0]                       # variables (:int32_array)
  sys[131] = 2                              # save_count
  save[101] = sys

  reread = LCF::SaveData.new(StringIO.new(save.to_lcf))
  assert_equal 3, reread.hero.map_id
  assert_equal 8, reread.hero.x
  assert_equal 4, reread.hero.y
  assert_equal 1, reread.hero.direction
  assert_equal [false, true, false], reread[101].switches
  assert_equal [0, 7, 0], reread[101].variables
  assert_equal 2, reread[101].save_count
end

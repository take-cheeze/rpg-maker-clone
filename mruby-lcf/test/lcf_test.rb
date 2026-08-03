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
  assert_equal 56, save.actors[3].hp
  assert_equal 53, save.actors[3].mp
  assert_equal 1, save.actors[1].level
  assert_equal 50, save.actors[1].hp
  assert_equal 0, save.actors[1].mp
  # Absent optional vitals read as nil, so the runtime restore leaves them alone.
  assert_nil save.actors[1].skills
end

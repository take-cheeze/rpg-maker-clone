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

assert "LCF.unpack_shorts" do
  packed = [1, 2, 65535].pack('v*')
  assert_equal [1, 2, 65535], LCF.unpack_shorts(packed, false)
  assert_equal [1, 2, -1], LCF.unpack_shorts(packed, true)
end

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

assert "LCF::Database chipset passability table" do
  chip = lcf_array1d([lcf_str_field(2, "World"),
                      lcf_shorts_field(4, [0x0f, 0x00, 0x08])])
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

assert "LCF decodes boolean chunks (1 byte 0/1)" do
  ce = lcf_array1d([lcf_int_field(11, 3), lcf_field(12, "\x01"),
                    lcf_int_field(13, 7)])
  db = LCF::Database.new(lcf_file("LcfDataBase",
    lcf_array1d([lcf_field(26, lcf_array2d([[1, ce]]))])))
  assert_true db.common_events[1].need_flag
  assert_equal 3, db.common_events[1].start_term
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

assert "LCF::MapUnit parses layers and nested events" do
  page = lcf_array1d([lcf_str_field(21, "hero"), lcf_int_field(23, 4)])
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
  assert_equal "hero", lmu.events[1].pages[1].character_name
  assert_equal 4, lmu.events[1].pages[1].character_direction

  collected = []
  lmu.events.each { |id, ev| collected << [id, ev.name] }
  assert_equal [[1, "NPC"]], collected
end

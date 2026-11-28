class StringIO
  def ungetbyte(substr)
    substr = substr.chr if substr.is_a? Integer
    ungetc substr
  end
end

module LCF
  # The largest chunk id / table row id a reader accepts. A chunk id indexes a
  # Ruby Array (Array1D#@data), so an id read from a corrupt or hostile file
  # ("chunk 2000000000") would otherwise ask for a multi-gigabyte array and die
  # with NoMemoryError, which no `rescue StandardError` catches. No genuine id
  # comes near this: the schema's highest field id is 140 and database tables
  # hold a few thousand rows.
  MAX_CHUNK_ID = 0xffff
  # LAZY_CHUNKS: the smallest chunk (and table) a file-backed record leaves in
  # its file instead of reading into a String (Array1D#initialize's +io+).
  LAZY_MIN = 2048

  # The BER integers of the format (base-128, big-endian, 0x80 the continuation
  # bit) as RPG_RT stores them: the low 32 bits read as signed, so -1 is the five
  # bytes 8f ff ff ff 7f. Four groups stay below 2**28; from the fifth on the
  # native LCF.ber_shift keeps only 32 bits, so no step needs a bignum on a
  # 32-bit mrb_int. LCF.ber_value (the same for a String's leading bytes) and
  # LCF.append_ber (the shortest encoding) are native too (src/lcf.cxx).
  def self.read_ber(s)
    ret = 0
    n = 0
    loop do
      b = s.getbyte
      # A BER integer whose final byte still has the continuation bit set has
      # been truncated (e.g. a single 0xff byte, which is a raw uint8 field
      # mistyped as :int, not a valid BER number). Fail loudly instead of
      # letting `nil & 0x7f` collapse to `false` and raise a cryptic TypeError.
      raise 'truncated BER integer' if b.nil?
      ret = n < 4 ? (ret << 7) | (b & 0x7f) : ber_shift(ret, b)
      n += 1
      break if (b & 0x80) == 0
    end
    ret
  end

  # Inverse of read_ber: negative numbers are written as their 32-bit two's
  # complement, non-negative ones in the shortest form, so a value read from a
  # real file re-encodes to the identical bytes.
  def self.write_ber(n)
    append_ber(String.new, n)
  end

  # SHARED_STR: one frozen String per byte value, and one empty one, stand for every 1-byte or empty chunk and
  # command string (most chunks of an event page are one byte). Frozen, so a caller that mutates one raises instead
  # of changing them all. Each freeze is of a String literal: bc2cpp's closed world then knows no class object is
  # frozen (`b.chr.freeze` would turn its constant-definition elision off for the whole world).
  def self.byte_str b
    return nil if b.nil? # getbyte at the end of the stream: the caller's truncation check raises

    strs = (@byte_strs ||= [])
    str = strs[b]
    return str if str

    str = "\0"
    str.setbyte(0, b)
    strs[b] = str.freeze
  end

  def self.empty_str
    @empty_str ||= ''.freeze
  end

  # The +len+ bytes of +s+ at +pos+: a shared String for 0 or 1 byte, else a slice that shares s's buffer.
  def self.chunk_str s, pos, len
    return byte_str(s.getbyte(pos)) if len == 1
    return empty_str if len == 0

    s.byteslice(pos, len)
  end

  # STR_POOL: a decoded LCF string of at most 32 bytes comes back frozen and shared with the last equal one decoded
  # into its slot of a 64-slot table (a map's events name the same charset, sound or face a hundred times). Frozen
  # through `-s`, not `freeze` (see SHARED_STR). Callers never mutate these, so a mutation raises FrozenError.
  def self.pool_str s
    return empty_str if s.empty?
    return s if s.bytesize > 32

    pool = (@str_pool ||= Array.new(64))
    i = s.hash & 63
    hit = pool[i]
    return hit if hit == s

    pool[i] = -s
  end

  class Tree
    def initialize(selected_id, maps)
      @selected_id = selected_id
      @maps = maps
    end

    attr_reader :selected_id, :maps
  end

  # One decoded RPG2000 event command: an opcode, an indent level (used for
  # branch/loop nesting), an optional string argument and an integer parameter
  # list.
  class EventCommand
    attr_reader :code, :indent, :string, :parameters

    def initialize(code, indent, string, parameters)
      @code = code
      @indent = indent
      @string = string
      @parameters = parameters
    end

    # Parameters are frequently accessed past the end of short lists; treat
    # missing parameters as 0 to match RPG2000's behaviour.
    def param(i); @parameters[i] || 0; end
  end

  # EVENT_LIST: an event command list as its LCF bytes and the native index of
  # each command's offset (LCF.event_index, src/lcf.cxx); the :event_packed
  # schema type. A list nobody runs holds no command objects: #[] builds a new
  # LCF::EventCommand on every read, and #command (the interpreter's read) keeps
  # what it built once the list reads back. Read-only: a writer stores a new list.
  class EventList
    # An EventList as is; an Array of EventCommand (or nil) encoded into one.
    def self.of list
      return list if list.is_a?(EventList)

      EventList.new(LCF.encode_event_commands(list || []))
    end

    def self.empty
      @empty ||= EventList.new(LCF.empty_str)
    end

    def initialize bytes
      @bytes = bytes
      @starts = LCF.event_index(bytes)
    end

    def size; LCF.event_count(@bytes, @starts) end

    def empty?; size == 0 end

    # Command +i+ as Array#[] indexes: negative from the end, nil outside.
    def [] i
      n = size
      i += n if i < 0
      return nil if i < 0 || i >= n

      str = LCF.pool_str(LCF.event_string(@bytes, @starts, i) || LCF.empty_str)
      EventCommand.new(LCF.event_code(@bytes, @starts, i), LCF.event_indent(@bytes, @starts, i), str,
                       LCF.event_params(@bytes, @starts, i))
    end

    # Command +i+ as #[] reads it. A list read straight through (a cutscene)
    # keeps nothing; from its first read of an earlier command on (a parallel
    # process restarting, a loop) each command is built once and kept.
    def command i
      cmds = @cmds
      unless cmds
        last = @last_read || 0
        @last_read = i
        return self[i] if i >= last

        cmds = @cmds = []
      end
      cmd = cmds[i]
      return cmd if cmd

      cmd = self[i]
      cmds[i] = cmd if cmd
      cmd
    end

    # The code / indent of command +i+ (0...size) without building it.
    def code_at i; LCF.event_code(@bytes, @starts, i) end

    def indent_at i; LCF.event_indent(@bytes, @starts, i) end

    def each
      i = 0
      n = size
      while i < n
        yield self[i]
        i += 1
      end
      self
    end

    def to_a
      out = []
      each { |c| out.push c }
      out
    end

    def to_lcf; @bytes end
  end

  # Decode a packed event command list (the `:event` schema type, used by event
  # pages, common events and move routes). Each command is: code, indent, string
  # (length-prefixed, cp932), then a count-prefixed list of integer parameters.
  # The list runs to the end of the blob.
  def self.parse_event_commands d
    cmds = []
    pos = 0
    size = d.bytesize
    while pos < size
      code = ber_at d, pos
      pos = ber_next d, pos
      indent = ber_at d, pos
      pos = ber_next d, pos
      slen = ber_at d, pos
      pos = ber_next d, pos
      str = slen > 0 ? pool_str(cp932_to_utf8(d.byteslice(pos, slen))) : empty_str
      pos += slen if slen > 0
      pcount = ber_at d, pos
      pos = ber_next d, pos
      params = []
      (0...pcount).each do
        params.push ber_at(d, pos)
        pos = ber_next d, pos
      end
      cmds.push EventCommand.new(code, indent, str, params)
    end
    cmds
  end

  # One decoded RPG2000 move-route command: a command id plus the optional
  # string / integer parameters a handful of commands carry. Move commands use a
  # different, more compact on-disk layout than event commands.
  class MoveCommand
    attr_reader :command_id, :parameter_string,
                :parameter_a, :parameter_b, :parameter_c


    def initialize(command_id, string, a, b, c)
      @command_id = command_id
      @parameter_string = string
      @parameter_a = a
      @parameter_b = b
      @parameter_c = c
    end
  end

  # Move-command ids that carry parameters (every other id is a bare command).
  MOVE_SWITCH_ON = 32       # + switch id
  MOVE_SWITCH_OFF = 33      # + switch id
  MOVE_CHANGE_GRAPHIC = 34  # + charset name (string) + charset index
  MOVE_PLAY_SOUND = 35      # + file name (string) + volume, tempo, balance

  # Encode a list of EventCommand (or {code:, indent:, string:, parameters:}
  # Hashes -- what a text-authored event page decodes to) back to the packed
  # blob #parse_event_commands reads. Its exact inverse: a list parsed then
  # re-encoded without edits reproduces the original bytes.
  def self.encode_event_commands(cmds)
    return cmds.to_lcf if cmds.is_a?(EventList)

    out = String.new
    cmds.each do |c|
      code = c.respond_to?(:code) ? c.code : c[:code]
      indent = c.respond_to?(:indent) ? c.indent : c[:indent]
      str = binstr(utf8_to_cp932((c.respond_to?(:string) ? c.string : c[:string]) || ''))
      params = c.respond_to?(:parameters) ? c.parameters : c[:parameters]
      append_ber(out, code)
      append_ber(out, indent)
      append_ber(out, str.bytesize) << str
      append_ber(out, params.size)
      params.each { |p| append_ber(out, p) }
    end
    out
  end

  # Decode a packed move-command list (the `:move_commands` schema type used by
  # event-page and common-event move routes). Unlike event commands, each entry
  # is a bare command id optionally followed by a length-prefixed cp932 string
  # and/or a few BER integer parameters, selected by the id. The list runs to
  # the end of the blob (its length is also stored separately as `command_size`).
  def self.parse_move_commands d
    cmds = []
    pos = 0
    size = d.bytesize
    while pos < size
      id = ber_at d, pos
      pos = ber_next d, pos
      str = empty_str
      a = b = c = 0
      case id
      when MOVE_SWITCH_ON, MOVE_SWITCH_OFF
        a = ber_at d, pos
        pos = ber_next d, pos
      when MOVE_CHANGE_GRAPHIC, MOVE_PLAY_SOUND
        slen = ber_at d, pos
        pos = ber_next d, pos
        if slen > 0
          str = pool_str(cp932_to_utf8(d.byteslice(pos, slen)))
          pos += slen
        end
        a = ber_at d, pos
        pos = ber_next d, pos
        if id == MOVE_PLAY_SOUND
          b = ber_at d, pos
          pos = ber_next d, pos
          c = ber_at d, pos
          pos = ber_next d, pos
        end
      end
      bare = id >= 0 && id < BARE_MOVE_IDS && str.empty? && a == 0 && b == 0 && c == 0
      cmds.push(bare ? bare_move(id) : MoveCommand.new(id, str, a, b, c))
    end
    cmds
  end

  # SHARED_MOVE: one MoveCommand per id stands for every parameterless command of a decoded route (most of a route
  # is bare moves and turns). A MoveCommand has no writers, so sharing one changes nothing a reader sees. Ids past
  # the format's (0..45) are not shared, so a corrupt id cannot size the table.
  BARE_MOVE_IDS = 64

  def self.bare_move id
    moves = (@bare_moves ||= [])
    moves[id] ||= MoveCommand.new(id, empty_str, 0, 0, 0)
  end

  # Encode a list of MoveCommand (or {command_id:, parameter_string:,
  # parameter_a:, parameter_b:, parameter_c:} Hashes) back to the packed blob
  # #parse_move_commands reads -- its exact inverse. Only the fields the
  # command's own id actually carries get written, mirroring the reader's own
  # `case id` dispatch (a bare command carries nothing past its id).
  def self.encode_move_commands(cmds)
    out = String.new
    cmds.each do |c|
      id = c.respond_to?(:command_id) ? c.command_id : c[:command_id]
      str_field = c.respond_to?(:parameter_string) ? c.parameter_string : c[:parameter_string]
      a = (c.respond_to?(:parameter_a) ? c.parameter_a : c[:parameter_a]) || 0
      b = (c.respond_to?(:parameter_b) ? c.parameter_b : c[:parameter_b]) || 0
      cc = (c.respond_to?(:parameter_c) ? c.parameter_c : c[:parameter_c]) || 0
      append_ber(out, id)
      case id
      when MOVE_SWITCH_ON, MOVE_SWITCH_OFF
        append_ber(out, a)
      when MOVE_CHANGE_GRAPHIC
        str = binstr(utf8_to_cp932(str_field || ''))
        append_ber(out, str.bytesize) << str
        append_ber(out, a)
      when MOVE_PLAY_SOUND
        str = binstr(utf8_to_cp932(str_field || ''))
        append_ber(out, str.bytesize) << str
        append_ber(out, a)
        append_ber(out, b)
        append_ber(out, cc)
      end
    end
    out
  end

  # Holds the sequential sections of a multi-section file (e.g. the map tree,
  # which is a map-properties table followed by the tree order and the initial
  # party/vehicle positions). Sections are reachable by their schema name
  # through #[] (`tree[:initial]`); a non-Symbol index reaches into the first
  # section for convenience. There is no dotted `tree.initial` form: see
  # Array1D#[] for why field access is `[]` only.
  class Sections
    def initialize
      @by_name = {}
      @list = []
    end

    def add name, value
      @by_name[name] = value
      @list.push value
    end

    # A Symbol looks up the named section itself (e.g. `tree[:tree]`); anything
    # else indexes into the first section for convenience (e.g. `tree[22]`).
    def [] idx
      return @by_name[idx] if idx.is_a? Symbol
      @list.first[idx]
    end

    def key? sym ; @by_name.key? sym end

    # Whether the file's schema declares a section called +sym+ -- every
    # section a multi-section file's schema lists is always read, so this is
    # the same answer as #key?. The Sections counterpart of Array1D#field?,
    # which LCF::File#field? forwards to.
    def field? sym ; @by_name.key? sym end
  end

  # MAPPED_LCF: the bytes of the open file +io+ where the platform holds them (LCF.mapped_file), or nil.
  def self.map_io io
    io.is_a?(::File) ? mapped_file(io.path) : nil
  end

  # LCF::ShortArray (src/lcf.cxx): `[]` and `[]=` are Ruby over the native #get and #set, so the compiled world
  # has a definer of each to dispatch to (it reads no operator from a native method table).
  class ShortArray
    def [] i ; get i end
    def []= i, v ; set i, v end
  end

  # Read one section of a file sequentially from the stream +io+. With +lazy+
  # (LCF::File#lazy_io), a table section keeps only each row's offset in it.
  def self.read_section io, s, lazy = nil
    case sget(s, :type)
    when :Array2D ; lazy ? Array2D.lazy_section(lazy, s) : Array2D.new(io, s)
    when :Array1D ; Array1D.new io, s
    when :Tree
      map_count = read_ber io
      maps = Array.new(map_count) { read_ber io }
      Tree.new read_ber(io), maps
    else
      raise "Unsupported section type: #{sget(s, :type)}"
    end
  end

  def self.to_rb d, s
    # An absent field yields its schema default. A Symbol default names an
    # edition-dependent value (max level, the exp curve) -- see
    # edition_default -- and a callable (`-> { ... }`) default is lazy:
    # evaluate it, so the value resolves, not the Proc itself.
    unless d
      dv = sget(s, :default)
      return edition_default(dv) if dv.is_a?(Symbol)
      return dv.respond_to?(:call) ? dv.call : dv
    end
    raise TypeError, "LCF field bytes are #{d.class}, not String" unless d.is_a?(String)

    case sget(s, :type)
    when :Array1D ; return Array1D.new d, s
    when :Array2D ; return Array2D.new d, s
    when :int ; return ber_value(d)
    when :bool
      raise "invalid bool size: #{d.size}" if d.size != 1
      return d.getbyte(0) != 0
    when :int16_array
      vals = d.unpack(int16_format(s))
      order = sget(s, :order)
      return vals unless order
      h = {}
      order.each_with_index { |name, i| h[name] = vals[i] }
      return h
    when :int16_packed ; return ShortArray.unpack(d)
    when :int8_array ; return d.bytes
    when :uint8 ; return d.getbyte(0)
    when :bool_array ; return d.bytes.map { |b| b != 0 }
    when :int32_array ; return unpack_int32(d)
    when :double ; return double_decode(d)
    when :event ; return parse_event_commands(d)
    when :event_packed ; return EventList.new(d)
    when :move_commands ; return parse_move_commands(d)
    when :string ; return LCF.pool_str(LCF.cp932_to_utf8(d))
    when :Tree
      pos = 0
      map_count = ber_at d, pos
      pos = ber_next d, pos
      maps = []
      (0...map_count).each do
        maps.push ber_at(d, pos)
        pos = ber_next d, pos
      end
      return Tree.new(ber_at(d, pos), maps)
    end

    raise "Unsupported type: #{sget(s, :type)}"
  end

  # Coerce a value to a raw byte string safe to concatenate with other byte
  # strings. Under CRuby (the analysis harnesses) this re-tags it ASCII-8BIT so
  # appending cp932 bytes to a binary buffer does not raise on encoding
  # mismatch; under mruby (no Encoding class) strings are already raw bytes and
  # #force_encoding is absent, so it is a no-op.
  def self.binstr s
    s = s.to_s
    s.respond_to?(:force_encoding) ? s.dup.force_encoding('BINARY') : s
  end

  # The unpack template of an :int16_array field: the schema's `format:` (a full
  # String#unpack template, e.g. 'S<*' for unsigned), else signed little-endian.
  # The schema is the source; every reader of these fields goes through here.
  def self.int16_format s
    (s && sget(s, :format)) || 's<*'
  end

  # A schema node is a Hash or, in a build with the ROM schema (gen_schema_rom.rb), a node's handle, a negative
  # Integer. These are the only reads of one (scripts/bc2cpp-rpg/lcf_schema_rom_check.rb holds the world to them).
  def self.sget s, key
    s.is_a?(Integer) ? LCF.rom_get(s, key) : s[key]
  end

  def self.skeys s
    s.is_a?(Integer) ? LCF.rom_keys(s) : s.keys
  end

  # Array1D#sym2idx's per-schema lookup for a ROM node, which cannot hold it as a Hash does under :sym2idx.
  ROM_SYM2IDX = {}

  # Encode an array of 16bit integers as packed little-endian bytes -- the
  # inverse of the schema's :int16_array unpack format. Each value is masked to
  # its low 16 bits, so the signed and unsigned readers round-trip exactly.
  # Built byte-wise rather than via `pack('s<*')` so it does not depend on
  # mruby-pack's endian-suffix pack support (the readers only rely on unpack).
  # Used for the save's item-id, equipment and skill tables.
  def self.pack_int16 a
    out = []
    a.each do |v|
      v &= 0xffff
      out.push(v & 0xff, (v >> 8) & 0xff)
    end
    out.pack('C*')
  end

  # The IEEE-754 double of the fixed-point value n / 2**shift, built with integer
  # arithmetic only (no Float), so it works on the no-Float builds. The bytes are
  # those pack_double writes for the same value. Requires |n| < 2**31 (every
  # intermediate stays below 2**31, the 32bit mrb_int range); a fixed-point
  # save value is far inside it. Zero is +0.0; a value whose exponent overflows
  # is infinity, and one that underflows flushes to zero (as pack_double does).
  def self.pack_fixed_double n, shift
    return [0, 0, 0, 0, 0, 0, 0, 0].pack("C*") if n == 0
    sign = n < 0 ? 1 : 0
    m = sign == 1 ? -n : n
    p = 0
    t = m
    while t > 1
      t = t >> 1
      p = p + 1
    end
    exp = p - shift + 1023
    if exp >= 0x7ff
      frac_high = 0
      frac_low = 0
      exp = 0x7ff
    elsif exp <= 0
      frac_high = 0
      frac_low = 0
      exp = 0
    else
      # fraction = (m - 2**p) * 2**(52 - p). Since p <= 30 it is g * 2**22 with
      # g = (m - 2**p) * 2**(30 - p) < 2**30, so g is split into bytes directly.
      g = (m - (1 << p)) << (30 - p)
      frac_low = 0
      frac_high = 0
      k = 0
      while k < 7
        sh = 8 * k - 22
        if sh >= 0
          byte = (g >> sh) & 0xff
        else
          left = 0 - sh
          byte = left >= 8 ? 0 : ((g & ((1 << (8 - left)) - 1)) << left)
        end
        frac_low = frac_low | (byte << (8 * k)) if k < 3
        frac_high = frac_high | (byte << (8 * (k - 3))) if k >= 3
        k = k + 1
      end
    end
    b = [
      frac_low & 0xff, (frac_low >> 8) & 0xff, (frac_low >> 16) & 0xff,
      frac_high & 0xff, (frac_high >> 8) & 0xff, (frac_high >> 16) & 0xff,
      ((exp & 0xf) << 4) | ((frac_high >> 24) & 0xf),
      (sign << 7) | ((exp >> 4) & 0x7f)
    ]
    b.pack("C*")
  end

  # The fixed-point value n of the IEEE-754 double in bytes (little-endian),
  # n = trunc(value * 2**shift), with integer arithmetic only. The inverse of
  # pack_fixed_double for every value it produces. Returns nil for a short
  # blob, for infinity or NaN, and for a magnitude that needs n >= 2**31.
  def self.unpack_fixed_double d, shift
    return nil if d.nil? || d.bytesize < 8
    b = d.bytes
    sign = (b[7] >> 7) & 1
    exp = ((b[7] & 0x7f) << 4) | ((b[6] >> 4) & 0xf)
    return nil if exp == 0x7ff
    return 0 if exp == 0
    # fraction bits 22..51 as g (g = fraction >> 22), split as high and low parts
    low = b[0] | (b[1] << 8) | (b[2] << 16)
    high = b[3] | (b[4] << 8) | (b[5] << 16) | ((b[6] & 0xf) << 24)
    g = high * 4 + (low >> 22)
    e = exp - 1023 + shift
    return 0 if e < 0
    return nil if e > 30
    n = (1 << e) + (g >> (30 - e))
    sign == 1 ? -n : n
  end

  # FLOAT-CODEC-BEGIN: the Float codec of the :double save fields. mruby-lcf/gen_lcf_nofloat.rb replaces the
  # whole block on a no-Float build (MRB_NO_FLOAT), where the same four names use the fixed-point codec.
  # LCF.unpack_double / LCF.pack_double (src/lcf.cxx) are the IEEE-754 codec of
  # the save file's timestamp, native so no 64-bit Integer is built.
  def self.double_decode d; unpack_double(d) end
  def self.double_encode v; pack_double(v) end
  def self.double_value? v; v.is_a?(Float) end
  def self.double_default whole; whole.to_f end
  # The :double value of a fixed-point n in 1/1024 units, and the fixed value of a :double (Float, or a whole
  # Integer taken as pixels). The no-Float build holds the :double as the fixed value already.
  def self.double_from_fixed n; n.to_f / 1024 end
  def self.double_to_fixed v; v.is_a?(Float) ? (v * 1024).round : v * 1024 end
  # FLOAT-CODEC-END

  # Encode a Ruby value back to the raw chunk bytes for a schema field -- the
  # inverse of to_rb. A nested :Array1D / :Array2D value is serialised through
  # its own #to_lcf. Strings go back out as cp932 via LCF.utf8_to_cp932 (the
  # build's uni-algo encoder; the CRuby harnesses provide a Windows-31J
  # stand-in), mirroring cp932_to_utf8 on read. :Tree is not handled here: it
  # is a whole-file section type (LCF::MapTree's multi-section root), never a
  # field type an Array1D chunk carries, so it never reaches #[]=.
  def self.encode value, type
    case type
    when :int ; write_ber value
    when :bool ; [value ? 1 : 0].pack('C')
    when :uint8 ; [value & 0xff].pack('C')
    when :double ; double_encode value
    when :int8_array ; value.pack('C*')
    when :bool_array ; value.map { |b| b ? 1 : 0 }.pack('C*')
    when :int16_array ; pack_int16 value
    when :int16_packed ; value.is_a?(ShortArray) ? value.to_lcf : pack_int16(value)
    when :int32_array ; pack_int32 value
    when :string ; utf8_to_cp932 value
    when :event, :event_packed ; encode_event_commands value
    when :move_commands ; encode_move_commands value
    when :Array1D, :Array2D
      return binstr(value) if value.is_a? String
      value.to_lcf
    else
      raise "cannot encode type: #{type}"
    end
  end

  # DATABASE's own per-record-type `elements:` sub-schemas (schema.rb) are
  # `-> { {...} }` lambdas, not the hash literal directly -- building all ~930
  # fields' worth of nested Hash/Symbol objects at gem-load time is what
  # raised a real NoMemoryError on the Wio's 192 KB SRAM.
  # Resolved and cached in place on first real access, the same way
  # Array1D#[]/Array2D#[] already cache a chunk's *decoded value* rather than
  # re-running LCF.to_rb on every read -- this just extends that to the
  # schema descriptor itself. A schema whose `elements:` was already a plain
  # Hash (every record type outside DATABASE, plus DATABASE entries that
  # reference an existing shared constant like `elements: COMMON_EVENT`) is
  # returned as-is.
  def self.elements_of schema
    e = sget(schema, :elements)
    # A ROM node, or a caller's Hash around one (`{ elements: LCF::Schema::SE }`), holds the table as its handle.
    return e if e.is_a?(Hash) || (e.is_a?(Integer) && e < 0)
    # A bc2cpp build folds each lambda into a byte table (gen_schema_tables.rb): `elements:` is the table's number
    # and the native LCF.schema_table builds the Hash, so no bytecode runs for it.
    return schema[:elements] = LCF.schema_table(e) if e.is_a?(Integer)
    return e unless e.respond_to?(:call)
    schema[:elements] = e.call
  end

  # Whether +obj+ has a field called +name+. For an LCF record, section list
  # or file that is whether its schema declares the name (Array1D#field?,
  # Sections#field?, File#field?). For anything else -- nil for an absent row
  # or chunk, a plain value, a check harness's stand-in record -- it is
  # whether +obj+ responds to +name+.
  #
  # This is the replacement for the `obj.respond_to?(:name)` guard callers
  # put in front of a field read while records answered fields through
  # method_missing: it gives that guard's exact answer for
  # every receiver, an LCF record included, now that a record no longer
  # responds to its field names. Callers read the field itself with
  # `obj[:name]`.
  def self.field? obj, name
    if obj.is_a?(Array1D) || obj.is_a?(Sections) || obj.is_a?(LCF::File)
      obj.field?(name)
    else
      obj.respond_to?(name)
    end
  end


  MODE = 2000 # 2003

  def self.var_max; MODE == 2003 ?  9_999_999 :  999_999 end
  def self.var_min; MODE == 2003 ? -9_999_999 : -999_999 end

  def self.level_max; MODE == 2003 ? 99 : 50 end
  def self.pc_hp_max; MODE == 2003 ? 9999 : 999 end
  def self.npc_hp_max; MODE == 2003 ? 99_999 : 9999 end

  def self.exp_default; MODE == 2003 ? 300 : 30 end

  # The value of a schema `default:` Symbol (schema.rb): the edition helper it names.
  def self.edition_default kind
    case kind
    when :level_max then level_max
    when :exp_default then exp_default
    else raise ArgumentError, "unknown edition default: #{kind}"
    end
  end

  # Edition-dependent helpers are referenced as `LCF.<name>` from lazy schema
  # defaults (edition_default, or a `-> { LCF.level_max }` lambda), so they
  # must be module functions -- otherwise calling the default raises
  # NoMethodError for module LCF.

  class Array1D
    # An empty, writable record over +elements+ (a schema constant), to fill through #[]= and #to_lcf.
    def self.blank_record elements
      Array1D.new '', { elements: elements }
    end

    # LAZY_CHUNKS: +io+ is the open file +s+ reads (LCF::File#lazy_io), which
    # stays open and unwritten while this record lives (LCF::File#save_to reads
    # it all back first). A chunk of LAZY_MIN bytes or more is then left there:
    # @data holds the file offset of its length, and #chunk_bytes, or a lazy
    # Array2D for a table chunk, reads it when it is used.
    # LAZY_RECORD: a record read from a String keeps only that String (@buf, no
    # @data): a read finds its chunk there (LCF.chunk_at), and the first write
    # splits it into @data (#materialize).
    def initialize s, schema, io = nil
      @schema = schema
      @io = io
      if s.is_a? String
        read_chunks s, nil
        @buf = s
        return
      end
      @data = []
      size = io ? io.size : 0

      begin
        until s.eof?
          idx = LCF.read_ber s
          break if idx == 0
          raise "chunk id #{idx} out of range" if idx < 0 || idx > MAX_CHUNK_ID

          at = io ? io.pos : 0
          len = LCF.read_ber s
          if io && len >= LAZY_MIN
            raise "truncated chunk #{idx}: #{len} bytes declared" if io.pos + len > size
            io.seek(io.pos + len)
            @data[idx] = at
            next
          end
          # A chunk that runs past the end of the stream is a truncated file, not
          # a shorter chunk: reading it short would load the file with that
          # field silently garbled or missing.
          d = if len == 1 then LCF.byte_str(s.getbyte)
              elsif len > 0 then s.read(len)
              else LCF.empty_str
              end
          raise "truncated chunk #{idx}: #{len} bytes declared" if len < 0 || d.nil? || d.bytesize != len
          @data[idx] = d
        end
      rescue StopIteration => e
        e.result
      end
    end

    attr_reader :schema

    # Decode a chunk to its Ruby value. Nested tables are decoded once and kept:
    # a :Array1D / :Array2D chunk re-parses its *whole* table on every read, and
    # the runtime asks for the same one over and over -- building a party alone
    # reads `db.item` thirty times (Game::Actor#equip_bonus, six stats over five
    # equipment slots), which cost 7.7 seconds on Nepheshel's database. The same
    # applies to :event/:move_commands chunks (an RPG2000 event page's own
    # command list, or a Move Route's): each decode builds one EventCommand (or
    # move-command Hash) object per entry from scratch, and both
    # Scene::Map#build_event and Scene::Base::EventResolver#map_event_commands
    # (mruby-rpg2k) re-read the same page's #event_commands on every page-flip
    # (a switch-gated dialogue is a routine RPG2000 idiom, not a one-off) or
    # Call Event, not just once. Cached the same way as the container types:
    # read-only to callers (Array1D exposes no field writers, and nothing in
    # this codebase mutates a decoded EventCommand/move-command list in place),
    # where a scalar or String decode is cheap and handing out the same mutable
    # object would change what a caller can do with it. The two writers below,
    # #[]= and #delete, drop the cached decode with the bytes.
    # A Symbol is a field name (resolved via the schema to its chunk id);
    # anything else is already a chunk id. This is the only way to read a
    # field by name: there is no dotted `row.field_name` form (it used to be
    # answered by method_missing, which kept every call whose receiver might
    # be a record unprovable for bc2cpp's closed-world compile). A name the record's schema does not declare resolves to
    # a nil chunk id and raises, as the dotted form did.
    def [] idx
      idx = sym2idx[idx] if idx.is_a? Symbol
      cached = @decoded && @decoded[idx]
      return cached if cached
      data = @data
      d = data ? data[idx] : nil
      return d if d.is_a?(ShortArray)

      elem = LCF.sget(LCF.elements_of(@schema), idx)
      value = if data.nil?
                v = buf_value idx, elem
                # SHORT_LAYER: kept, as below, so every read shares the one table and #to_lcf writes its edits.
                (@decoded ||= {})[idx] = v if v.is_a?(ShortArray)
                v
              elsif !d.is_a?(Integer)
                v = LCF.to_rb d, elem
                # SHORT_LAYER: a map layer's table holds the same 2 bytes a tile its chunk did, so it takes the
                # chunk's place (#to_lcf writes it back through ShortArray#to_lcf) and every read shares it.
                data[idx] = v if v.is_a?(ShortArray) && d.is_a?(String) && d.bytesize == v.size * 2
                v
              elsif LCF.sget(elem, :type) == :Array2D
                Array2D.new @io, elem, d
              else
                LCF.to_rb chunk_bytes(d), elem
              end
      if value.is_a?(Array1D) || value.is_a?(Array2D) || value.is_a?(EventList) ||
         LCF.sget(elem, :type) == :event || LCF.sget(elem, :type) == :move_commands
        @decoded ||= {}
        @decoded[idx] = value
      end
      value
    end

    # True when a chunk with this id was physically present in the file, before
    # any schema default is applied. Lets callers tell an absent optional
    # section from one that is present but empty (both read as a falsy value
    # through []), which is how the RPG2000/2003 edition is detected. A Symbol
    # first resolves to a chunk id the same way #[] does; a field name this
    # record's schema does not declare at all resolves to a nil id, which
    # never has data -- correctly false. Not the same question as #field?,
    # which asks whether the schema declares the name at all (a declared but
    # absent field is `field?` true, `key?` false, and reads its default).
    def key? idx
      idx = sym2idx[idx] if idx.is_a? Symbol
      data = @data
      data ? !data[idx].nil? : !LCF.chunk_at(@buf, idx).nil?
    end

    # Raw little-endian int16 values of a chunk, bypassing any schema `order`
    # mapping. Lets a caller read a variable-length short array (e.g. the actor
    # parameter growth curve, six shorts per level) whose typed `[]` read only
    # surfaces the first row. Returns nil when the chunk is absent.
    def int16_values idx
      data = @data
      d = chunk_value_bytes(data ? data[idx] : buf_bytes(idx))
      d && d.unpack(LCF.int16_format(LCF.sget(LCF.elements_of(@schema), idx)))
    end

    # Drop a chunk entirely, so #to_lcf omits it rather than writing an empty
    # one. An absent chunk and a present-but-empty chunk are different files to
    # the genuine runtime, and only the former means "nothing here": clearing
    # the running-event continuation (113) by writing empty bytes leaves a
    # zero-command interpreter state behind, where removing the chunk resumes
    # with no event running at all. Returns the removed raw bytes, or nil.
    def delete idx
      materialize
      was = chunk_value_bytes(@data[idx])
      @data[idx] = nil
      @decoded.delete(idx) if @decoded
      was
    end

    # Set the raw bytes of a chunk from a Ruby value, encoding it through the
    # schema type of that field (LCF.encode) so an authored/edited section can
    # be written back out. With no schema attached a raw String is stored as-is.
    # A Symbol resolves to a chunk id the same way #[] does -- File#[]=
    # forwards here blindly for either key type, so this stays consistent
    # with #[] and #key?.
    def []= idx, value
      idx = sym2idx[idx] if idx.is_a? Symbol
      materialize
      elem = @schema && LCF.sget(LCF.elements_of(@schema), idx)
      if elem
        @data[idx] = LCF.encode(value, LCF.sget(elem, :type))
      elsif value.is_a? String
        @data[idx] = LCF.binstr(value)
      else
        raise "cannot encode chunk #{idx} without a schema"
      end
      @decoded.delete(idx) if @decoded
      value
    end

    # Serialise back to the on-disk chunk stream: every present chunk in
    # ascending id order as write_ber(id) + write_ber(len) + bytes. Chunks are
    # stored as their original raw bytes, so a file read and re-serialised
    # without edits reproduces byte-for-byte; an edited chunk (see #[]=) carries
    # only its own re-encoded bytes. A chunk whose value is a nested
    # Array1D/Array2D is serialised through that object's own #to_lcf.
    #
    # When +terminate+ a write_ber(0) terminator is appended. That terminator is
    # required for an Array1D embedded in an Array2D, where entries carry no
    # length prefix and the reader scans until id 0; it is omitted at the top
    # level of a save file, whose chunk list runs to EOF with no terminator (a
    # real RPG2000/2003 .lsd ends on the last chunk's bytes).
    def to_lcf terminate = true
      out = String.new
      (@data || buf_table).each_with_index do |v, idx|
        next if idx == 0 || v.nil?
        v = chunk_bytes(v) if v.is_a?(Integer)
        bytes = LCF.binstr(v.is_a?(String) ? v : v.to_lcf)
        LCF.append_ber(out, idx)
        LCF.append_ber(out, bytes.bytesize) << bytes
      end
      LCF.append_ber(out, 0) if terminate
      out
    end

    # Whether this record's schema declares a field called +sym+ -- the
    # explicit form of the `row.respond_to?(:field)` guard callers used while
    # fields were answered by method_missing, and the same answer it gave:
    # true for every name the record type's schema lists, present in the file
    # or not; false for any other name and for a record built without a
    # schema. See #key? for "present in the file".
    def field? sym
      (@schema && sym2idx.key?(sym)) ? true : false
    end

    # LAZY_CHUNKS: reads every chunk and table row still in the file into
    # memory, so the file can be rewritten under this record.
    def load_lazy
      @data&.each_with_index { |v, idx| @data[idx] = chunk_bytes(v) if v.is_a?(Integer) }
      @decoded&.each_value { |v| v.load_lazy if v.is_a?(Array2D) }
      @io = nil
    end

    private

    # CURSOR: the chunks of a record in memory, read through a position in +s+ (LCF.ber_at), with the same checks as
    # #initialize's stream loop. Into +table+ (or only checked, for nil) as slices that share s's buffer.
    def read_chunks s, table
      pos = 0
      size = s.bytesize
      while pos < size
        idx = LCF.ber_at s, pos
        pos = LCF.ber_next s, pos
        break if idx == 0
        raise "chunk id #{idx} out of range" if idx < 0 || idx > MAX_CHUNK_ID

        len = LCF.ber_at s, pos
        pos = LCF.ber_next s, pos
        raise "truncated chunk #{idx}: #{len} bytes declared" if len < 0 || len > size - pos

        table[idx] = LCF.chunk_str(s, pos, len) if table
        pos += len
      end
      table
    end

    # LAZY_RECORD: the first write turns the record into its chunks.
    def materialize
      return if @data

      @data = buf_table
      @buf = nil
    end

    # The chunks of @buf, with the SHORT_LAYER tables #[] kept in place of theirs.
    def buf_table
      table = read_chunks(@buf, [])
      @decoded&.each { |idx, v| table[idx] = v if v.is_a?(ShortArray) }
      table
    end

    # The bytes of chunk +idx+ of @buf, or nil.
    def buf_bytes idx
      buf = @buf
      at = LCF.chunk_at buf, idx
      at && LCF.chunk_str(buf, LCF.ber_next(buf, at), LCF.ber_at(buf, at))
    end

    # Chunk +idx+ of @buf decoded as #[] decodes it; an :int is read in place.
    def buf_value idx, elem
      buf = @buf
      at = LCF.chunk_at buf, idx
      return LCF.to_rb(nil, elem) unless at

      len = LCF.ber_at buf, at
      pos = LCF.ber_next buf, at
      if len > 1 && LCF.sget(elem, :type) == :int
        raise 'truncated BER integer' if LCF.ber_next(buf, pos) > pos + len

        return LCF.ber_at(buf, pos)
      end
      LCF.to_rb LCF.chunk_str(buf, pos, len), elem
    end

    # The bytes an @data entry stands for (SHORT_LAYER, LAZY_CHUNKS).
    def chunk_value_bytes d
      return d.to_lcf if d.is_a?(ShortArray)

      d.is_a?(Integer) ? chunk_bytes(d) : d
    end

    # The bytes of the chunk whose length is at file offset +at+.
    def chunk_bytes at
      @io.seek at
      len = LCF.read_ber @io
      d = len > 0 ? @io.read(len) : ''
      raise "truncated chunk: #{len} bytes declared" if d.nil? || d.bytesize != len
      d
    end

    # Field-name -> chunk-id lookup for Symbol keys, built lazily
    # (only paid by callers that actually use a symbolic field key --
    # several save-data call sites write every field through numeric #[]=
    # and never touch this at all) and shared per record type via the schema
    # itself: `@schema` is normally one of schema.rb's shared, module-level
    # constant Hashes (e.g. MAP_EVENT_PAGE), so every Array1D built against a
    # given record type is handed the exact same object, not a copy, and the
    # lookup table built from it is identical across every instance too --
    # memoized onto the schema instead of rebuilt into a fresh per-instance
    # Hash. (A caller that instead builds a fresh, throwaway schema wrapper
    # on every call gets no sharing benefit here, but pays nothing either
    # unless it actually uses a symbolic accessor -- laziness alone already
    # covers that case.)
    def sym2idx
      return @sym2idx if @sym2idx
      return nil unless @schema
      node = @schema.is_a?(Integer)
      @sym2idx = node ? LCF::ROM_SYM2IDX[@schema] : @schema[:sym2idx]
      return @sym2idx if @sym2idx
      @sym2idx = {}
      elements = LCF.elements_of(@schema)
      keys = LCF.skeys(elements)
      i = 0
      while i < keys.size
        k = keys[i]
        e = LCF.sget(elements, k)
        @sym2idx[LCF.sget(e, :name)] = k
        i += 1
      end
      if node
        LCF::ROM_SYM2IDX[@schema] = @sym2idx
      else
        @schema[:sym2idx] = @sym2idx
      end
    end
  end

  class Array2D
    # An empty, writable table over +elements+ (a schema constant), to fill through #[]= and #to_lcf.
    def self.blank_table elements
      Array2D.new '', { elements: elements }
    end

    # LAZY_MAP_TREE: the table section of a multi-section file at +io+'s
    # position, read like a lazy chunk's (#index_rows): only each row's offset
    # is kept, and +io+ is left after the table.
    def self.lazy_section io, schema
      table = Array2D.new '', schema
      table.index_section io
      table
    end

    # LAZY_CHUNKS: with +at+, +s+ is the open file of a lazy Array1D chunk and +at+
    # the offset of the chunk's length (Array1D#initialize): only each row's
    # file offset is kept, and #[] reads the row from the file.
    def initialize s, schema, at = nil
      @data = []
      @schema = schema
      return index_rows(s, at) if at
      if s.is_a? String
        read_rows s
        return
      end

      # An empty string builds an empty, writable table from scratch (populate
      # via #[]= then #to_lcf); a real chunk starts with a BER entry count.
      return if s.eof?

      # Each row used to be decoded into an Array1D right here, so opening a
      # table meant building N objects up front (one per project map, or per
      # item/actor/skill/... row in the database) even though a session only
      # ever touches a fraction of them -- the tree-ancestry maps, or whatever
      # database rows the current scene reads. Only the row's raw byte span is
      # captured now; #[] and #each decode it into an Array1D lazily, on first
      # actual access, and keep the result (the same in-place-replace trick
      # Array1D#[] uses for its own nested chunks).
      (0...LCF.read_ber(s)).each do
        idx = LCF.read_ber s
        raise "row id #{idx} out of range" if idx < 0 || idx > MAX_CHUNK_ID
        @data[idx] = read_row_bytes(s)
      end
    end

    # Decode (and cache) row +idx+ on first access; a row never read stays a
    # raw byte span forever. nil for an id the table never had.
    def [] idx
      entry = @data[idx]
      return entry unless entry.is_a?(String) || entry.is_a?(Integer)
      @data[idx] = row_record(entry)
    end

    # PEEK_ROWS: row +idx+ as #[] reads it, but a row #[] has not kept is not
    # kept now either, so a scan of a few fields of every row does not leave the
    # whole table decoded.
    def peek idx
      entry = @data[idx]
      return entry unless entry.is_a?(String) || entry.is_a?(Integer)
      row_record(entry)
    end

    # PEEK_ROWS: #each through #peek. A `while`, not a block: a blockless loop gives each row's peek garbage back
    # to the GC arena every turn (bc2cpp's LOOP_ARENA), where the block kept every row read until the scan ended.
    def each_peek
      i = 0
      n = @data.size
      while i < n
        v = peek(i)
        yield i, v unless v.nil?
        i += 1
      end
    end

    # Store an entry (an Array1D, or its already-serialised bytes) at id +idx+,
    # so an authored table can be assembled and written back out via #to_lcf.
    # LCF_ROW_FLOW: an entry of any other kind is re-read through this
    # table's schema, so every stored entry is nil, bytes or an Array1D over its
    # own elements and `self[i]` has a schema the compiler can rely on.
    def []= idx, entry
      unless entry.nil? || entry.is_a?(String) || (entry.is_a?(Array1D) && same_schema?(entry.schema))
        raise ArgumentError, 'an Array2D entry is nil, bytes or an Array1D' unless entry.is_a?(Array1D)

        entry = Array1D.new(entry.to_lcf, @schema)
      end
      @data[idx] = entry
      entry
    end

    # Iterate over defined (id, Array1D) entries; useful for walking event or
    # actor tables that are sparsely populated. Decodes each row it yields,
    # same as #[] -- a full-table scan (e.g. searching common events by name)
    # still pays for every row it actually visits, just no longer for the
    # ones it doesn't.
    def each
      @data.size.times do |i|
        v = self[i]
        yield i, v unless v.nil?
      end
    end
    include Enumerable

    # Serialise back to the on-disk layout: write_ber(entry count) followed by,
    # for each defined entry in ascending id order, write_ber(id) and the
    # entry's own Array1D#to_lcf (which supplies its trailing terminator). The
    # inverse of the reader; an unedited table reproduces its original bytes.
    def to_lcf
      ids = []
      @data.each_with_index { |v, i| ids.push(i) unless v.nil? }
      out = LCF.write_ber(ids.size)
      ids.each do |i|
        entry = @data[i]
        entry = row_bytes(entry) if entry.is_a?(Integer)
        bytes = LCF.binstr(entry.is_a?(String) ? entry : entry.to_lcf)
        LCF.append_ber(out, i) << bytes
      end
      out
    end

    # LAZY_MAP_TREE: see .lazy_section.
    def index_section io
      @io = io
      index_rows_to io, io.size
    end

    # LAZY_CHUNKS: reads the rows still in the file (see Array1D#load_lazy).
    def load_lazy
      return unless @io

      @data.each_with_index do |v, i|
        if v.is_a?(Integer)
          @data[i] = row_bytes(v)
        elsif v.is_a?(Array1D)
          v.load_lazy # a FILE_ROW record reads its chunks from @io
        end
      end
      @io = nil
    end

    private

    # CURSOR: the rows of a table in memory, read through a position in +s+ (LCF.ber_at), with LCF.row_end checking
    # each row's chunks as #read_row_slice does. LAZY_RECORD: a row is kept as its offset in s (@buf), and #row_bytes
    # slices it out when it is read.
    def read_rows s
      return if s.empty?

      @buf = s
      pos = LCF.ber_next s, 0
      count = LCF.ber_at(s, 0)
      sized = presize count, s.size - pos
      (0...count).each do
        idx = LCF.ber_at s, pos
        pos = LCF.ber_next s, pos
        raise "row id #{idx} out of range" if idx < 0 || idx > MAX_CHUNK_ID

        @data[idx] = pos
        pos = LCF.row_end s, pos
      end
      trim_presized count if sized
    end

    # The row table of a lazy chunk (see #initialize): a row's chunks are
    # skipped, short ones read into one reused buffer rather than sought past
    # (a seek drops the file's read buffer).
    def index_rows io, at
      @io = io
      io.seek at
      len = LCF.read_ber io
      stop = io.pos + len
      index_rows_to io, stop
      raise "truncated table: #{len} bytes declared" if io.pos > stop
    end

    # The rows of a table that starts at +io+'s position and ends by +stop+.
    def index_rows_to io, stop
      scratch = String.new
      count = LCF.read_ber(io)
      sized = presize count, stop - io.pos
      (0...count).each do
        idx = LCF.read_ber io
        raise "row id #{idx} out of range" if idx < 0 || idx > MAX_CHUNK_ID
        @data[idx] = io.pos
        until io.eof?
          id = LCF.read_ber io
          break if id == 0
          n = LCF.read_ber io
          raise "truncated chunk #{id}: #{n} bytes declared" if n < 0 || io.pos + n > stop
          if n > 256
            io.seek(io.pos + n)
          elsif n > 0
            io.read(n, scratch)
          end
        end
      end
      trim_presized count if sized
    end

    # EXACT_ROWS: a table's row ids run 1..count, so its row array is made that long at once. Grown a store at a time
    # it doubled its capacity, which left up to half of each table's slots unused (Nepheshel's items: 2048 for 1201);
    # Array.new rounds up the same way, Array#* allocates the exact length. A row takes at least two bytes (its id and
    # a 0 terminator), so a count past room/2 is malformed and not trusted.
    def presize count, room
      return false unless @data.empty? && count > 0 && count <= room / 2

      @data = [nil] * (count + 1)
      true
    end

    # The length the stores alone would have left: one past the highest row id. A row id past +count+ (a sparse
    # table) grew the array by doubling again, so it is copied to its length (Array#+ allocates exactly; #dup would
    # share the doubled buffer).
    def trim_presized count
      @data.pop while !@data.empty? && @data.last.nil?
      @data = [] + @data if @data.size > count + 1
    end

    # A row of an in-memory table: the span read_row_bytes builds, as a slice of the table's bytes (it shares their
    # buffer, which the record holding the table keeps anyway) instead of a copy.
    def read_row_slice s
      start = s.pos
      size = s.size
      until s.eof?
        idx = LCF.read_ber s
        break if idx == 0

        len = LCF.read_ber s
        raise "truncated chunk #{idx}: #{len} bytes declared" if len < 0 || s.pos + len > size

        s.seek(s.pos + len)
      end
      s.string.byteslice(start, s.pos - start)
    end

    # A row entry as a record. FILE_ROW: a file row longer than LAZY_MIN is read as a record over the file, which
    # leaves its large chunks there (LAZY_CHUNKS), so a peek at a few fields of a long row does not read it all.
    def row_record entry
      return Array1D.new(entry, @schema) if entry.is_a?(String)

      io = @io
      return Array1D.new(row_bytes(entry), @schema) unless io

      io.seek entry
      len = row_span io
      io.seek entry
      return Array1D.new(io, @schema, io) if len > LAZY_MIN

      d = io.read(len)
      raise "truncated row: #{len} bytes declared" if d.nil? || d.bytesize != len

      Array1D.new(d, @schema)
    end

    # The length of the file row at +io+'s position, through its id-0 terminator (or the end of the file).
    def row_span io
      start = io.pos
      size = io.size
      until io.eof?
        id = LCF.read_ber io
        break if id == 0

        n = LCF.read_ber io
        raise "truncated chunk #{id}: #{n} bytes declared" if n < 0 || io.pos + n > size

        io.seek(io.pos + n)
      end
      io.pos - start
    end

    # Row bytes at +at+: an offset in the file (@io) or in @buf.
    def row_bytes at
      io = @io
      unless io
        buf = @buf
        return buf.byteslice(at, LCF.row_end(buf, at) - at)
      end
      io.seek at
      read_row_bytes(io)
    end

    def same_schema? other
      return @schema.equal?(other) if @schema.nil? || other.nil?

      @schema.equal?(other) || LCF.elements_of(@schema).equal?(LCF.elements_of(other))
    end

    # Scan (without decoding) one row's chunk stream and return its raw bytes,
    # from the first chunk id through the id-0 terminator inclusive --
    # precisely the span Array1D#to_lcf(true) would itself produce, so handing
    # it back out unread through #to_lcf is a byte-for-byte passthrough for a
    # real file (write_ber always re-emits the same shortest encoding RPG_RT
    # itself writes -- see write_ber's own comment). Walks the same id/len
    # chunk structure Array1D#initialize does, forward-only: each id/len is
    # read then re-emitted via write_ber (exactly what Array1D#to_lcf already
    # does for every chunk, touched or not, so this changes nothing about
    # what "byte-exact" means here) and each payload is read and appended
    # rather than decoded, so this never touches cp932 conversion or nested
    # Array1D/Array2D construction. Deliberately forward-only, no #seek: a
    # `#seek(len, IO::SEEK_CUR)` skip here -- tried first -- desyncs mruby-io's
    # read-ahead buffer against the real fd position when interleaved with
    # read_ber's own small buffered reads (`#seek` issues a raw `lseek` on the
    # fd without correcting for bytes already buffered-but-unconsumed), which
    # silently corrupted every row after the first on a real `File`-backed
    # stream (StringIO has no such buffer, so a local, String-only check
    # missed it entirely -- confirmed by CI's real-game boot check).
    def read_row_bytes s
      return read_row_slice(s) if s.is_a?(StringIO)

      out = String.new
      # Every chunk is read into this one buffer before it is appended.
      buf = String.new
      begin
        until s.eof?
          idx = LCF.read_ber s
          LCF.append_ber(out, idx)
          break if idx == 0
          len = LCF.read_ber s
          raise "truncated chunk #{idx}: #{len} bytes declared" if len < 0
          LCF.append_ber(out, len)
          next if len == 0
          d = s.read(len, buf)
          raise "truncated chunk #{idx}: #{len} bytes declared" if d.nil? || d.bytesize != len
          out << d
        end
      rescue StopIteration => e
        e.result
      end
      out
    end
  end
end

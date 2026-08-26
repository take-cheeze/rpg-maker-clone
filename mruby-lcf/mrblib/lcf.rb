class StringIO
  def ungetbyte(substr)
    substr = substr.chr if substr.is_a? Integer
    ungetc substr
  end

  def getbyte
    ret = getc
    return ret.getbyte 0 if ret
    ret
  end
end

module LCF
  def read_ber(s)
    ret = 0
    loop do
      b = s.getbyte
      # A BER integer whose final byte still has the continuation bit set has
      # been truncated (e.g. a single 0xff byte, which is a raw uint8 field
      # mistyped as :int, not a valid BER number). Fail loudly instead of
      # letting `nil & 0x7f` collapse to `false` and raise a cryptic TypeError.
      raise 'truncated BER integer' if b.nil?
      ret = (ret << 7) | (b & 0x7f)
      break if (b & 0x80) == 0
    end
    # RPG_RT writes a negative number as its 32-bit two's-complement form (-1 is
    # the five bytes 8f ff ff ff 7f), so the low 32 bits are reinterpreted as
    # signed. Done arithmetically rather than with `[ret].pack('L').unpack1('l')`
    # because on a target whose `mrb_int` is 32-bit -- the browser/Emscripten
    # build, Wio, PSP -- `ret` is already a bignum here, and pack has to convert
    # it back to an `mrb_int` to write it: it raised `RangeError: integer out of
    # range` on every value with the high bit set, i.e. on every negative
    # parameter. That is one command list into any real project, so New Game
    # failed for every RPG2000 game in the browser ("Failed to start new game:
    # integer out of range"). The subtraction below reduces the bignum back into
    # `mrb_int` range instead, which is exactly what pack could not do.
    ret &= 0xffff_ffff
    ret >= 0x8000_0000 ? ret - 0x1_0000_0000 : ret
  end

  # Inverse of read_ber: encode an integer as a base-128 (BER) big-endian byte
  # string, every byte but the last carrying the 0x80 continuation bit. The
  # value is first reduced to its 32-bit two's-complement form so that negative
  # numbers round-trip through read_ber (which reinterprets the low 32 bits as
  # signed) -- e.g. -1 becomes the five bytes 8f ff ff ff 7f, exactly as RPG_RT
  # writes it. Non-negative numbers use the shortest encoding (RPG_RT's own),
  # so a value read from a real file re-encodes to the identical bytes.
  def write_ber(n)
    n &= 0xffff_ffff
    groups = [n & 0x7f]
    while n > 0x7f
      n >>= 7
      groups.unshift(n & 0x7f)
    end
    last = groups.size - 1
    bytes = []
    groups.each_with_index { |g, i| bytes << (i < last ? (g | 0x80) : g) }
    bytes.pack('C*')
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

  # Decode a packed event command list (the `:event` schema type, used by event
  # pages, common events and move routes). Each command is: code, indent, string
  # (length-prefixed, cp932), then a count-prefixed list of integer parameters.
  # The list runs to the end of the blob.
  def parse_event_commands d
    s = StringIO.new d
    cmds = []
    until s.eof?
      code = read_ber s
      indent = read_ber s
      slen = read_ber s
      str = slen > 0 ? cp932_to_utf8(s.read(slen)) : ''
      pcount = read_ber s
      params = []
      (0...pcount).each { params.push read_ber s }
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
  def encode_event_commands(cmds)
    out = String.new
    cmds.each do |c|
      code = c.respond_to?(:code) ? c.code : c[:code]
      indent = c.respond_to?(:indent) ? c.indent : c[:indent]
      str = binstr(utf8_to_cp932((c.respond_to?(:string) ? c.string : c[:string]) || ''))
      params = c.respond_to?(:parameters) ? c.parameters : c[:parameters]
      out = out + write_ber(code) + write_ber(indent) +
            write_ber(str.bytesize) + str + write_ber(params.size)
      params.each { |p| out = out + write_ber(p) }
    end
    out
  end

  # Decode a packed move-command list (the `:move_commands` schema type used by
  # event-page and common-event move routes). Unlike event commands, each entry
  # is a bare command id optionally followed by a length-prefixed cp932 string
  # and/or a few BER integer parameters, selected by the id. The list runs to
  # the end of the blob (its length is also stored separately as `command_size`).
  def parse_move_commands d
    s = StringIO.new d
    cmds = []
    until s.eof?
      id = read_ber s
      str = ''
      a = b = c = 0
      case id
      when MOVE_SWITCH_ON, MOVE_SWITCH_OFF
        a = read_ber s
      when MOVE_CHANGE_GRAPHIC
        slen = read_ber s
        str = slen > 0 ? cp932_to_utf8(s.read(slen)) : ''
        a = read_ber s
      when MOVE_PLAY_SOUND
        slen = read_ber s
        str = slen > 0 ? cp932_to_utf8(s.read(slen)) : ''
        a = read_ber s
        b = read_ber s
        c = read_ber s
      end
      cmds.push MoveCommand.new(id, str, a, b, c)
    end
    cmds
  end

  # Encode a list of MoveCommand (or {command_id:, parameter_string:,
  # parameter_a:, parameter_b:, parameter_c:} Hashes) back to the packed blob
  # #parse_move_commands reads -- its exact inverse. Only the fields the
  # command's own id actually carries get written, mirroring the reader's own
  # `case id` dispatch (a bare command carries nothing past its id).
  def encode_move_commands(cmds)
    out = String.new
    cmds.each do |c|
      id = c.respond_to?(:command_id) ? c.command_id : c[:command_id]
      str_field = c.respond_to?(:parameter_string) ? c.parameter_string : c[:parameter_string]
      a = (c.respond_to?(:parameter_a) ? c.parameter_a : c[:parameter_a]) || 0
      b = (c.respond_to?(:parameter_b) ? c.parameter_b : c[:parameter_b]) || 0
      cc = (c.respond_to?(:parameter_c) ? c.parameter_c : c[:parameter_c]) || 0
      out = out + write_ber(id)
      case id
      when MOVE_SWITCH_ON, MOVE_SWITCH_OFF
        out = out + write_ber(a)
      when MOVE_CHANGE_GRAPHIC
        str = binstr(utf8_to_cp932(str_field || ''))
        out = out + write_ber(str.bytesize) + str + write_ber(a)
      when MOVE_PLAY_SOUND
        str = binstr(utf8_to_cp932(str_field || ''))
        out = out + write_ber(str.bytesize) + str + write_ber(a) + write_ber(b) + write_ber(cc)
      end
    end
    out
  end

  # Holds the sequential sections of a multi-section file (e.g. the map tree,
  # which is a map-properties table followed by the tree order and the initial
  # party/vehicle positions). Sections are reachable by their schema name;
  # #[] indexes into the first section for convenience.
  class Sections
    def initialize
      @by_name = {}
      @list = []
    end

    def add name, value
      @by_name[name] = value
      @list.push value
    end

    def [] idx ; @list.first[idx] end

    def method_missing sym, *args
      return @by_name[sym] if @by_name.key? sym
      super
    end

    def respond_to_missing? sym, include_private = false
      @by_name.key?(sym) || super
    end
  end

  # Read one section of a file sequentially from the stream +io+.
  def read_section io, s
    case s[:type]
    when :Array2D ; Array2D.new io, s
    when :Array1D ; Array1D.new io, s
    when :Tree
      map_count = read_ber io
      maps = Array.new(map_count) { read_ber io }
      Tree.new read_ber(io), maps
    else
      raise "Unsupported section type: #{s[:type]}"
    end
  end

  def to_rb d, s
    # An absent field yields its schema default. A callable (`-> { ... }`)
    # default is lazy -- evaluate it -- so edition-dependent defaults such as
    # max level and the exp curve resolve to their value, not the Proc itself.
    unless d
      dv = s[:default]
      return dv.respond_to?(:call) ? dv.call : dv
    end

    case s[:type]
    when :Array1D ; return Array1D.new d, s
    when :Array2D ; return Array2D.new d, s
    when :int ; return read_ber StringIO.new(d)
    when :bool
      raise "invalid bool size: #{d.size}" if d.size != 1
      return d.bytes[0] != 0
    when :int16_array
      vals = d.unpack('s<*')
      return vals unless s[:order]
      h = {}
      s[:order].each_with_index { |name, i| h[name] = vals[i] }
      return h
    when :int8_array ; return d.bytes
    when :uint8 ; return d.bytes[0]
    when :bool_array ; return d.bytes.map { |b| b != 0 }
    when :int32_array ; return unpack_int32(d)
    when :double ; return unpack_double(d)
    when :event ; return parse_event_commands(d)
    when :move_commands ; return parse_move_commands(d)
    when :string ; return LCF.cp932_to_utf8 d
    when :Tree
      s = StringIO.new(d)
      map_count = read_ber s
      maps = []
      (0...map_count).each { maps.push read_ber s }
      selected_id = read_ber s
      return Tree.new(selected_id, maps)
    end

    raise "Unsupported type: #{s[:type]}"
  end

  # Decode a packed sequence of little-endian signed 32bit integers.
  def unpack_int32 d
    bytes = d.bytes
    out = []
    (0...(bytes.size / 4)).each do |i|
      b = i * 4
      v = bytes[b] | (bytes[b + 1] << 8) | (bytes[b + 2] << 16) | (bytes[b + 3] << 24)
      v -= 0x1_0000_0000 if v >= 0x8000_0000
      out.push v
    end
    out
  end

  # Decode a little-endian IEEE-754 64bit double (used by the save file's
  # timestamp field). Assembled from raw bytes -- like unpack_int32 -- so it does
  # not depend on the optional 'E' pack directive. Returns nil for a short blob.
  def unpack_double d
    return nil if d.nil? || d.bytesize < 8
    b = d.bytes
    bits = 0
    7.downto(0) { |i| bits = (bits << 8) | b[i] }
    sign = (bits >> 63) & 1
    exp  = (bits >> 52) & 0x7ff
    frac = bits & 0x000f_ffff_ffff_ffff
    if exp == 0x7ff
      return 0.0 / 0.0 unless frac == 0 # NaN
      return sign == 1 ? (-1.0 / 0.0) : (1.0 / 0.0) # +/- infinity
    elsif exp == 0
      val = frac * (2.0 ** -1074)
    else
      val = (1.0 + frac * (2.0 ** -52)) * (2.0 ** (exp - 1023))
    end
    sign == 1 ? -val : val
  end

  # Coerce a value to a raw byte string safe to concatenate with other byte
  # strings. Under CRuby (the analysis harnesses) this re-tags it ASCII-8BIT so
  # appending cp932 bytes to a binary buffer does not raise on encoding
  # mismatch; under mruby (no Encoding class) strings are already raw bytes and
  # #force_encoding is absent, so it is a no-op.
  def binstr s
    s = s.to_s
    s.respond_to?(:force_encoding) ? s.dup.force_encoding('BINARY') : s
  end

  # Encode an array of signed 32bit integers as packed little-endian bytes --
  # the inverse of unpack_int32 (used for the save file's variable table).
  def pack_int32 a
    out = []
    a.each do |v|
      v &= 0xffff_ffff
      out.push(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff)
    end
    out.pack('C*')
  end

  # Encode an array of 16bit integers as packed little-endian bytes -- the
  # inverse of `unpack('s<*')` (the :int16_array reader). Each value is masked to
  # its low 16 bits, so the signed reinterpretation the reader applies
  # round-trips exactly. Built byte-wise rather than via `pack('s<*')` so it does
  # not depend on mruby-pack's endian-suffix pack support (the readers only rely
  # on unpack). Used for the save's item-id, equipment and skill tables.
  def pack_int16 a
    out = []
    a.each do |v|
      v &= 0xffff
      out.push(v & 0xff, (v >> 8) & 0xff)
    end
    out.pack('C*')
  end

  # Encode a Ruby Float as a little-endian IEEE-754 64bit double -- the inverse
  # of unpack_double (the save file's timestamp field). Assembled byte-wise from
  # the sign / biased exponent / 52bit mantissa so it needs neither the 'E' pack
  # directive nor a full 64bit integer (mruby's Integer is 63bit): the sign and
  # exponent land in the top two bytes and the mantissa fills the low seven, so
  # no intermediate value ever exceeds 2**52. Finite values (including 0.0) and
  # NaN are handled; a timestamp is always finite and non-negative, which is also
  # the domain unpack_double reproduces exactly (its 63bit assembly cannot hold a
  # bit pattern with the sign or a very large exponent set).
  def pack_double v
    v = v.to_f
    sign = 0
    if v != v                       # NaN
      exp = 0x7ff
      frac = 1 << 51
    elsif v == 0.0
      exp = 0
      frac = 0
    else
      if v < 0.0
        sign = 1
        v = -v
      end
      e = 0
      while v >= 2.0 && e < 1024
        v = v / 2.0
        e = e + 1
      end
      while v < 1.0 && e > -1074
        v = v * 2.0
        e = e - 1
      end
      exp = e + 1023
      # 52bit mantissa of the normalised significand (1.xxxx -> xxxx), rounded.
      frac = ((v - 1.0) * 4503599627370496.0 + 0.5).to_i
      if frac >= 4503599627370496   # rounding carried into the next binade
        frac = 0
        exp = exp + 1
      end
      if exp >= 0x7ff               # overflow -> infinity
        exp = 0x7ff
        frac = 0
      elsif exp <= 0                # underflow -> flush to zero
        exp = 0
        frac = 0
      end
    end
    b = []
    b[0] = frac & 0xff
    b[1] = (frac >> 8) & 0xff
    b[2] = (frac >> 16) & 0xff
    b[3] = (frac >> 24) & 0xff
    b[4] = (frac >> 32) & 0xff
    b[5] = (frac >> 40) & 0xff
    b[6] = ((exp & 0xf) << 4) | ((frac >> 48) & 0xf)
    b[7] = (sign << 7) | ((exp >> 4) & 0x7f)
    b.pack('C*')
  end

  # Encode a Ruby value back to the raw chunk bytes for a schema field -- the
  # inverse of to_rb. A nested :Array1D / :Array2D value is serialised through
  # its own #to_lcf. Strings go back out as cp932 via LCF.utf8_to_cp932 (the
  # build's uni-algo encoder; the CRuby harnesses provide a Windows-31J
  # stand-in), mirroring cp932_to_utf8 on read. :Tree is not handled here: it
  # is a whole-file section type (LCF::MapTree's multi-section root), never a
  # field type an Array1D chunk carries, so it never reaches #[]=.
  def encode value, type
    case type
    when :int ; write_ber value
    when :bool ; [value ? 1 : 0].pack('C')
    when :uint8 ; [value & 0xff].pack('C')
    when :double ; pack_double value
    when :int8_array ; value.pack('C*')
    when :bool_array ; value.map { |b| b ? 1 : 0 }.pack('C*')
    when :int16_array ; pack_int16 value
    when :int32_array ; pack_int32 value
    when :string ; utf8_to_cp932 value
    when :event ; encode_event_commands value
    when :move_commands ; encode_move_commands value
    when :Array1D, :Array2D
      return binstr(value) if value.is_a? String
      value.to_lcf
    else
      raise "cannot encode type: #{type}"
    end
  end

  module_function :read_ber, :write_ber, :to_rb, :read_section,
                  :parse_event_commands, :encode_event_commands,
                  :parse_move_commands, :encode_move_commands,
                  :unpack_int32, :unpack_double, :pack_int32, :pack_int16,
                  :pack_double, :encode, :binstr

  MODE = 2000 # 2003

  def var_max; MODE == 2003 ?  9_999_999 :  999_999 end
  def var_min; MODE == 2003 ? -9_999_999 : -999_999 end

  def level_max; MODE == 2003 ? 99 : 50 end
  def pc_hp_max; MODE == 2003 ? 9999 : 999 end
  def npc_hp_max; MODE == 2003 ? 99_999 : 9999 end

  def exp_default; MODE == 2003 ? 300 : 30 end

  # Edition-dependent helpers are referenced as `LCF.<name>` from lazy schema
  # defaults (`-> { LCF.level_max }` etc.), so they must be module functions --
  # otherwise calling the default raises NoMethodError for module LCF.
  module_function :var_max, :var_min, :level_max, :pc_hp_max, :npc_hp_max,
                  :exp_default

  class Array1D
    def initialize s, schema
      s = StringIO.new s if s.is_a? String

      @data = []
      @schema = schema

      loop do
        break if s.eof?

        idx = LCF.read_ber s
        break if idx == 0

        len = LCF.read_ber s
        @data[idx] = s.read len
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
    def [] idx
      cached = @decoded && @decoded[idx]
      return cached if cached
      elem = @schema[:elements][idx]
      value = LCF.to_rb @data[idx], elem
      if value.is_a?(Array1D) || value.is_a?(Array2D) ||
         elem[:type] == :event || elem[:type] == :move_commands
        @decoded ||= {}
        @decoded[idx] = value
      end
      value
    end

    # True when a chunk with this id was physically present in the file, before
    # any schema default is applied. Lets callers tell an absent optional
    # section from one that is present but empty (both read as a falsy value
    # through []), which is how the RPG2000/2003 edition is detected.
    def key? idx
      !@data[idx].nil?
    end

    # Raw little-endian int16 values of a chunk, bypassing any schema `order`
    # mapping. Lets a caller read a variable-length short array (e.g. the actor
    # parameter growth curve, six shorts per level) whose named accessor only
    # surfaces the first row. Returns nil when the chunk is absent.
    def int16_values idx
      d = @data[idx]
      d && d.unpack('s<*')
    end

    # Drop a chunk entirely, so #to_lcf omits it rather than writing an empty
    # one. An absent chunk and a present-but-empty chunk are different files to
    # the genuine runtime, and only the former means "nothing here": clearing
    # the running-event continuation (113) by writing empty bytes leaves a
    # zero-command interpreter state behind, where removing the chunk resumes
    # with no event running at all. Returns the removed raw bytes, or nil.
    def delete idx
      was = @data[idx]
      @data[idx] = nil
      @decoded.delete(idx) if @decoded
      was
    end

    # Set the raw bytes of a chunk from a Ruby value, encoding it through the
    # schema type of that field (LCF.encode) so an authored/edited section can
    # be written back out. With no schema attached a raw String is stored as-is.
    def []= idx, value
      elem = @schema && @schema[:elements] && @schema[:elements][idx]
      if elem
        @data[idx] = LCF.encode(value, elem[:type])
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
      @data.each_with_index do |v, idx|
        next if idx == 0 || v.nil?
        bytes = LCF.binstr(v.is_a?(String) ? v : v.to_lcf)
        out = out + LCF.write_ber(idx) + LCF.write_ber(bytes.bytesize) + bytes
      end
      out = out + LCF.write_ber(0) if terminate
      out
    end

    def method_missing sym, *args
      raise args unless args.empty?
      self[sym2idx[sym]]
    end

    def respond_to_missing? sym, include_private = false
      (@schema && sym2idx.key?(sym)) || super
    end

    private

    # Field-name -> chunk-id lookup for method_missing dispatch, built lazily
    # (only paid by callers that actually use a symbolic field accessor --
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
      @sym2idx = @schema[:sym2idx]
      return @sym2idx if @sym2idx
      @sym2idx = {}
      @schema[:elements].each { |k, e| @sym2idx[e[:name]] = k }
      @schema[:sym2idx] = @sym2idx
    end
  end

  class Array2D
    def initialize s, schema
      s = StringIO.new s if s.is_a? String

      @data = []
      @schema = schema

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
        @data[idx] = read_row_bytes(s)
      end
    end

    # Decode (and cache) row +idx+ on first access; a row never read stays a
    # raw byte span forever. nil for an id the table never had.
    def [] idx
      entry = @data[idx]
      return entry unless entry.is_a? String
      @data[idx] = Array1D.new(entry, @schema)
    end

    # Store an entry (an Array1D, or its already-serialised bytes) at id +idx+,
    # so an authored table can be assembled and written back out via #to_lcf.
    def []= idx, entry
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
        bytes = LCF.binstr(entry.is_a?(String) ? entry : entry.to_lcf)
        out = out + LCF.write_ber(i) + bytes
      end
      out
    end

    private

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
      out = String.new
      loop do
        break if s.eof?
        idx = LCF.read_ber s
        out = out + LCF.write_ber(idx)
        break if idx == 0
        len = LCF.read_ber s
        out = out + LCF.write_ber(len) + s.read(len)
      end
      out
    end
  end
end

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
    [ret].pack('L').unpack1('l')
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

  module_function :read_ber, :to_rb, :read_section, :parse_event_commands,
                  :parse_move_commands, :unpack_int32, :unpack_double

  MODE = 2000 # 2003

  def var_max; MODE == 2003 ?  9_999_999 :  999_999 end
  def var_min; MODE == 2003 ? -9_999_999 : -999_999 end

  def level_max; MODE == 2003 ? 99 : 50 end
  def pc_hp_max; MODE == 2003 ? 9999 : 999 end
  def npc_hp_max; MODE == 2003 ? 99_999 : 9999 end

  def exp_default; MODE == 2003 ? 300 : 30 end

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

      if @schema
        @sym2idx = {}
        @schema[:elements].each do |k, e|
          @sym2idx[e[:name]] = k
        end
      end
    end

    attr_reader :schema

    def [] idx
      LCF.to_rb @data[idx], @schema[:elements][idx]
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

    def method_missing sym, *args
      raise args unless args.empty?
      self[@sym2idx[sym]]
    end

    def respond_to_missing? sym, include_private = false
      (@sym2idx && @sym2idx.key?(sym)) || super
    end
  end

  class Array2D
    def initialize s, schema
      s = StringIO.new s if s.is_a? String

      @data = []
      @scheme = schema

      (0...LCF.read_ber(s)).each do
        @data[LCF.read_ber s] = Array1D.new(s, schema)
      end
    end

    def [] idx ; @data[idx] end

    # Iterate over defined (id, Array1D) entries; useful for walking event or
    # actor tables that are sparsely populated.
    def each
      @data.each_with_index do |v, i|
        yield i, v unless v.nil?
      end
    end
    include Enumerable
  end
end

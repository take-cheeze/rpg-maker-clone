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

  # Read a tree structure (used by the map tree's `tree` element) from a live
  # stream: a BER-encoded count, that many BER map ids, then the selected id.
  def read_tree s
    map_count = read_ber s
    maps = []
    (0...map_count).each { maps.push read_ber s }
    selected_id = read_ber s
    Tree.new(selected_id, maps)
  end

  # Decode a packed sequence of little-endian 16bit integers (as used by map
  # tile layers and chipset passability tables). `signed` interprets values
  # >= 0x8000 as negative; tile ids are unsigned while some tables are signed.
  def unpack_shorts d, signed = false
    bytes = d.bytes
    out = []
    (0...(bytes.size / 2)).each do |i|
      v = bytes[i * 2] | (bytes[i * 2 + 1] << 8)
      v -= 0x10000 if signed && v >= 0x8000
      out.push v
    end
    out
  end

  # Parse a single top-level element of a multi-part file (see LCF::File) from a
  # live stream, dispatching on the structural type.
  def parse_stream s, schema
    case schema[:type]
    when :Array1D ; Array1D.new s, schema
    when :Array2D ; Array2D.new s, schema
    when :Tree ; read_tree s
    else raise "Unsupported top-level type: #{schema[:type]}"
    end
  end

  def to_rb d, s
    return s[:default] unless d

    case s[:type]
    when :Array1D ; return Array1D.new d, s
    when :Array2D ; return Array2D.new d, s
    when :int ; return read_ber StringIO.new(d)
    when :bool
      raise "invalid bool size: #{d.size}" if d.size != 0
      return d.bytes[0] != 0
    when :string ; return LCF.cp932_to_utf8 d
    when :Tree ; return read_tree StringIO.new(d)
    when :short_array ; return unpack_shorts(d, false)
    when :int16_array
      vals = unpack_shorts(d, true)
      order = s[:order]
      return vals unless order
      h = {}
      order.each_with_index { |k, i| h[k] = vals[i] }
      return h
    end

    raise "Unsupported type: #{s[:type]}"
  end

  module_function :read_ber, :read_tree, :unpack_shorts, :parse_stream, :to_rb

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

    def method_missing sym, *args
      raise args unless args.empty?
      self[@sym2idx[sym]]
    end
  end

  class Array2D
    def initialize s, schema
      # Nested Array2D fields (e.g. the database's actor table) arrive as a raw
      # byte string, while top-level tables are read from a live stream; wrap
      # strings so both work.
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

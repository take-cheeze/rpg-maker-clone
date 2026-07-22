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
    return s[:default] unless d

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

  module_function :read_ber, :to_rb, :read_section

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
      s = StringIO.new s if s.is_a? String

      @data = []
      @scheme = schema

      (0...LCF.read_ber(s)).each do
        @data[LCF.read_ber s] = Array1D.new(s, schema)
      end
    end

    def [] idx ; @data[idx] end
  end
end

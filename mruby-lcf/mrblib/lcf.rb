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
    end

    raise "Unsupported type: #{s[:type]}"
  end

  module_function :read_ber, :to_rb

  MODE = 2000 # 2003

  def var_max; MODE == 2003 ?  9_999_999 :  999_999 end
  def var_min; MODE == 2003 ? -9_999_999 : -999_999 end

  def level_max; MODE == 2003 ? 99 : 50 end
  def pc_hp_max; MODE == 2003 ? 9999 : 999 end
  def npc_hp_max; MODE == 2003 ? 99_999 : 9999 end

  def exp_default; MODE == 2003 ? 300 : 30 end

  class Array1D
    def initialize s, schema
      s = StringIO.new s unless s.kind_of? IO

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
      @data = []
      @scheme = schema

      (0...LCF.read_ber(s)).each do
        @data[LCF.read_ber s] = Array1D.new(s, schema)
      end
    end

    def [] idx ; @data[idx] end
  end
end

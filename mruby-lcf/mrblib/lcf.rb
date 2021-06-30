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

  module_function :read_ber

  MODE = 2000 # 2003

  def var_max; MODE == 2003 ?  9_999_999 :  999_999 end
  def var_min; MODE == 2003 ? -9_999_999 : -999_999 end

  def level_max; MODE == 2003 ? 99 : 50 end
  def pc_hp_max; MODE == 2003 ? 9999 : 999 end
  def npc_hp_max; MODE == 2003 ? 99_999 : 9999 end

  def exp_default; MODE == 2003 ? 300 : 30 end

  class Array1D
    def initialize s, schema = nil
      @data = []
      @schame = schema

      loop do
        break if s.eof?

        idx = read_ber s
        break if idx.zero?

        len = read_ber s
        @data[idx] = s.read len
      end
    end
  end

  class Array2D
    def initialize s, schema = nil
      @data = []
      @scheme = schema

      (0...read_ber(s)).each do
        @data[read_ber s] = Array1D.new(s, schema)
      end
    end
  end
end

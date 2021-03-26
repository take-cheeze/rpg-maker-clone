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
end

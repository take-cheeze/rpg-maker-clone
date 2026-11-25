# frozen_string_literal: true

# CRuby stand-ins for mruby-lcf's native integer and double codecs (src/lcf.cxx), for the harnesses that load
# mruby-lcf/mrblib under CRuby. They give the native results byte for byte; mruby-lcf/test/lcf_test.rb holds the
# native ones to the same edge cases.
module LCF
  def self.int32(v)
    v &= 0xffff_ffff
    v >= 0x8000_0000 ? v - 0x1_0000_0000 : v
  end

  def self.ber_shift(ret, b)
    int32((ret << 7) | (b & 0x7f))
  end

  def self.ber_value(d)
    ret = 0
    i = 0
    loop do
      b = d.getbyte(i)
      raise 'truncated BER integer' if b.nil?

      i += 1
      ret = ((ret << 7) | (b & 0x7f)) & 0xffff_ffff
      break if (b & 0x80).zero?
    end
    int32(ret)
  end

  def self.append_ber(out, n)
    n &= 0xffff_ffff
    shift = 0
    shift += 7 while (n >> shift) > 0x7f
    while shift.positive?
      out << "\0"
      out.setbyte(-1, ((n >> shift) & 0x7f) | 0x80)
      shift -= 7
    end
    out << "\0"
    out.setbyte(-1, n & 0x7f)
    out
  end

  def self.unpack_int32(d)
    d.b.unpack('l<*')
  end

  def self.pack_int32(a)
    a.map { |v| v & 0xffff_ffff }.pack('L<*')
  end

  def self.unpack_double(d)
    return nil if d.nil? || d.bytesize < 8

    d.b.unpack1('E')
  end

  def self.pack_double(v)
    v = v.to_f
    return "\x00\x00\x00\x00\x00\x00\xf8\x7f".b if v.nan?
    raise FloatDomainError, 'Infinity' if v.infinite?
    return "\x00".b * 8 if v.zero? || (v.abs < 2.2250738585072014e-308 && v.positive?)
    return "#{"\x00" * 7}\x80".b if v.abs < 2.2250738585072014e-308

    [v].pack('E')
  end
end

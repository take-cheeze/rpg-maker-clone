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

  # LCF.ber_at / LCF.ber_next / LCF.row_end (CURSOR): a BER integer at a byte position of a String.
  def self.ber_read(s, pos)
    raise ArgumentError, 'negative LCF position' if pos.negative?

    ret = 0
    loop do
      b = s.getbyte(pos)
      raise 'truncated BER integer' if b.nil?

      pos += 1
      ret = ((ret << 7) | (b & 0x7f)) & 0xffff_ffff
      return [int32(ret), pos] if (b & 0x80).zero?
    end
  end

  def self.ber_at(s, pos) = ber_read(s, pos)[0]

  def self.ber_next(s, pos) = ber_read(s, pos)[1]

  def self.row_end(s, pos)
    size = s.bytesize
    while pos < size
      idx, pos = ber_read(s, pos)
      break if idx.zero?

      len, pos = ber_read(s, pos)
      raise "truncated chunk #{idx}: #{len} bytes declared" if len.negative? || len > size - pos

      pos += len
    end
    pos
  end

  # LCF.chunk_at (LAZY_RECORD): the offset of the length of the last chunk +want+ of a record, or nil.
  def self.chunk_at(s, want)
    raise TypeError, 'no implicit conversion into Integer' unless want.is_a?(Integer)

    size = s.bytesize
    pos = 0
    found = nil
    while pos < size
      idx, pos = ber_read(s, pos)
      break if idx.zero?

      at = pos
      len, pos = ber_read(s, pos)
      raise "truncated chunk #{idx}: #{len} bytes declared" if len.negative? || len > size - pos

      found = at if idx == want
      pos += len
    end
    found
  end

  # EVENT_LIST (src/lcf.cxx): an :event_packed list's offset index, and the fields of one command.
  def self.event_index(bytes)
    width = bytes.bytesize <= 0xffff ? 2 : 4
    starts = []
    pos = 0
    while pos < bytes.bytesize
      starts << pos
      pos = event_skip(bytes, pos)
    end
    starts.pack(width == 2 ? 'v*' : 'V*')
  end

  def self.event_skip(bytes, pos)
    _, pos = ber_read(bytes, pos)
    _, pos = ber_read(bytes, pos)
    slen, pos = ber_read(bytes, pos)
    if slen.positive?
      raise 'truncated BER integer' if slen > bytes.bytesize - pos

      pos += slen
    end
    pcount, pos = ber_read(bytes, pos)
    pcount.times { _, pos = ber_read(bytes, pos) }
    pos
  end

  def self.event_count(bytes, starts) = starts.bytesize / (bytes.bytesize <= 0xffff ? 2 : 4)

  def self.event_field(bytes, starts, i, field)
    raise IndexError, "event command #{i} outside the list" unless i >= 0 && i < event_count(bytes, starts)

    pos = starts.unpack(bytes.bytesize <= 0xffff ? 'v*' : 'V*')[i]
    field.times do |f|
      v, pos = ber_read(bytes, pos)
      pos += v if f == 2 && v.positive?
    end
    pos
  end

  def self.event_code(bytes, starts, i) = ber_at(bytes, event_field(bytes, starts, i, 0))

  def self.event_indent(bytes, starts, i) = ber_at(bytes, event_field(bytes, starts, i, 1))

  def self.event_string(bytes, starts, i)
    slen, pos = ber_read(bytes, event_field(bytes, starts, i, 2))
    return nil unless slen.positive?

    cp932_to_utf8(bytes.byteslice(pos, slen))
  end

  def self.event_params(bytes, starts, i)
    pcount, pos = ber_read(bytes, event_field(bytes, starts, i, 3))
    Array.new([pcount, 0].max) do
      v, pos = ber_read(bytes, pos)
      v
    end
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

  # LCF::ShortArray (src/lcf.cxx): a fixed-size signed int16 table.
  class ShortArray
    def self.unpack(d)
      a = new(0)
      a.instance_variable_set(:@v, d.b.unpack('s<*'))
      a
    end

    def initialize(n)
      raise TypeError, "#{n.class} is not an Integer" unless n.is_a?(Integer)
      raise ArgumentError, 'invalid LCF::ShortArray size' if n.negative?

      @v = Array.new(n, 0)
    end

    def initialize_copy(src)
      super
      @v = src.to_a
    end

    def get(i)
      raise TypeError, "#{i.class} is not an Integer" unless i.is_a?(Integer)

      @v[i]
    end

    def set(i, v)
      raise TypeError, "#{i.class} is not an Integer" unless i.is_a?(Integer)

      at = i.negative? ? i + @v.size : i
      raise IndexError, "index #{i} outside LCF::ShortArray of size #{@v.size}" unless at >= 0 && at < @v.size
      raise TypeError, "#{v.class} is not an Integer" unless v.is_a?(Integer)
      raise RangeError, "#{v} is outside int16 (-32768..32767)" unless v.between?(-32_768, 32_767)

      @v[at] = v
    end

    def [](i) = get(i)

    def []=(i, v)
      set(i, v)
    end

    def size = @v.size

    def each(&block)
      raise ArgumentError, 'no block given' unless block

      @v.each_index { |i| yield @v[i] }
      self
    end

    def to_a = @v.dup
    def to_lcf = @v.pack('s<*')
  end
end

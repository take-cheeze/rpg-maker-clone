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

assert 'Read BER number' do
  [
    [0x7f, "\x7f"],
    [0x80, "\x81\x00"],
    [-1, "\x8f\xff\xff\xff\x7f"],
  ].each do |num, data|
    s = StringIO.new(data)
    assert_equal num, LCF.read_ber(s)
    assert_true s.eof?
  end
end

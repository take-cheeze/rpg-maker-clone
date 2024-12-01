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

assert "cp932 to unicode" do
  assert_equal "あ", LCF.cp932_to_utf8("\x82\xa0")
  assert_equal "あああ", LCF.cp932_to_utf8("\x82\xa0\x82\xa0\x82\xa0")
  assert_equal "AあA", LCF.cp932_to_utf8("A\x82\xa0A")
  assert_equal "LcfDataBase", LCF.cp932_to_utf8("LcfDataBase")
end

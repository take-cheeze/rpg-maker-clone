HEIGHT = 12
FONT_DIR = "#{File.dirname __FILE__}/../3rd/shinonome-0.9.11-src/#{HEIGHT}"

File.write "shinonome.hxx", <<EOS
#pragma once

#include <cstdint>
#include <array>

namespace shinonome {

static constexpr unsigned HEIGHT = #{HEIGHT};

template<unsigned W>
struct Char {
  static constexpr unsigned WIDTH = W;
  static constexpr unsigned HEIGHT = shinonome::HEIGHT;
  static constexpr unsigned PIXELS = W * HEIGHT;
  char32_t codepoint;
  std::array<uint32_t, PIXELS / 32 + ((PIXELS % 32) > 0 ? 1 : 0)> data;
};

extern const Char<HEIGHT / 2> HANKAKU[];
extern const unsigned HANKAKU_LEN;
extern const Char<HEIGHT / 2> LATIN1[];
extern const unsigned LATIN1_LEN;
extern const Char<HEIGHT> GOTHIC[];
extern const unsigned GOTHIC_LEN;
extern const Char<HEIGHT> MINCHO[];
extern const unsigned MINCHO_LEN;

}
EOS

jis0208_table = {}
File.read(ENV["jis0208_table"], external_encoding: Encoding::UTF_8).each_line do |l|
  s, j, u = l.sub(/#.*/, '').split
  next if s.nil?
  jis0208_table[j.to_i(16)] = u.to_i 16
end

f = File.new "shinonome.cxx", "w"

f.write <<EOS

#include "shinonome.hxx"

namespace shinonome {

EOS

{
  hankaku: ["HANKAKU", "CP932", false],
  kanjic: ["GOTHIC", "JIS0208", true],
  latin1: ["LATIN1", "ISO-8859-1", false],
  mincho: ["MINCHO", "JIS0208", true],
}.each do |k, (name, encoding, full)|
  if File.exist? "#{FONT_DIR}/#{k}/font_src.bit"
    src = File.read "#{FONT_DIR}/#{k}/font_src.bit", external_encoding: Encoding::SJIS
  else
    src = File.read "#{FONT_DIR}/#{k}/font_src_diff.bit", external_encoding: Encoding::SJIS
  end

  t = {}
  c = nil
  bmp = []
  src.each_line do |l|
    if l.start_with? "STARTCHAR"
      c = l.split[1].to_i 16
      if encoding == "JIS0208"
        c = jis0208_table[c]
      else
        begin
          c = c.chr.encode("UTF-8", encoding).codepoints[0]
        rescue EncodingError
          p "Unknonwn char: #{c}"
        end
      end
      raise "Unknown char: #{l}" if c.nil?
    elsif l.start_with? "ENDCHAR"
      raise "Uknown char" if c.nil?
      t[c] = bmp
      bmp = []
    elsif l.start_with? "BITMAP"
      bmp = []
    else
      bmp << l
    end
  end

  f.write <<EOS
const unsigned #{name}_LEN = #{t.size};
const Char<#{full ? "HEIGHT" : "HEIGHT / 2"}> #{name}[] = {
EOS

  t.sort.to_h.each do |u, b|
    b = b.map(&:strip).reduce(&:+)
    d = b.scan(/.{1,32}/).map do |s|
      v = 0
      s.each_char.each_with_index do |p, idx|
        v |= (1 << idx) if p == "@"
      end
      "0x#{v.to_s(16)}"
    end
    f.write <<EOS
  { 0x#{u.to_s(16)}, {#{d.join(", ")}} },
EOS
  end

  f.write <<EOS
};
EOS
end

f.write <<EOS
}
EOS

f.close

# frozen_string_literal: true

# The light encoding model the Prism Ruby half needs on mruby, which has no encodings. It is prepended to the
# generated Prism sources by tools/build_mrblib.rb.
#
#   - Encoding: the constants Prism compares against, and Encoding.find by name.
#   - String#encoding / force_encoding: a tag kept per string object. A string has UTF-8 unless tagged.
#   - String#inspect for UTF-8 with non-ASCII bytes: \uXXXX (and \u{...} above U+FFFF), as CRuby prints it under a
#     non-UTF-8 locale. Other strings keep mruby's inspect.
#
# The tags are keyed by object_id, so they are only as good as object ids are stable; that holds for the short
# parse-and-inspect use this is for, and nothing else in this gem depends on tags.

RUBY_ENGINE = "mruby" unless defined?(RUBY_ENGINE)

class Encoding
  attr_reader :name

  def initialize(name)
    @name = name
  end

  def to_s
    @name
  end

  def inspect
    "#<Encoding:#{@name}>"
  end

  def ==(other)
    other.is_a?(Encoding) && other.name == @name
  end

  def self.find(name)
    name = name.to_s.upcase
    (constants_by_name[name] or new(name))
  end

  def self.constants_by_name
    {
      "ASCII-8BIT" => BINARY, "BINARY" => BINARY, "UTF-8" => UTF_8, "US-ASCII" => US_ASCII,
      "ASCII" => US_ASCII, "UTF-16LE" => UTF_16LE, "UTF-16BE" => UTF_16BE, "UTF-32LE" => UTF_32LE,
      "UTF-32BE" => UTF_32BE, "ISO-8859-1" => ISO_8859_1, "WINDOWS-31J" => WINDOWS_31J,
      "EUC-JP" => EUC_JP, "SHIFT_JIS" => SHIFT_JIS, "UTF-16" => UTF_16, "UTF-32" => UTF_32
    }
  end

  BINARY = new("ASCII-8BIT")
  UTF_8 = new("UTF-8")
  US_ASCII = new("US-ASCII")
  UTF_16LE = new("UTF-16LE")
  UTF_16BE = new("UTF-16BE")
  UTF_32LE = new("UTF-32LE")
  UTF_32BE = new("UTF-32BE")
  ISO_8859_1 = new("ISO-8859-1")
  WINDOWS_31J = new("WINDOWS-31J")
  EUC_JP = new("EUC-JP")
  SHIFT_JIS = new("SHIFT_JIS")
  UTF_16 = new("UTF-16")
  UTF_32 = new("UTF-32")
end

class String
  # Tags by object id. mruby strings cannot carry instance variables.
  def self.__light_encodings
    @__light_encodings ||= {}
  end

  def encoding
    String.__light_encodings[object_id] || Encoding::UTF_8
  end

  def force_encoding(encoding)
    String.__light_encodings[object_id] = encoding
    self
  end

  def b
    dup.force_encoding(Encoding::BINARY)
  end

  def valid_encoding?
    true
  end

  def ascii_only?
    bytes.all? { |byte| byte < 128 }
  end

  alias __light_core_inspect inspect

  def inspect
    return __light_core_inspect unless encoding == Encoding::UTF_8 && !ascii_only?

    out = +'"'
    data = bytes
    i = 0
    while i < data.size
      byte = data[i]
      if byte < 128
        out << __light_escape_ascii(byte, data[i + 1])
        i += 1
      else
        length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC2 ? 2 : 0
        codepoint = __light_codepoint(data, i, length)
        if codepoint
          out << (codepoint > 0xFFFF ? format("\\u{%X}", codepoint) : format("\\u%04X", codepoint))
          i += length
        else
          out << format("\\x%02X", byte)
          i += 1
        end
      end
    end
    out << '"'
  end

  def __light_escape_ascii(byte, following)
    case byte
    when 0x22 then '\\"'
    when 0x5C then '\\\\'
    when 0x0A then '\\n'
    when 0x09 then '\\t'
    when 0x0D then '\\r'
    when 0x1B then '\\e'
    when 0x07 then '\\a'
    when 0x08 then '\\b'
    when 0x0C then '\\f'
    when 0x0B then '\\v'
    when 0x23 then (following == 0x7B || following == 0x24 || following == 0x40) ? '\\#' : '#'
    when 0x7F then '\\x7F'
    else
      byte < 0x20 ? format("\\u%04X", byte) : byte.chr
    end
  end

  def __light_codepoint(data, i, length)
    return nil if length == 0 || i + length > data.size

    codepoint = data[i] & (0xFF >> (length + 1))
    (1...length).each do |k|
      continuation = data[i + k]
      return nil unless continuation & 0xC0 == 0x80

      codepoint = (codepoint << 6) | (continuation & 0x3F)
    end
    return nil if length == 3 && (codepoint < 0x800 || (codepoint >= 0xD800 && codepoint <= 0xDFFF))
    return nil if length == 4 && (codepoint < 0x10000 || codepoint > 0x10FFFF)

    codepoint
  end
end

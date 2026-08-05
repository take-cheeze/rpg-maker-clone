#!/usr/bin/env ruby
# Verify the bundled default font is a font the engine can actually use.
#
# assets/fonts holds the fallback UI font for projects that ship none (see
# assets/fonts/README.md). The engine parses it with stb_truetype and, when the
# file is unreadable or a glyph is missing, simply draws nothing for that
# character — quietly, at draw time, as blank window text rather than an error.
# A truncated download or a subsetted replacement would therefore ship
# unnoticed, so check the file up front: it must be a real sfnt, carry the
# outline and metric tables stb_truetype needs, and cover the scripts the
# makers' UI text is written in.
#
# Usage: ruby scripts/check_default_font.rb [assets/fonts]

dir = ARGV[0] || File.expand_path('../assets/fonts', __dir__)

fonts = Dir.glob(File.join(dir, '*.{ttf,otf,ttc,TTF,OTF,TTC}')).sort

# The font is downloaded, not committed (scripts/download-default-font.bash), so
# its absence is a normal state for a fresh checkout rather than a failure.
# Report it and pass; games that ship their own font are unaffected either way.
if fonts.empty?
  puts "default font: none in #{dir} — skipping " \
       '(run scripts/download-default-font.bash to install it)'
  exit 0
end

errors = []

# The SIL Open Font License the font is distributed under has to travel with it.
license = Dir.glob(File.join(dir, '{OFL,LICENSE}*')).first
errors << "#{dir}: no licence file next to the font" unless license

fonts.each do |path|
  data = File.binread(path)

  if data.bytesize < 12
    errors << "#{path}: too small to be a font (#{data.bytesize} bytes)"
    next
  end

  # sfnt wrappers stb_truetype accepts: TrueType outlines ("\0\1\0\0" or
  # "true"), CFF/OpenType ("OTTO") and a collection ("ttcf").
  tag = data[0, 4]
  unless ["\x00\x01\x00\x00".b, 'true'.b, 'OTTO'.b, 'ttcf'.b].include?(tag)
    errors << "#{path}: not an sfnt font (magic #{tag.unpack1('H*')})"
    next
  end
  # A collection's first font starts at the offset in its header; the table
  # directory below is read from there either way.
  base = tag == 'ttcf'.b ? data[12, 4].unpack1('N') : 0

  num_tables = data[base + 4, 2].unpack1('n')
  tables = {}
  num_tables.times do |i|
    rec = base + 12 + (16 * i)
    name = data[rec, 4]
    off, len = data[rec + 8, 8].unpack('NN')
    tables[name] = [off, len]
  end

  # cmap maps code points to glyphs, head/hhea/hmtx give the metrics
  # stbtt_GetFontVMetrics / GetCodepointHMetrics read for layout, and the
  # outlines live in glyf+loca (TrueType) or CFF (OpenType).
  required = %w[cmap head hhea hmtx maxp]
  missing = required.reject { |t| tables.key?(t) }
  outlines = tables.key?('glyf') || tables.key?('CFF ') || tables.key?('CFF2')
  missing << 'glyf/CFF' unless outlines
  errors << "#{path}: missing table(s): #{missing.join(', ')}" unless missing.empty?
  next unless missing.empty?

  truncated = tables.reject { |_, (off, len)| off + len <= data.bytesize }
  unless truncated.empty?
    errors << "#{path}: table(s) past end of file: #{truncated.keys.join(', ')}"
    next
  end

  glyphs = data[tables['maxp'][0] + 4, 2].unpack1('n')

  # Walk every cmap subtable and collect the code points covered, so a font
  # whose Unicode coverage sits in a format 12 (or format 4) subtable is read
  # either way.
  covered = lambda do |cp|
    cmap = tables['cmap'][0]
    data[cmap + 2, 2].unpack1('n').times do |i|
      sub = cmap + data[cmap + 4 + (8 * i) + 4, 4].unpack1('N')
      case data[sub, 2].unpack1('n')
      when 4
        seg = data[sub + 6, 2].unpack1('n') / 2
        ends = data[sub + 14, seg * 2].unpack('n*')
        starts = data[sub + 16 + (seg * 2), seg * 2].unpack('n*')
        return true if starts.zip(ends).any? { |s, e| s <= cp && cp <= e && s != 0xffff }
      when 12
        n = data[sub + 12, 4].unpack1('N')
        n.times do |g|
          s, e = data[sub + 16 + (12 * g), 8].unpack('NN')
          return true if s <= cp && cp <= e
        end
      end
    end
    false
  end

  # RPG Maker UI text is Japanese: Latin for the western projects, plus kana and
  # JIS level-1 kanji for everything else. A Latin-only (or web-subsetted) font
  # would draw blanks through most of a Japanese game's windows.
  {
    0x0041 => 'Latin capital A',
    0x0061 => 'Latin small a',
    0x0030 => 'digit zero',
    0x3042 => 'hiragana A',
    0x30A2 => 'katakana A',
    0x6F22 => 'kanji "kan"',
    0x3001 => 'ideographic comma',
    0xFF21 => 'fullwidth A',
  }.each do |cp, what|
    next if covered.call(cp)

    errors << format('%s: no glyph for U+%04X (%s)', path, cp, what)
  end

  puts format('default font: %s — %d glyphs, %d KiB, tables OK',
              File.basename(path), glyphs, data.bytesize / 1024)
end

if errors.empty?
  puts "default font: #{dir} OK"
  exit 0
end

errors.each { |e| warn "default font: #{e}" }
warn 'default font: re-run scripts/download-default-font.bash --force to reinstall'
exit 1

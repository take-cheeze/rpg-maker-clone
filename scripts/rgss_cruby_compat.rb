# encoding: UTF-8
#
# A CRuby stand-in for the *native* half of mruby-rgss: the RGSS API the C++
# engine implements in src/lib.cxx, src/audio.cxx, src/profiler.cxx and the
# other native files. Loading this file under plain CRuby, then the real
# mruby-rgss/mrblib sources on top, reproduces the engine's Ruby-visible
# surface with no mruby build — which is what lets the RGSS tests
# (scripts/rgss_cruby_test_check.rb, and anything else that wants the classes)
# run on the host and what lets scripts/coverage_report.rb measure the mrblib
# lines those tests reach.
#
# The rule, matching the native code it stands in for: *our own Ruby is always
# loaded for real; only native code is stood in for here.* So the value types
# and pixel ops below replicate the C arithmetic exactly (they are pinned by
# mruby-rgss/test/test.rb byte for byte), while the display classes are
# structural — the tests can only assert their method surface without a live
# display — and font rasterisation falls back to the compact 5x7 font below,
# the analogue of the engine's shinonome fallback.
#
# Deliberately not reproduced: anything that needs a window, an audio device or
# stb's full codec zoo. Graphics.update/snap_to_bitmap are no-ops, the audio
# primitives are graceful no-ops, and PNG/XYZ decode is implemented in pure
# Ruby (zlib + a port of the engine's tolerant inflater) so image-loading
# behaviour is still exercised.

require "zlib"

# The RGSS module, value types and display classes live under the same
# namespace the native gem uses; the mrblib sources reopen them.
module RGSS
  # --- Diagnostics shared with Bitmap (mirrors g_bitmap_load_error / stb) ---

  @bitmap_load_error = ""
  @bitmap_stbi_error = ""
  @bitmap_decoder_ran = false

  # --- Native module functions (src/lib.cxx's gem init) ---------------------

  class << self
    attr_accessor :bitmap_load_error, :bitmap_stbi_error, :bitmap_decoder_ran

    # The running game's title. nil (and the empty string) clears it; anything
    # else is stringified, as window_title_set_m does.
    def window_title
      @window_title
    end

    def window_title=(title)
      if title.nil?
        @window_title = nil
      else
        @window_title = title.to_s
        @window_title = nil if @window_title.empty?
      end
      title
    end

    # The bundled default UI font, or nil when none is installed (it is
    # downloaded, not committed — see assets/fonts/README.md). Mirrors
    # rgss::default_font_path by scanning the tree's font assets.
    def default_font_path
      dir = File.expand_path("../assets/fonts", __dir__)
      return nil unless File.directory?(dir)
      Dir.glob(File.join(dir, "*.{ttf,otf,ttc}")).sort.first
    end

    # NFD of `s`. The engine uses uni-algo's full Unicode normaliser; this
    # table covers the Latin ranges a path name is likely to carry (Latin-1
    # Supplement, Latin Extended-A, and the W/Y circumflex pair of Extended-B)
    # and passes everything else through unchanged. That is enough for the
    # loader fallbacks that call it: an unhandled character simply never
    # matches, which is the same miss the native build reports for a name in
    # neither form.
    def to_nfd(s)
      out = +""
      s.each_codepoint do |cp|
        seq = NFD_TABLE[cp]
        if seq
          seq.each { |c| out << c }
        else
          out << cp
        end
      end
      out
    end

    # zlib inflate with the engine's no-header fallback (stbi_zlib_decode
    # then stbi_zlib_decode_noheader).
    def zlib_inflate(bytes)
      begin
        return Zlib::Inflate.inflate(bytes)
      rescue Zlib::Error
        inf = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        begin
          return inf.inflate(bytes)
        ensure
          inf.close
        end
      end
    end

    # Pointer state; no mouse here, so the RGSS default of (0, 0) / unpressed.
    def mouse_x
      0
    end

    def mouse_y
      0
    end

    def mouse_pressed?
      false
    end

    # Every $stderr line the error report buffers is handed here; the engine
    # forwards it to ng-log stamped with the script location it was written at.
    # Under CRuby there is no ng-log hook, so the location is the only
    # observable half — and it is what RGSS::ErrorReport.last_location exposes.
    def __log_bridge_write(_line)
      frame = caller.find { |f| !f.include?("error_report.rb") }
      return nil if frame.nil?
      file, line = frame.split(":")
      "#{file}:#{line}"
    end
  end

  # The value-type Marshal payloads. Kept byte-compatible with the C dumpers
  # (pack_doubles/unpack_doubles, the table's put32/get32, rect's raw int32s).
  def self.pack_doubles(*vals)
    vals.pack("E*")
  end

  # Unpack up to `n` little-endian doubles, padding missing tail entries with
  # `fill` — the analogue of unpack_doubles' "keep 0 unless the payload has the
  # byte" behaviour, except the caller can say what the default for a missing
  # field is (Color alpha defaults to 255).
  def self.unpack_doubles(s, n, fill = 0.0)
    arr = s.unpack("E#{n}")
    arr + Array.new([0, n - arr.size].max, fill)
  end

  def self.clamp255(v)
    v < 0 ? 0.0 : (v > 255 ? 255.0 : v.to_f)
  end

  def self.clamp_signed255(v)
    v < -255 ? -255.0 : (v > 255 ? 255.0 : v.to_f)
  end

  # RGSSError is defined for real in mrblib/lib.rb; declared here too so the
  # compat file works on its own (the two definitions agree on the superclass,
  # so reopening is harmless).
  class RGSSError < StandardError; end

  # --- RGSS::Color ----------------------------------------------------------
  # Floating RGBA components in 0..255, as src/lib.cxx's Color.

  class Color
    def initialize(r = 0, g = 0, b = 0, a = 255)
      @red = RGSS.clamp255(r)
      @green = RGSS.clamp255(g)
      @blue = RGSS.clamp255(b)
      @alpha = RGSS.clamp255(a)
    end

    def set(*args)
      if args.size == 1
        other = args[0]
        @red = other.red
        @green = other.green
        @blue = other.blue
        @alpha = other.alpha
      else
        r, g, b, a = args
        a = 255 if a.nil?
        @red = RGSS.clamp255(r)
        @green = RGSS.clamp255(g)
        @blue = RGSS.clamp255(b)
        @alpha = RGSS.clamp255(a)
      end
      self
    end

    attr_reader :red, :green, :blue, :alpha

    def red=(v)
      @red = RGSS.clamp255(v)
    end

    def green=(v)
      @green = RGSS.clamp255(v)
    end

    def blue=(v)
      @blue = RGSS.clamp255(v)
    end

    def alpha=(v)
      @alpha = RGSS.clamp255(v)
    end

    def ==(o)
      o.is_a?(RGSS::Color) && @red == o.red && @green == o.green &&
        @blue == o.blue && @alpha == o.alpha
    end

    def to_s
      "(#{@red}, #{@green}, #{@blue}, #{@alpha})"
    end

    def _dump(_limit)
      RGSS.pack_doubles(@red, @green, @blue, @alpha)
    end

    def self._load(s)
      r, g, b, a = RGSS.unpack_doubles(s, 4, 255.0)
      new(r, g, b, a)
    end
  end

  # --- RGSS::Tone -----------------------------------------------------------
  # Red/green/blue in -255..255 and gray in 0..255.

  class Tone
    def initialize(r = 0, g = 0, b = 0, gray = 0)
      @red = RGSS.clamp_signed255(r)
      @green = RGSS.clamp_signed255(g)
      @blue = RGSS.clamp_signed255(b)
      @gray = RGSS.clamp255(gray)
    end

    def set(*args)
      if args.size == 1
        other = args[0]
        @red = other.red
        @green = other.green
        @blue = other.blue
        @gray = other.gray
      else
        r, g, b, gray = args
        gray = 0 if gray.nil?
        @red = RGSS.clamp_signed255(r)
        @green = RGSS.clamp_signed255(g)
        @blue = RGSS.clamp_signed255(b)
        @gray = RGSS.clamp255(gray)
      end
      self
    end

    attr_reader :red, :green, :blue, :gray

    def red=(v)
      @red = RGSS.clamp_signed255(v)
    end

    def green=(v)
      @green = RGSS.clamp_signed255(v)
    end

    def blue=(v)
      @blue = RGSS.clamp_signed255(v)
    end

    def gray=(v)
      @gray = RGSS.clamp255(v)
    end

    def ==(o)
      o.is_a?(RGSS::Tone) && @red == o.red && @green == o.green &&
        @blue == o.blue && @gray == o.gray
    end

    def to_s
      "(#{@red}, #{@green}, #{@blue}, #{@gray})"
    end

    def _dump(_limit)
      RGSS.pack_doubles(@red, @green, @blue, @gray)
    end

    def self._load(s)
      r, g, b, gray = RGSS.unpack_doubles(s, 4)
      gray = 0.0 if gray.nil?
      new(r, g, b, gray)
    end
  end

  # --- RGSS::Rect -----------------------------------------------------------

  class Rect
    def initialize(x = 0, y = 0, width = 0, height = 0)
      @x = x.to_i
      @y = y.to_i
      @width = width.to_i
      @height = height.to_i
    end

    def set(*args)
      if args.size == 1
        o = args[0]
        @x = o.x
        @y = o.y
        @width = o.width
        @height = o.height
      else
        x, y, w, h = args
        @x = x.to_i
        @y = y.to_i
        @width = w.to_i
        @height = h.to_i
      end
      self
    end

    def empty
      @x = @y = @width = @height = 0
      self
    end

    attr_accessor :x, :y, :width, :height

    def ==(o)
      o.is_a?(RGSS::Rect) && @x == o.x && @y == o.y &&
        @width == o.width && @height == o.height
    end

    def to_s
      "(#{@x}, #{@y}, #{@width}, #{@height})"
    end

    def _dump(_limit)
      [@x, @y, @width, @height].pack("l<4")
    end

    def self._load(s)
      x, y, w, h = s.unpack("l<4")
      new(x, y, w, h)
    end
  end

  # --- RGSS::Table ----------------------------------------------------------
  # 1..3-dimensional int16 grid, as src/lib.cxx's Table.

  class Table
    def initialize(*args)
      @dim = args.size
      args.concat(Array.new(3 - args.size, 1))
      @xsize = args[0].to_i
      @ysize = @dim >= 2 ? args[1].to_i : 1
      @zsize = @dim >= 3 ? args[2].to_i : 1
      @data = Array.new(@xsize * @ysize * @zsize, 0)
    end

    def initialize_copy(other)
      super
      @data = other.instance_variable_get(:@data).dup
      self
    end

    attr_reader :dim, :xsize, :ysize, :zsize

    def index(x, y, z)
      if x < 0 || x >= @xsize || y < 0 || y >= @ysize || z < 0 || z >= @zsize
        nil
      else
        x + y * @xsize + z * @xsize * @ysize
      end
    end

    # A read past the edge is nil. A write past the edge is dropped *before*
    # the value is converted — games lean on that (see the note on
    # table_set in src/lib.cxx).
    def [](x, y = 0, z = 0)
      i = index(x.to_i, y.to_i, z.to_i)
      i.nil? ? nil : @data[i]
    end

    def []=(x, *rest)
      case rest.size
      when 1 then y, z, v = 0, 0, rest[0]
      when 2 then y, z, v = rest[0], 0, rest[1]
      when 3 then y, z, v = rest
      else raise ArgumentError, "wrong number of arguments (given #{rest.size + 1}, expected 2..4)"
      end
      # Resolve to an int *only* when the value is going to be stored.
      i = index(x.to_i, y.to_i, z.to_i)
      return v if i.nil?
      @data[i] = Integer(v)
      v
    end

    def resize(*args)
      @dim = args.size
      args.concat(Array.new(3 - args.size, 1))
      nx = args[0].to_i
      ny = @dim >= 2 ? args[1].to_i : 1
      nz = @dim >= 3 ? args[2].to_i : 1
      nd = Array.new(nx * ny * nz, 0)
      0.upto([nz, @zsize].min - 1) do |z|
        0.upto([ny, @ysize].min - 1) do |y|
          0.upto([nx, @xsize].min - 1) do |x|
            nd[x + y * nx + z * nx * ny] =
              @data[x + y * @xsize + z * @xsize * @ysize]
          end
        end
      end
      @dim = args.size
      @xsize = nx
      @ysize = ny
      @zsize = nz
      @data = nd
      self
    end

    def _dump(_limit)
      out = [@dim, @xsize, @ysize, @zsize, @data.size].pack("l<5")
      out << @data.pack("s<*")
      out
    end

    def self._load(s)
      dim, xsize, ysize, zsize, count = s[0, 20].unpack("l<5")
      t = new(xsize, ysize, zsize)
      t.instance_variable_set(:@dim, dim)
      vals = s[20, count * 2].unpack("s<#{count}")
      t.instance_variable_set(:@data, vals)
      t
    end
  end

  # --- RGSS::Bitmap ---------------------------------------------------------
  #
  # Pixels live in a flat Array of bytes in LVGL's B, G, R, A order (the same
  # byte order src/lib.cxx stores), so the ported arithmetic below reads and
  # writes exactly what the C code would. All the blit maths is integer and
  # truncating, as in the C — Ruby's floor division would differ on negatives,
  # so blend paths use cdiv where a difference can arise.

  class Bitmap
    # The RGB channels of a pixel, read out of the BGR(A) byte buffer.
    def bmp_read(x, y)
      i = (y * @width + x) * 4
      [@data[i + 2], @data[i + 1], @data[i], @data[i + 3]]
    end

    # Write one pixel, converting channels with C's uint8 truncation/wrap.
    def bmp_put(x, y, r, g, b, a)
      return if x < 0 || y < 0 || x >= @width || y >= @height
      i = (y * @width + x) * 4
      @data[i] = b.to_i & 0xff
      @data[i + 1] = g.to_i & 0xff
      @data[i + 2] = r.to_i & 0xff
      @data[i + 3] = a.to_i & 0xff
    end

    # Integer division truncating toward zero, matching C.
    def cdiv(num, den)
      q = num / den
      q -= 1 if q < 0 && num % den != 0
      q
    end

    def clamp_channel(v)
      v < 0 ? 0 : (v > 255 ? 255 : v)
    end

    # Disposed bitmaps raise like real RGSS (bmp_require).
    def bmp_require!
      raise RGSS::RGSSError, "disposed Bitmap" if @disposed
    end

    # --- Class-level load diagnostics (src/lib.cxx's g_bitmap_* globals) ----

    class << self
      def _load_error
        RGSS.bitmap_load_error
      end

      def _stbi_error
        RGSS.bitmap_stbi_error
      end

      def _begin_load
        RGSS.bitmap_load_error = ""
        RGSS.bitmap_decoder_ran = false
        nil
      end

      def _decoder_ran?
        RGSS.bitmap_decoder_ran
      end
    end

    # --- Construction --------------------------------------------------------

    def _init_size(w, h)
      @width = w.to_i
      @height = h.to_i
      @data = Array.new(@width * @height * 4, 0)
      @disposed = false
      self
    end

    # Decode a file, retrying the NFD form like bmp_init_file.
    def _init_file(path, trans = false)
      return nil unless File.file?(path) && File.size(path).positive?
      data = File.binread(path)
      return self if bmp_decode_into(data, path, trans)
      nfd = RGSS.to_nfd(path)
      if nfd != path && File.file?(nfd) && File.size(nfd).positive?
        return self if bmp_decode_into(File.binread(nfd), nfd, trans)
      end
      nil
    end

    def _init_memory(bytes, trans = false)
      return nil if bytes.nil? || bytes.bytesize <= 0
      bmp_decode_into(bytes, "<archive entry>", trans) ? self : nil
    end

    # clone/dup: a real pixel copy, so RPG::Cache's hue variants do not
    # recolour the cached original (bmp_init_copy).
    def initialize_copy(other)
      super
      @data = other.instance_variable_get(:@data).dup
      @width = other.instance_variable_get(:@width)
      @height = other.instance_variable_get(:@height)
      font = instance_variable_get(:@font)
      instance_variable_set(:@font, font.dup) if font
      self
    end

    # --- Image decode --------------------------------------------------------

    PNG_SIG = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a".b.freeze

    def bmp_decode_into(data, label, trans)
      # A decoder got the bytes: from here a failure is a decoder's.
      RGSS.bitmap_decoder_ran = true
      # stb tries JPEG first for every image and its header check leaves "no
      # SOI" behind after any non-JPEG decode.
      RGSS.bitmap_stbi_error = "no SOI"
      decoded =
        if data[0, 8] == PNG_SIG
          decode_png(data, label, trans)
        elsif data[0, 4] == "XYZ1"
          decode_xyz(data, label, trans)
        end
      return adopt(decoded) if decoded
      # Nothing recognised the bytes (or a recognised decoder failed and set
      # its own _load_error). stb would report "unknown image type".
      RGSS.bitmap_stbi_error = "unknown image type" if RGSS.bitmap_load_error.empty?
      nil
    end

    def adopt(decoded)
      @width, @height, @data = decoded
      @disposed = false
      self
    end

    # PNG decode with the engine's fallback order: strict zlib first, then the
    # tolerant inflater for streams whose back-references reach before the
    # output (RPG Maker windowskins — "bad dist" in stb).
    def decode_png(data, label, trans)
      i = 8
      idat = +"".b
      plte = nil
      trns = nil
      w = h = depth = ct = interlace = nil
      while i + 8 <= data.bytesize
        len = data[i, 4].unpack1("N")
        break if i + 12 + len > data.bytesize
        typ = data[i + 4, 4]
        body = data[i + 8, len]
        case typ
        when "IHDR"
          w, h = body[0, 8].unpack("NN")
          depth = body.getbyte(8)
          ct = body.getbyte(9)
          interlace = body.getbyte(12)
        when "IDAT" then idat << body
        when "PLTE" then plte = body
        when "tRNS" then trns = body
        when "IEND" then break
        end
        i += 12 + len
      end
      return nil if w.nil? || h.nil? || w <= 0 || h <= 0 || interlace != 0
      unless depth == 8 || (ct == 3 && [1, 2, 4].include?(depth))
        return nil
      end
      channels = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }[ct]
      return nil if channels.nil?
      return nil if ct == 3 && (plte.nil? || plte.bytesize < 3)

      rowbytes = (w * channels * depth + 7) / 8
      bpp = (channels * depth + 7) / 8
      bpp = 1 if bpp < 1
      raw =
        begin
          Zlib::Inflate.inflate(idat)
        rescue Zlib::Error
          inflate_tolerant(idat)
        end
      need = (rowbytes + 1) * h
      if raw.nil? || raw.bytesize < need
        RGSS.bitmap_load_error =
          format("PNG %dx%d depth %d colortype %d '%s': tolerant inflate " \
                 "produced too little data", w, h, depth, ct, label)
        return nil
      end

      # Reverse the per-scanline filters in place.
      bytes = raw.bytes
      rows = []
      prev = Array.new(rowbytes, 0)
      0.upto(h - 1) do |r|
        srow = bytes[(rowbytes + 1) * r, rowbytes + 1]
        ft = srow[0]
        cur = Array.new(rowbytes, 0)
        0.upto(rowbytes - 1) do |x|
          a = x >= bpp ? cur[x - bpp] : 0
          b = prev[x]
          cc = x >= bpp ? prev[x - bpp] : 0
          v = srow[1 + x]
          case ft
          when 1 then v += a
          when 2 then v += b
          when 3 then v += (a + b) >> 1
          when 4 then v += paeth(a, b, cc)
          end
          cur[x] = v & 0xff
        end
        rows << cur
        prev = cur
      end

      out = Array.new(w * h * 4, 0)
      pal = plte.nil? ? [] : plte.bytes
      trns_b = trns.nil? ? [] : trns.bytes
      palcount = pal.size / 3
      0.upto(h - 1) do |y|
        row = rows[y]
        0.upto(w - 1) do |x|
          p = (y * w + x) * 4
          case ct
          when 3
            idx =
              if depth == 8
                row[x]
              else
                per = 8 / depth
                shift = (per - 1 - (x % per)) * depth
                (row[x / per] >> shift) & ((1 << depth) - 1)
              end
            idx = palcount - 1 if idx >= palcount
            idx = 0 if palcount.zero?
            a = 255
            a = 0 if trans && idx.zero?
            a = trns_b[idx] if idx < trns_b.size
            out[p] = pal[idx * 3 + 2]
            out[p + 1] = pal[idx * 3 + 1]
            out[p + 2] = pal[idx * 3]
            out[p + 3] = a
          when 2
            out[p] = row[x * 3 + 2]
            out[p + 1] = row[x * 3 + 1]
            out[p + 2] = row[x * 3]
            out[p + 3] = 255
          when 6
            out[p] = row[x * 4 + 2]
            out[p + 1] = row[x * 4 + 1]
            out[p + 2] = row[x * 4]
            out[p + 3] = row[x * 4 + 3]
          when 0
            g = row[x]
            out[p] = g
            out[p + 1] = g
            out[p + 2] = g
            out[p + 3] = 255
          else # ct == 4, grayscale + alpha
            g = row[x * 2]
            out[p] = g
            out[p + 1] = g
            out[p + 2] = g
            out[p + 3] = row[x * 2 + 1]
          end
        end
      end
      [w, h, out]
    end

    def paeth(a, b, c)
      p = a + b - c
      pa = (p - a).abs
      pb = (p - b).abs
      pc = (p - c).abs
      (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
    end

    # RPG Maker 2000/2003 XYZ: "XYZ1" + uint16 LE w/h + a zlib stream holding
    # a 768-byte RGB palette then one index per pixel.
    def decode_xyz(data, label, trans)
      w = data.getbyte(4) | (data.getbyte(5) << 8)
      h = data.getbyte(6) | (data.getbyte(7) << 8)
      if w <= 0 || h <= 0
        RGSS.bitmap_load_error = format("XYZ: invalid dimensions %dx%d in '%s'",
                                        w, h, label)
        return nil
      end
      stream = data[8..-1]
      expected = 768 + w * h
      raw = zlib_decode_any(stream)
      if raw.nil?
        RGSS.bitmap_load_error =
          format("XYZ %dx%d '%s': zlib inflate failed (%s); zlib header " \
                 "0x%02x%02x, %d compressed bytes, expected %d decompressed",
                 w, h, label, RGSS.bitmap_stbi_error,
                 stream.getbyte(0) || 0, stream.getbyte(1) || 0,
                 stream.bytesize, expected)
        return nil
      end
      if raw.bytesize < expected
        RGSS.bitmap_load_error =
          format("XYZ %dx%d '%s': short data, got %d bytes, expected %d " \
                 "(768 palette + %d pixels)", w, h, label, raw.bytesize,
                 expected, w * h)
        return nil
      end
      pal = raw.bytes
      out = Array.new(w * h * 4, 0)
      (w * h).times do |i|
        idx = pal[i + 768]
        out[i * 4] = pal[idx * 3 + 2]
        out[i * 4 + 1] = pal[idx * 3 + 1]
        out[i * 4 + 2] = pal[idx * 3]
        out[i * 4 + 3] = (trans && idx.zero?) ? 0 : 255
      end
      [w, h, out]
    end

    # Standard zlib, then headerless raw DEFLATE — the same two tries the
    # engine's stbi_zlib_decode_malloc path makes.
    def zlib_decode_any(stream)
      Zlib::Inflate.inflate(stream)
    rescue Zlib::Error
      inf = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      begin
        inf.inflate(stream)
      rescue Zlib::Error
        nil
      ensure
        inf.close
      end
    end

    # --- Tolerant DEFLATE (port of src/lib.cxx's png_tol::inflate_tolerant) --
    #
    # Some RPG Maker PNGs ship an IDAT whose back-references reach before the
    # start of the output; strict inflaters reject those with "bad dist", and
    # the producers rely on the missing pre-history reading as zeros.

    class BitReader
      attr_reader :pos, :end_pos, :fail

      def initialize(data, start)
        @data = data
        @pos = start
        @end_pos = data.bytesize
        @buf = 0
        @cnt = 0
        @fail = false
      end

      def bit
        if @cnt.zero?
          if @pos >= @end_pos
            @fail = true
            return 0
          end
          @buf = @data.getbyte(@pos)
          @pos += 1
          @cnt = 8
        end
        b = @buf & 1
        @buf >>= 1
        @cnt -= 1
        b
      end

      def bits(n)
        v = 0
        n.times { |i| v |= bit << i }
        v
      end

      def align
        @buf = 0
        @cnt = 0
      end

      def skip(n)
        @pos += n
      end

      def byte
        b = @data.getbyte(@pos)
        @pos += 1
        b
      end
    end

    class Huff
      def initialize
        @count = Array.new(16, 0)
        @symbol = []
      end

      def build(len)
        @count = Array.new(16, 0)
        len.each { |l| @count[l] += 1 }
        @count[0] = 0
        offs = Array.new(16, 0)
        (1...15).each { |l| offs[l + 1] = offs[l] + @count[l] }
        @symbol = Array.new(len.size, 0)
        len.each_with_index do |l, i|
          next if l.zero?
          @symbol[offs[l]] = i
          offs[l] += 1
        end
      end

      def decode(br)
        code = 0
        first = 0
        index = 0
        1.upto(15) do |len|
          code = (code << 1) | br.bit
          count = @count[len]
          if code - count < first
            return @symbol[index + (code - first)]
          end
          index += count
          first += count
          first <<= 1
        end
        -1
      end
    end

    LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
             35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258].freeze
    LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
            2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0].freeze
    DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
             257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193,
             12289, 16385, 24577].freeze
    DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
            6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13].freeze

    def inflate_tolerant(input)
      off = 0
      if input.bytesize >= 2
        b0 = input.getbyte(0)
        b1 = input.getbyte(1)
        off = 2 if (b0 & 0x0f) == 8 && (((b0 << 8) | b1) % 31).zero?
      end
      br = BitReader.new(input, off)
      out = []

      fixed_l = Huff.new
      lens = []
      lens.concat(Array.new(144, 8))
      lens.concat(Array.new(112, 9))
      lens.concat(Array.new(24, 7))
      lens.concat(Array.new(8, 8))
      fixed_l.build(lens)
      fixed_d = Huff.new
      fixed_d.build(Array.new(30, 5))

      loop do
        last = br.bit
        type = br.bits(2)
        return nil if br.fail
        if type.zero?
          br.align
          return nil if br.pos + 4 > br.end_pos
          len0 = br.byte | (br.byte << 8)
          br.skip(2) # NLEN
          len0.times do
            return nil if br.pos >= br.end_pos
            out << br.byte
          end
        elsif type == 1 || type == 2
          if type == 1
            lc = fixed_l
            dc = fixed_d
          else
            hlit = br.bits(5) + 257
            hdist = br.bits(5) + 1
            hclen = br.bits(4) + 4
            ord = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14,
                   1, 15]
            cl = Array.new(19, 0)
            hclen.times { |i| cl[ord[i]] = br.bits(3) }
            clh = Huff.new
            clh.build(cl)
            lens = []
            n = 0
            while n < hlit + hdist
              sym = clh.decode(br)
              return nil if sym < 0
              if sym < 16
                lens << sym
                n += 1
              elsif sym == 16
                return nil if n.zero?
                r = br.bits(2) + 3
                prev = lens[n - 1]
                while r.positive? && n < hlit + hdist
                  lens << prev
                  n += 1
                  r -= 1
                end
              elsif sym == 17
                r = br.bits(3) + 3
                while r.positive? && n < hlit + hdist
                  lens << 0
                  n += 1
                  r -= 1
                end
              else
                r = br.bits(7) + 11
                while r.positive? && n < hlit + hdist
                  lens << 0
                  n += 1
                  r -= 1
                end
              end
            end
            dyn_l = Huff.new
            dyn_l.build(lens[0, hlit])
            dyn_d = Huff.new
            dyn_d.build(lens[hlit, hdist])
            lc = dyn_l
            dc = dyn_d
          end
          loop do
            sym = lc.decode(br)
            return nil if sym < 0
            break if sym == 256
            if sym < 256
              out << sym
            else
              sym -= 257
              return nil if sym >= 29
              len0 = LBASE[sym] + br.bits(LEXT[sym])
              dsym = dc.decode(br)
              return nil if dsym < 0 || dsym >= 30
              dist = DBASE[dsym] + br.bits(DEXT[dsym])
              while len0.positive?
                v = out.size < dist ? 0 : out[out.size - dist]
                out << v
                len0 -= 1
              end
            end
            return nil if br.fail
          end
        else
          return nil
        end
        break if last == 1
      end
      out.pack("C*")
    end

    # --- Pixel operations (ported from src/lib.cxx) -------------------------

    def width
      @width
    end

    def height
      @height
    end

    def rect
      RGSS::Rect.new(0, 0, @width, @height)
    end

    def clear
      @data.fill(0)
      self
    end

    def fill_rect(*args)
      if args.size <= 2
        r, col = args
        x, y, w, h = r.x, r.y, r.width, r.height
      else
        x, y, w, h, col = args
      end
      y.upto(y + h - 1) do |j|
        x.upto(x + w - 1) do |i|
          bmp_put(i, j, col.red, col.green, col.blue, col.alpha)
        end
      end
      self
    end

    def gradient_fill_rect(*args)
      if args.size <= 4
        r, col1, col2, vertical = args
        x, y, w, h = r.x, r.y, r.width, r.height
      else
        x, y, w, h, col1, col2, vertical = args
      end
      vertical ||= false
      span = vertical ? h : w
      y.upto(y + h - 1) do |j|
        x.upto(x + w - 1) do |i|
          pos = vertical ? j - y : i - x
          t = span > 1 ? pos.to_f / (span - 1) : 0.0
          bmp_put(i, j,
                  col1.red + (col2.red - col1.red) * t,
                  col1.green + (col2.green - col1.green) * t,
                  col1.blue + (col2.blue - col1.blue) * t,
                  col1.alpha + (col2.alpha - col1.alpha) * t)
        end
      end
      self
    end

    def get_pixel(x, y)
      r = 0
      g = 0
      b = 0
      a = 0
      if x >= 0 && y >= 0 && x < @width && y < @height
        r, g, b, a = bmp_read(x, y)
      end
      RGSS::Color.new(r, g, b, a)
    end

    def set_pixel(x, y, col)
      bmp_put(x, y, col.red, col.green, col.blue, col.alpha)
      self
    end

    # Source-over composite in straight (non-premultiplied) alpha
    # (src/lib.cxx's blend_over).
    def blend_over(x, y, r, g, b, sa, dr, dg, db, da)
      dw = da * (255 - sa) / 255
      out_a = sa + dw
      return if out_a <= 0
      bmp_put(x, y, (r * sa + dr * dw) / out_a, (g * sa + dg * dw) / out_a,
              (b * sa + db * dw) / out_a, out_a)
    end

    def blt(x, y, src, srect, opacity = 255)
      bmp_require!
      src.bmp_require!
      opacity = 0 if opacity < 0
      opacity = 255 if opacity > 255
      srect.y.upto(srect.y + srect.height - 1) do |sy|
        srect.x.upto(srect.x + srect.width - 1) do |sx|
          next if sx < 0 || sy < 0 || sx >= src.width || sy >= src.height
          r, g, b, a = src.bmp_read(sx, sy)
          alpha = a * opacity / 255
          dx = x + (sx - srect.x)
          dy = y + (sy - srect.y)
          next if dx < 0 || dy < 0 || dx >= @width || dy >= @height
          next if alpha <= 0
          if alpha >= 255
            bmp_put(dx, dy, r, g, b, 255)
          else
            dr, dg, db, da = bmp_read(dx, dy)
            blend_over(dx, dy, r, g, b, alpha, dr, dg, db, da)
          end
        end
      end
      self
    end

    def copy_blt(x, y, src, srect)
      bmp_require!
      src.bmp_require!
      sx = srect.x
      sy = srect.y
      w = srect.width
      h = srect.height
      if sx < 0
        w += sx
        x -= sx
        sx = 0
      end
      if sy < 0
        h += sy
        y -= sy
        sy = 0
      end
      if x < 0
        w += x
        sx -= x
        x = 0
      end
      if y < 0
        h += y
        sy -= y
        y = 0
      end
      w = src.width - sx if sx + w > src.width
      h = src.height - sy if sy + h > src.height
      w = @width - x if x + w > @width
      h = @height - y if y + h > @height
      return self if w <= 0 || h <= 0
      0.upto(h - 1) do |row|
        src_y = sy + row
        dst_y = y + row
        row_src = src_y * src.width * 4 + sx * 4
        row_dst = dst_y * @width * 4 + x * 4
        @data[row_dst, w * 4] = src.instance_variable_get(:@data)[row_src, w * 4]
      end
      self
    end

    def tone_blt(src, tone)
      bmp_require!
      src.bmp_require!
      if src.width != @width || src.height != @height
        raise RGSS::RGSSError,
              format("tone_blt: size mismatch (self %dx%d, src %dx%d)",
                     @width, @height, src.width, src.height)
      end
      tr = tone.red.to_i
      tg = tone.green.to_i
      tb = tone.blue.to_i
      gray = tone.gray.to_i
      0.upto(src.height - 1) do |y|
        0.upto(src.width - 1) do |x|
          r, g, b, a = src.bmp_read(x, y)
          if gray.positive?
            lum = (r * 299 + g * 587 + b * 114) / 1000
            r += cdiv((lum - r) * gray, 255)
            g += cdiv((lum - g) * gray, 255)
            b += cdiv((lum - b) * gray, 255)
          end
          bmp_put(x, y, clamp_channel(r + tr), clamp_channel(g + tg),
                  clamp_channel(b + tb), a)
        end
      end
      self
    end

    def stretch_blt(drect, src, srect, opacity = 255)
      bmp_require!
      src.bmp_require!
      opacity = 0 if opacity < 0
      opacity = 255 if opacity > 255
      return self if drect.width <= 0 || drect.height <= 0 ||
                     srect.width <= 0 || srect.height <= 0
      0.upto(drect.height - 1) do |j|
        dy = drect.y + j
        next if dy < 0 || dy >= @height
        sy = srect.y + j * srect.height / drect.height
        0.upto(drect.width - 1) do |i|
          dx = drect.x + i
          next if dx < 0 || dx >= @width
          sx = srect.x + i * srect.width / drect.width
          next if sx < 0 || sy < 0 || sx >= src.width || sy >= src.height
          r, g, b, a = src.bmp_read(sx, sy)
          alpha = a * opacity / 255
          next if alpha <= 0
          if alpha >= 255
            bmp_put(dx, dy, r, g, b, 255)
          else
            dr, dg, db, da = bmp_read(dx, dy)
            blend_over(dx, dy, r, g, b, alpha, dr, dg, db, da)
          end
        end
      end
      self
    end

    def mosaic_blt(src, size)
      bmp_require!
      src.bmp_require!
      if src.width != @width || src.height != @height
        raise RGSS::RGSSError,
              format("mosaic_blt: size mismatch (self %dx%d, src %dx%d)",
                     @width, @height, src.width, src.height)
      end
      blk = size < 1 ? 1 : size.to_i
      off = blk / 2
      block_centre = lambda do |pos, len|
        v = ((pos + off) / blk) * blk - off
        v = 0 if v < 0
        v = len - 1 if v > len - 1
        v
      end
      0.upto(src.height - 1) do |y|
        sy = block_centre.call(y, src.height)
        0.upto(src.width - 1) do |x|
          sx = block_centre.call(x, src.width)
          r, g, b, a = src.bmp_read(sx, sy)
          bmp_put(x, y, r, g, b, a)
        end
      end
      self
    end

    def wave_blt(src, depth, phase)
      bmp_require!
      src.bmp_require!
      if src.width != @width || src.height != @height
        raise RGSS::RGSSError,
              format("wave_blt: size mismatch (self %dx%d, src %dx%d)",
                     @width, @height, src.width, src.height)
      end
      two_pi = 2.0 * Math::PI
      0.upto(src.height - 1) do |y|
        sy = y * two_pi / 32.0
        offset = (2.0 * depth * Math.sin(phase + sy)).to_i
        0.upto(src.width - 1) do |x|
          dx = x + offset
          next if dx < 0 || dx >= @width
          r, g, b, a = src.bmp_read(x, y)
          next if a <= 0
          if a >= 255
            bmp_put(dx, y, r, g, b, 255)
          else
            dr, dg, db, da = bmp_read(dx, y)
            blend_over(dx, y, r, g, b, a, dr, dg, db, da)
          end
        end
      end
      self
    end

    def blur
      bmp_require!
      return self if @width < 1 || @height < 1
      src = @data.dup
      0.upto(@height - 1) do |y|
        0.upto(@width - 1) do |x|
          rs = 0
          gs = 0
          bs = 0
          as = 0
          n = 0
          (-1..1).each do |dy|
            (-1..1).each do |dx|
              sx = x + dx
              sy = y + dy
              next if sx < 0 || sy < 0 || sx >= @width || sy >= @height
              i = (sy * @width + sx) * 4
              r = src[i + 2]
              g = src[i + 1]
              b = src[i]
              a = src[i + 3]
              rs += r * a / 255
              gs += g * a / 255
              bs += b * a / 255
              as += a
              n += 1
            end
          end
          next if n.zero?
          a = as / n
          r = a.positive? ? [255, rs * 255 / n / a].min : 0
          g = a.positive? ? [255, gs * 255 / n / a].min : 0
          b = a.positive? ? [255, bs * 255 / n / a].min : 0
          bmp_put(x, y, r, g, b, a)
        end
      end
      self
    end

    def radial_blur(angle, division)
      bmp_require!
      return self if division < 2 || angle.zero? || @width < 1 || @height < 1
      src = @data.dup
      cx = (@width - 1) / 2.0
      cy = (@height - 1) / 2.0
      span = angle * Math::PI / 180.0
      0.upto(@height - 1) do |y|
        0.upto(@width - 1) do |x|
          rs = 0
          gs = 0
          bs = 0
          as = 0
          n = 0
          0.upto(division - 1) do |k|
            t = k.to_f / (division - 1) - 0.5
            th = span * t
            s = Math.sin(th)
            c = Math.cos(th)
            dx = x - cx
            dy = y - cy
            sx = (cx + dx * c - dy * s).round
            sy = (cy + dx * s + dy * c).round
            next if sx < 0 || sy < 0 || sx >= @width || sy >= @height
            i = (sy * @width + sx) * 4
            r = src[i + 2]
            g = src[i + 1]
            b = src[i]
            a = src[i + 3]
            rs += r * a / 255
            gs += g * a / 255
            bs += b * a / 255
            as += a
            n += 1
          end
          next if n.zero?
          a = as / n
          r = a.positive? ? [255, rs * 255 / n / a].min : 0
          g = a.positive? ? [255, gs * 255 / n / a].min : 0
          b = a.positive? ? [255, bs * 255 / n / a].min : 0
          bmp_put(x, y, r, g, b, a)
        end
      end
      self
    end

    def hue_change(hue)
      bmp_require!
      hue = ((hue % 360) + 360) % 360
      return self if hue.zero?
      0.upto(@height - 1) do |y|
        0.upto(@width - 1) do |x|
          r, g, b, a = bmp_read(x, y)
          rf = r / 255.0
          gf = g / 255.0
          bf = b / 255.0
          mx = [rf, gf, bf].max
          mn = [rf, gf, bf].min
          delta = mx - mn
          h = 0.0
          if delta.positive?
            if mx == rf
              h = 60.0 * (((gf - bf) / delta) % 6.0)
            elsif mx == gf
              h = 60.0 * ((bf - rf) / delta + 2.0)
            else
              h = 60.0 * ((rf - gf) / delta + 4.0)
            end
            h += 360.0 if h < 0.0
          end
          s = mx.zero? ? 0.0 : delta / mx
          v = mx
          h = (h + hue) % 360.0
          c = v * s
          xx = c * (1.0 - ((h / 60.0 % 2.0) - 1.0).abs)
          m = v - c
          nr =
            if h < 60.0
              c
            elsif h < 120.0
              xx
            elsif h < 180.0
              0.0
            elsif h < 240.0
              0.0
            elsif h < 300.0
              xx
            else
              c
            end
          ng =
            if h < 60.0
              xx
            elsif h < 120.0
              c
            elsif h < 180.0
              c
            elsif h < 240.0
              xx
            elsif h < 300.0
              0.0
            else
              0.0
            end
          nb =
            if h < 60.0
              0.0
            elsif h < 120.0
              0.0
            elsif h < 180.0
              xx
            elsif h < 240.0
              c
            elsif h < 300.0
              c
            else
              xx
            end
          bmp_put(x, y, (nr + m) * 255.0, (ng + m) * 255.0, (nb + m) * 255.0,
                  a)
        end
      end
      self
    end

    # One frame of Graphics.transition's transition-graphic form: dissolve
    # `self`'s alpha in the shape of a greyscale `map` (bmp_transition_alpha).
    # Answers false when the dissolve cannot be carried.
    def _transition_alpha(map, prog, vague)
      bmp_require!
      map.bmp_require!
      if @width <= 0 || @height <= 0 || map.width <= 0 || map.height <= 0
        return false
      end
      0.upto(@height - 1) do |y|
        my = y * map.height / @height
        0.upto(@width - 1) do |x|
          mx = x * map.width / @width
          t = map.bmp_read(mx, my)[2] / 255.0
          keep =
            if vague <= 0.0
              t > prog ? 1.0 : 0.0
            else
              (t - prog) / vague
            end
          keep = 0.0 if keep < 0.0
          keep = 1.0 if keep > 1.0
          i = (y * @width + x) * 4
          @data[i + 3] = (keep * 255.0 + 0.5).to_i & 0xff
        end
      end
      true
    end

    # --- Text (stand-in for the shinonome / TrueType rasterisers) -----------

    # The embedded 5x7 ASCII font (the same classic bitmaps the compact font
    # engines share). Each glyph is seven 5-bit rows, bit 0 the leftmost
    # column. A char with no glyph draws nothing, like a font missing it.
    GLYPHS = {
      0x20 => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], # space
      0x21 => [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04], # !
      0x22 => [0x0a, 0x0a, 0x0a, 0x00, 0x00, 0x00, 0x00], # "
      0x23 => [0x0a, 0x0a, 0x1f, 0x0a, 0x1f, 0x0a, 0x0a], # #
      0x24 => [0x04, 0x0f, 0x14, 0x0e, 0x05, 0x1e, 0x04], # $
      0x25 => [0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03], # %
      0x26 => [0x0c, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0d], # &
      0x27 => [0x04, 0x04, 0x04, 0x00, 0x00, 0x00, 0x00], # '
      0x28 => [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02], # (
      0x29 => [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08], # )
      0x2a => [0x00, 0x04, 0x15, 0x0e, 0x15, 0x04, 0x00], # *
      0x2b => [0x00, 0x04, 0x04, 0x1f, 0x04, 0x04, 0x00], # +
      0x2c => [0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x08], # ,
      0x2d => [0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00], # -
      0x2e => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04], # .
      0x2f => [0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10], # /
      0x30 => [0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e], # 0
      0x31 => [0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e], # 1
      0x32 => [0x0e, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1f], # 2
      0x33 => [0x1f, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0e], # 3
      0x34 => [0x02, 0x06, 0x0a, 0x12, 0x1f, 0x02, 0x02], # 4
      0x35 => [0x1f, 0x10, 0x1e, 0x01, 0x01, 0x11, 0x0e], # 5
      0x36 => [0x06, 0x08, 0x10, 0x1e, 0x11, 0x11, 0x0e], # 6
      0x37 => [0x1f, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08], # 7
      0x38 => [0x0e, 0x11, 0x11, 0x0e, 0x11, 0x11, 0x0e], # 8
      0x39 => [0x0e, 0x11, 0x11, 0x0f, 0x01, 0x02, 0x0c], # 9
      0x3a => [0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00], # :
      0x3b => [0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x08], # ;
      0x3c => [0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02], # <
      0x3d => [0x00, 0x00, 0x1f, 0x00, 0x1f, 0x00, 0x00], # =
      0x3e => [0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08], # >
      0x3f => [0x0e, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04], # ?
      0x40 => [0x0e, 0x11, 0x15, 0x15, 0x15, 0x08, 0x06], # @
      0x41 => [0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11], # A
      0x42 => [0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e], # B
      0x43 => [0x0e, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0e], # C
      0x44 => [0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e], # D
      0x45 => [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f], # E
      0x46 => [0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x10], # F
      0x47 => [0x0e, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0f], # G
      0x48 => [0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11], # H
      0x49 => [0x0e, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e], # I
      0x4a => [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0c], # J
      0x4b => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11], # K
      0x4c => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1f], # L
      0x4d => [0x11, 0x1b, 0x15, 0x15, 0x11, 0x11, 0x11], # M
      0x4e => [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11], # N
      0x4f => [0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e], # O
      0x50 => [0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10, 0x10], # P
      0x51 => [0x0e, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0d], # Q
      0x52 => [0x1e, 0x11, 0x11, 0x1e, 0x14, 0x12, 0x11], # R
      0x53 => [0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e], # S
      0x54 => [0x1f, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04], # T
      0x55 => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e], # U
      0x56 => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04], # V
      0x57 => [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0a], # W
      0x58 => [0x11, 0x11, 0x0a, 0x04, 0x0a, 0x11, 0x11], # X
      0x59 => [0x11, 0x11, 0x0a, 0x04, 0x04, 0x04, 0x04], # Y
      0x5a => [0x1f, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1f], # Z
      0x5b => [0x0e, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0e], # [
      0x5c => [0x10, 0x08, 0x08, 0x04, 0x02, 0x02, 0x01], # backslash
      0x5d => [0x0e, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0e], # ]
      0x5e => [0x04, 0x0a, 0x11, 0x00, 0x00, 0x00, 0x00], # ^
      0x5f => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1f], # _
      0x60 => [0x08, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00], # `
      0x61 => [0x00, 0x00, 0x0e, 0x01, 0x0f, 0x11, 0x0f], # a
      0x62 => [0x10, 0x10, 0x1e, 0x11, 0x11, 0x11, 0x1e], # b
      0x63 => [0x00, 0x00, 0x0e, 0x10, 0x10, 0x10, 0x0e], # c
      0x64 => [0x01, 0x01, 0x0f, 0x11, 0x11, 0x11, 0x0f], # d
      0x65 => [0x00, 0x00, 0x0e, 0x11, 0x1f, 0x10, 0x0e], # e
      0x66 => [0x06, 0x09, 0x08, 0x1e, 0x08, 0x08, 0x08], # f
      0x67 => [0x00, 0x0f, 0x11, 0x11, 0x0f, 0x01, 0x0e], # g
      0x68 => [0x10, 0x10, 0x1e, 0x11, 0x11, 0x11, 0x11], # h
      0x69 => [0x04, 0x00, 0x0c, 0x04, 0x04, 0x04, 0x0e], # i
      0x6a => [0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0c], # j
      0x6b => [0x10, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11], # k
      0x6c => [0x0c, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0e], # l
      0x6d => [0x00, 0x00, 0x1a, 0x15, 0x15, 0x15, 0x15], # m
      0x6e => [0x00, 0x00, 0x1e, 0x11, 0x11, 0x11, 0x11], # n
      0x6f => [0x00, 0x00, 0x0e, 0x11, 0x11, 0x11, 0x0e], # o
      0x70 => [0x00, 0x1e, 0x11, 0x11, 0x1e, 0x10, 0x10], # p
      0x71 => [0x00, 0x0f, 0x11, 0x11, 0x0f, 0x01, 0x01], # q
      0x72 => [0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10], # r
      0x73 => [0x00, 0x00, 0x0f, 0x10, 0x0e, 0x01, 0x1e], # s
      0x74 => [0x08, 0x08, 0x1e, 0x08, 0x08, 0x09, 0x06], # t
      0x75 => [0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0d], # u
      0x76 => [0x00, 0x00, 0x11, 0x11, 0x11, 0x0a, 0x04], # v
      0x77 => [0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0a], # w
      0x78 => [0x00, 0x00, 0x11, 0x0a, 0x04, 0x0a, 0x11], # x
      0x79 => [0x00, 0x11, 0x11, 0x11, 0x0f, 0x01, 0x0e], # y
      0x7a => [0x00, 0x00, 0x1f, 0x02, 0x04, 0x08, 0x1f], # z
      0x7b => [0x06, 0x08, 0x08, 0x10, 0x08, 0x08, 0x06], # {
      0x7c => [0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04], # |
      0x7d => [0x0c, 0x02, 0x02, 0x01, 0x02, 0x02, 0x0c], # }
      0x7e => [0x08, 0x15, 0x02, 0x00, 0x00, 0x00, 0x00]  # ~
    }.freeze

    # The rasteriser scales with Font#size only when a real font file is
    # configured (Font.default_path) — without one the embedded 5x7 font is
    # fixed-size, exactly like the engine's shinonome fallback.
    def glyph_scale
      RGSS::Font.default_path ? [1, (font.size / 7.0).round].max : 1
    end

    def draw_text(*args)
      bmp_require!
      if args.size <= 3
        rect, str, align = args
        x, y, w, h = rect.x, rect.y, rect.width, rect.height
      else
        x, y, w, h, str, align = args
      end
      align ||= 0
      s = str.to_s
      scale = glyph_scale
      adv = 6 * scale
      tw = 0
      s.each_codepoint { tw += adv }
      x += (w - tw) / 2 if align == 1
      x += w - tw if align == 2
      col = font.color
      s.each_codepoint do |cp|
        glyph = GLYPHS[cp]
        unless glyph.nil?
          glyph.each_with_index do |row, r|
            5.times do |c|
              next if ((row >> c) & 1).zero?
              0.upto(scale - 1) do |dy|
                0.upto(scale - 1) do |dx|
                  bmp_put(x + c * scale + dx, y + r * scale + dy,
                          col.red, col.green, col.blue, col.alpha)
                end
              end
            end
          end
        end
        x += adv
      end
      self
    end

    def text_size(text)
      s = text.to_s
      if RGSS::Font.default_path
        scale = glyph_scale
        w = s.length * 6 * scale
        h = 7 * scale
      else
        w = s.length * 6
        h = 22
      end
      RGSS::Rect.new(0, 0, w, h)
    end

    def dispose
      @disposed = true
      nil
    end

    def disposed?
      @disposed
    end
  end

  # --- Display objects ------------------------------------------------------
  #
  # Structural: the tests can assert only the method surface without a live
  # display, so these record what a game assigns and answer RGSS's defaults,
  # exactly as the native setters' @ivars do for the mrblib readers.

  class Viewport
    def initialize(x = nil, y = nil, width = nil, height = nil)
      if x.is_a?(RGSS::Rect)
        r = x
        @rect = RGSS::Rect.new(r.x, r.y, r.width, r.height)
      elsif width.nil?
        @rect = RGSS::Rect.new(0, 0, 640, 480)
      else
        @rect = RGSS::Rect.new(x, y, width, height)
      end
      @ox = 0
      @oy = 0
      @visible = true
      @disposed = false
    end

    attr_reader :ox, :oy

    def rect
      @rect
    end

    def rect=(r)
      @rect = RGSS::Rect.new(r.x, r.y, r.width, r.height)
      r
    end

    def ox=(v)
      @ox = v
    end

    def oy=(v)
      @oy = v
    end

    def z=(v)
      @z = v
    end

    attr_reader :visible

    def visible=(v)
      @visible = v
    end

    def color
      @color ||= RGSS::Color.new(0, 0, 0, 0)
    end

    def color=(c)
      @color = c
      c
    end

    def tone
      @tone ||= RGSS::Tone.new(0, 0, 0, 0)
    end

    def tone=(t)
      @tone = t
      t
    end

    def flash(color, duration)
      @flash_color = color
      @flash_duration = duration
      @flash_count = color.nil? ? 0 : duration
      nil
    end

    def update
      @flash_count -= 1 if @flash_count && @flash_count.positive?
      nil
    end

    def dispose
      @disposed = true
      nil
    end

    def disposed?
      @disposed
    end
  end

  class Sprite
    def initialize(viewport = nil)
      @viewport = viewport
      @disposed = false
    end

    attr_reader :viewport

    def bitmap=(b)
      @bitmap = b
      b
    end

    def x=(v)
      @x = v
    end

    def y=(v)
      @y = v
    end

    def z=(v)
      @z = v
    end

    attr_reader :visible

    def visible=(v)
      @visible = v
    end

    def opacity=(v)
      raise TypeError, "opacity= got #{v.class}" unless v.is_a?(Integer)
      @opacity = v < 0 ? 0 : (v > 255 ? 255 : v)
    end

    def zoom_x=(v)
      @zoom_x = v < 0 ? 0.0 : v
    end

    def zoom_y=(v)
      @zoom_y = v < 0 ? 0.0 : v
    end

    def angle=(v)
      @angle = v
    end

    def mirror=(v)
      @mirror = v
    end

    def tone=(v)
      @tone = v
      v
    end

    def color=(v)
      @color = v
      v
    end

    def src_rect=(v)
      @src_rect = v
      v
    end

    def blend_type=(v)
      @blend_type = v
    end

    def bush_depth=(v)
      @bush_depth = v
    end

    def flash(color, duration)
      @flash_color = color
      @flash_duration = duration
      @flash_count = duration
      nil
    end

    def update
      @flash_count -= 1 if @flash_count && @flash_count.positive?
      nil
    end

    def dispose
      @disposed = true
      nil
    end

    def disposed?
      @disposed
    end
  end

  class Plane
    def initialize(viewport = nil)
      @viewport = viewport
      @disposed = false
    end

    attr_reader :viewport

    def bitmap=(b)
      @bitmap = b
      b
    end

    def ox=(v)
      @ox = v
    end

    def oy=(v)
      @oy = v
    end

    def opacity=(v)
      @opacity = v < 0 ? 0 : (v > 255 ? 255 : v)
    end

    def tone=(v)
      @tone = v
      v
    end

    def color=(v)
      @color = v
      v
    end

    def zoom_x=(v)
      @zoom_x = v < 0 ? 0.0 : v
    end

    def zoom_y=(v)
      @zoom_y = v < 0 ? 0.0 : v
    end

    def blend_type=(v)
      @blend_type = v
    end

    def z=(v)
      @z = v
    end

    attr_reader :visible

    def visible=(v)
      @visible = v
    end

    def dispose
      @disposed = true
      nil
    end

    def disposed?
      @disposed
    end
  end

  # VX / VX Ace tile geometry, ported from src/lib.cxx's vx_tile_quads (which
  # itself mirrors the MV corescript's Tilemap.js). Pinned byte-for-byte by the
  # mruby tests, so the tables below have to match exactly.
  TILE_SIZE = 32
  VX_TILE_ID_A5 = 1536
  VX_TILE_ID_A1 = 2048
  VX_TILE_ID_A2 = 2816
  VX_TILE_ID_A3 = 4352
  VX_TILE_ID_A4 = 5888
  VX_TILE_ID_MAX = 8192

  VX_FLOOR_QUADS = [
    [[2, 4], [1, 4], [2, 3], [1, 3]], [[2, 0], [1, 4], [2, 3], [1, 3]],
    [[2, 4], [3, 0], [2, 3], [1, 3]], [[2, 0], [3, 0], [2, 3], [1, 3]],
    [[2, 4], [1, 4], [2, 3], [3, 1]], [[2, 0], [1, 4], [2, 3], [3, 1]],
    [[2, 4], [3, 0], [2, 3], [3, 1]], [[2, 0], [3, 0], [2, 3], [3, 1]],
    [[2, 4], [1, 4], [2, 1], [1, 3]], [[2, 0], [1, 4], [2, 1], [1, 3]],
    [[2, 4], [3, 0], [2, 1], [1, 3]], [[2, 0], [3, 0], [2, 1], [1, 3]],
    [[2, 4], [1, 4], [2, 1], [3, 1]], [[2, 0], [1, 4], [2, 1], [3, 1]],
    [[2, 4], [3, 0], [2, 1], [3, 1]], [[2, 0], [3, 0], [2, 1], [3, 1]],
    [[0, 4], [1, 4], [0, 3], [1, 3]], [[0, 4], [3, 0], [0, 3], [1, 3]],
    [[0, 4], [1, 4], [0, 3], [3, 1]], [[0, 4], [3, 0], [0, 3], [3, 1]],
    [[2, 2], [1, 2], [2, 3], [1, 3]], [[2, 2], [1, 2], [2, 3], [3, 1]],
    [[2, 2], [1, 2], [2, 1], [1, 3]], [[2, 2], [1, 2], [2, 1], [3, 1]],
    [[2, 4], [3, 4], [2, 3], [3, 3]], [[2, 4], [3, 4], [2, 1], [3, 3]],
    [[2, 0], [3, 4], [2, 3], [3, 3]], [[2, 0], [3, 4], [2, 1], [3, 3]],
    [[2, 4], [1, 4], [2, 5], [1, 5]], [[2, 0], [1, 4], [2, 5], [1, 5]],
    [[2, 4], [3, 0], [2, 5], [1, 5]], [[2, 0], [3, 0], [2, 5], [1, 5]],
    [[0, 4], [3, 4], [0, 3], [3, 3]], [[2, 2], [1, 2], [2, 5], [1, 5]],
    [[0, 2], [1, 2], [0, 3], [1, 3]], [[0, 2], [1, 2], [0, 3], [3, 1]],
    [[2, 2], [3, 2], [2, 3], [3, 3]], [[2, 2], [3, 2], [2, 1], [3, 3]],
    [[2, 4], [3, 4], [2, 5], [3, 5]], [[2, 0], [3, 4], [2, 5], [3, 5]],
    [[0, 4], [1, 4], [0, 5], [1, 5]], [[0, 4], [3, 0], [0, 5], [1, 5]],
    [[0, 2], [3, 2], [0, 3], [3, 3]], [[0, 2], [1, 2], [0, 5], [1, 5]],
    [[0, 4], [3, 4], [0, 5], [3, 5]], [[2, 2], [3, 2], [2, 5], [3, 5]],
    [[0, 2], [3, 2], [0, 5], [3, 5]], [[0, 0], [1, 0], [0, 1], [1, 1]]
  ].freeze

  VX_WALL_QUADS = [
    [[2, 2], [1, 2], [2, 1], [1, 1]], [[0, 2], [1, 2], [0, 1], [1, 1]],
    [[2, 0], [1, 0], [2, 1], [1, 1]], [[0, 0], [1, 0], [0, 1], [1, 1]],
    [[2, 2], [3, 2], [2, 1], [3, 1]], [[0, 2], [3, 2], [0, 1], [3, 1]],
    [[2, 0], [3, 0], [2, 1], [3, 1]], [[0, 0], [3, 0], [0, 1], [3, 1]],
    [[2, 2], [1, 2], [2, 3], [1, 3]], [[0, 2], [1, 2], [0, 3], [1, 3]],
    [[2, 0], [1, 0], [2, 3], [1, 3]], [[0, 0], [1, 0], [0, 3], [1, 3]],
    [[2, 2], [3, 2], [2, 3], [3, 3]], [[0, 2], [3, 2], [0, 3], [3, 3]],
    [[2, 0], [3, 0], [2, 3], [3, 3]], [[0, 0], [3, 0], [0, 3], [3, 3]]
  ].freeze

  VX_WATERFALL_QUADS = [
    [[2, 0], [1, 0], [2, 1], [1, 1]],
    [[0, 0], [1, 0], [0, 1], [1, 1]],
    [[2, 0], [3, 0], [2, 1], [3, 1]],
    [[0, 0], [3, 0], [0, 1], [3, 1]]
  ].freeze

  class Tilemap
    def initialize(viewport = nil)
      @viewport = viewport
      @disposed = false
    end

    attr_reader :viewport

    def tileset=(v)
      @tileset = v
      v
    end

    def map_data=(v)
      @map_data = v
      v
    end

    def priorities=(v)
      @priorities = v
      v
    end

    def bitmaps
      @bitmaps ||= Array.new(9)
    end

    def flags=(v)
      @flags = v
      v
    end

    def ox=(v)
      @ox = v
    end

    def oy=(v)
      @oy = v
    end

    def update
      nil
    end

    def z=(v)
      @z = v
    end

    attr_reader :visible

    def visible=(v)
      @visible = v
    end

    def dispose
      @disposed = true
      nil
    end

    def disposed?
      @disposed
    end

    def self.vx_tile_quads(tile_id, frame = 0, table = false)
      out = []
      return out if tile_id <= 0 || tile_id >= VX_TILE_ID_MAX
      half = TILE_SIZE / 2

      if tile_id < VX_TILE_ID_A1
        sheet = tile_id >= VX_TILE_ID_A5 ? 4 : 5 + tile_id / 256
        return out if sheet > 8
        sx = (tile_id / 128 % 2 * 8 + tile_id % 8) * TILE_SIZE
        sy = (tile_id % 256 / 8 % 16) * TILE_SIZE
        return [[sheet, sx, sy, 0, 0, TILE_SIZE, TILE_SIZE]]
      end

      kind = (tile_id - VX_TILE_ID_A1) / 48
      shape = (tile_id - VX_TILE_ID_A1) % 48
      tx = kind % 8
      ty = kind / 8
      sheet = 0
      bx = 0
      by = 0
      quad_table = VX_FLOOR_QUADS
      shape_count = 48
      is_table = false

      if tile_id < VX_TILE_ID_A2
        surface = [0, 1, 2, 1][((frame % 4) + 4) % 4]
        sheet = 0
        if kind.zero?
          bx = surface * 2
          by = 0
        elsif kind == 1
          bx = surface * 2
          by = 3
        elsif kind == 2
          bx = 6
          by = 0
        elsif kind == 3
          bx = 6
          by = 3
        else
          bx = tx / 4 * 8
          by = ty * 6 + tx / 2 % 2 * 3
          if kind.even?
            bx += surface * 2
          else
            bx += 6
            quad_table = VX_WATERFALL_QUADS
            shape_count = 4
            by += ((frame % 3) + 3) % 3
          end
        end
      elsif tile_id < VX_TILE_ID_A3
        sheet = 1
        bx = tx * 2
        by = (ty - 2) * 3
        is_table = table
      elsif tile_id < VX_TILE_ID_A4
        sheet = 2
        bx = tx * 2
        by = (ty - 6) * 2
        quad_table = VX_WALL_QUADS
        shape_count = 16
      else
        sheet = 3
        bx = tx * 2
        by = ((ty - 10) * 5 + (ty.even? ? 0 : 1)) / 2
        if ty.odd?
          quad_table = VX_WALL_QUADS
          shape_count = 16
        end
      end

      return out if shape >= shape_count

      table_x = [0, 3, 2, 1]
      4.times do |i|
        qsx = quad_table[shape][i][0]
        qsy = quad_table[shape][i][1]
        sx = (bx * 2 + qsx) * half
        sy = (by * 2 + qsy) * half
        dx = (i % 2) * half
        dy = (i / 2) * half
        if is_table && (qsy == 1 || qsy == 5)
          qsx2 = qsy == 1 ? table_x[qsx % 4] : qsx
          out << [sheet, (bx * 2 + qsx2) * half, (by * 2 + 3) * half,
                  dx, dy, half, half]
          out << [sheet, sx, sy, dx, dy + half / 2, half, half / 2]
        else
          out << [sheet, sx, sy, dx, dy, half, half]
        end
      end
      out
    end

    # Ported from src/lib.cxx's vx_table_leg_quads: the A2 table tile's "leg",
    # which spills 8px past the tile's own box into the map row below. See
    # that function's comment for the derivation.
    def self.vx_table_leg_quads(tile_id)
      out = []
      return out if tile_id < VX_TILE_ID_A2 || tile_id >= VX_TILE_ID_A3
      half = TILE_SIZE / 2
      kind = (tile_id - VX_TILE_ID_A1) / 48
      shape = (tile_id - VX_TILE_ID_A1) % 48
      return out if shape >= 48
      tx = kind % 8
      ty = kind / 8
      bx = tx * 2
      by = (ty - 2) * 3
      [[0, 2], [1, 3]].each do |c, corner|
        qsx = VX_FLOOR_QUADS[shape][corner][0]
        qsy = VX_FLOOR_QUADS[shape][corner][1]
        next unless [1, 5].include?(qsy)
        sx = (bx * 2 + qsx) * half
        sy = (by * 2 + qsy) * half
        dx = c.zero? ? 0 : half
        out << [1, sx, sy, dx, TILE_SIZE - half / 2, half, half]
      end
      out
    end
  end

  class Window
    def initialize(viewport = nil)
      @viewport = viewport
      @contents = nil
      @width = 0
      @height = 0
      @ox = 0
      @oy = 0
      @contents_opacity = 255
      @disposed = false
    end

    attr_reader :viewport

    def contents=(b)
      @contents = b
      b
    end

    def x=(v)
      @x = v
    end

    def y=(v)
      @y = v
    end

    def width=(v)
      @width = v
    end

    def height=(v)
      @height = v
    end

    def ox=(v)
      @ox = v
    end

    def oy=(v)
      @oy = v
    end

    def contents_opacity=(v)
      @contents_opacity = v
    end

    def windowskin=(v)
      @windowskin = v
      v
    end

    def opacity=(v)
      @opacity = v
    end

    def back_opacity=(v)
      @back_opacity = v
    end

    def cursor_rect=(v)
      @cursor_rect = v
      v
    end

    def active=(v)
      @active = v
    end

    def pause=(v)
      @pause = v
    end

    def stretch=(v)
      @stretch = v
    end

    def update
      nil
    end

    def openness=(v)
      @openness = v
    end

    def tone
      @tone ||= RGSS::Tone.new(0, 0, 0, 0)
    end

    def tone=(v)
      @tone = v
      v
    end

    def z=(v)
      @z = v
    end

    attr_reader :visible

    def visible=(v)
      @visible = v
    end

    def dispose
      @disposed = true
      nil
    end

    def disposed?
      @disposed
    end
  end

  # --- Graphics (native hooks; the RGSS2 additions live in mrblib/lib.rb) ---

  module Graphics
    class << self
      def update
        nil
      end

      def snap_to_bitmap
        nil
      end

      def frame_reset
        RGSS::Graphics
      end
    end
  end

  # --- Audio (native primitives; the resolver lives in mrblib/lib.rb) -------

  module Audio
    class << self
      def _bgm_play(*); nil; end
      def _bgm_volume(*); nil; end
      def _bgm_pan(*); nil; end
      def _bgm_stop; nil; end
      def _bgm_fade(*); nil; end
      def _bgm_pos; 0; end
      def _bgs_play(*); nil; end
      def _bgs_stop; nil; end
      def _bgs_fade(*); nil; end
      def _bgs_pos; 0; end
      def _me_play(*); nil; end
      def _me_stop; nil; end
      def _me_fade(*); nil; end
      def _se_play(*); nil; end
      def _se_stop; nil; end
      def _update; nil; end
      def _bgm_play_mem(*); nil; end
      def _bgs_play_mem(*); nil; end
      def _me_play_mem(*); nil; end
      def _se_play_mem(*); nil; end
      def _midi_available; false; end
      def _can_play_mem?; false; end
    end
  end

  # --- Input (native hooks; the key state machine lives in mrblib/lib.rb) ---
  #
  # `_push` feeds the same transition buffer the SDL backend does, and `_poll`
  # drains it — Input.update expires the previous frame's triggers *then*
  # calls `_poll`, so a tap buffered between frames is visible to the game's
  # own Input.update, exactly as under the real engine.

  module Input
    @buffer = []

    class << self
      def _push(key, press)
        @buffer << [key, press]
        nil
      end

      def _poll
        buf = @buffer
        @buffer = []
        buf.each do |key, press|
          if press
            press(key)
          else
            release(key)
          end
        end
        nil
      end
    end
  end

  # --- Profiler (native, src/profiler.cxx) ---------------------------------

  module Profiler
    @enabled = false
    @trace_path = nil
    @trace_first = true
    @trace_base_ns = 0
    @frames = 0
    @work_ns_sum = 0.0
    @work_ns_max = 0.0
    @period_ns_sum = 0.0
    @drops = 0
    @sections = {}
    @interval_open = false

    class << self
      def now_ns
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      end

      def enabled?
        @enabled
      end

      def enabled=(v)
        @enabled = v
      end

      def section(name)
        return nil unless block_given?
        return yield unless @enabled
        start = now_ns
        ret = yield
        record_section(name, start)
        ret
      end

      def frame
        return nil unless block_given?
        return yield unless @enabled
        reset_interval(now_ns) unless @interval_open
        start = now_ns
        ret = yield
        finish_frame(start)
        ret
      end

      def stats
        return nil unless @enabled
        avg_period_ms = @frames.positive? ? @period_ns_sum / @frames / 1e6 : 0.0
        fps = avg_period_ms.positive? ? 1000.0 / avg_period_ms : 0.0
        avg_ms = @frames.positive? ? @work_ns_sum / @frames / 1e6 : 0.0
        sections = {}
        @sections.each do |name, agg|
          calls, ns_sum, ns_max = agg
          sections[name] = {
            calls: calls,
            avg_ms: calls.positive? ? ns_sum / calls / 1e6 : 0.0,
            max_ms: ns_max / 1e6
          }
        end
        {
          frames: @frames,
          fps: fps,
          frame_avg_ms: avg_ms,
          frame_max_ms: @work_ns_max / 1e6,
          frame_drops: @drops,
          rss_bytes: 0,
          live_blocks: 0,
          lv_used_bytes: 0,
          sections: sections
        }
      end

      def report
        return nil unless @enabled && @interval_open
        secs = @sections.map { |name, agg| [name, agg] }
                         .sort_by { |(_n, a)| -a[1] }
        line = "[profiler] frames=#{@frames} fps=#{@frames.positive? ? 1000.0 / (@period_ns_sum / @frames / 1e6) : 0.0}"
        secs.first(8).each do |name, agg|
          calls, ns_sum, = agg
          line << " #{name} avg=#{ns_sum / calls / 1e6}ms n=#{calls}"
        end
        $stderr.puts line
        reset_interval(now_ns)
        nil
      end

      def reset
        reset_interval(now_ns) if @enabled
        nil
      end

      def trace_start(path)
        return false if @trace_path
        @trace_file = File.open(path, "w")
        if @trace_file.nil?
          $stderr.puts "[profiler] could not open trace file: #{path}"
          return false
        end
        @enabled = true
        @trace_first = true
        @trace_base_ns = now_ns
        @trace_file.write("[")
        trace_raw('{"ph":"M","pid":1,"name":"process_name","args":{"name":"rpg_maker_clone"}}')
        trace_raw('{"ph":"M","pid":1,"tid":1,"name":"thread_name","args":{"name":"main loop"}}')
        @trace_file.flush
        true
      end

      def trace_stop
        return nil unless @trace_file
        @trace_file.write("\n]\n")
        @trace_file.close
        @trace_file = nil
        nil
      end

      def tracing?
        !@trace_file.nil?
      end

      private

      def reset_interval(_now)
        @frames = 0
        @work_ns_sum = 0.0
        @work_ns_max = 0.0
        @period_ns_sum = 0.0
        @drops = 0
        @sections = {}
        @interval_open = true
      end

      def finish_frame(start)
        now = now_ns
        period = now - start
        @frames += 1
        @work_ns_sum += period
        @work_ns_max = [@work_ns_max, period].max
        @period_ns_sum += period
        if @trace_file
          trace_complete("frame", start, now, '{"work_ms":%.3f}' % (period / 1e6))
        end
      end

      def record_section(name, start)
        end_ns = now_ns
        dur = end_ns - start
        agg = @sections[name] ||= [0, 0.0, 0.0]
        agg[0] += 1
        agg[1] += dur
        agg[2] = [agg[2], dur].max
        trace_complete(name, start, end_ns, "") if @trace_file
      end

      def trace_raw(event)
        @trace_file.write(",") unless @trace_first
        @trace_file.write("\n")
        @trace_file.write(event)
        @trace_first = false
      end

      def trace_complete(name, start, finish, args)
        trace_raw(
          format('{"ph":"X","pid":1,"tid":1,"name":"%s","ts":%.3f,"dur":%.3f,"args":{%s}}',
                 name.to_s.gsub('"', '\\"'),
                 (start - @trace_base_ns) / 1000.0,
                 (finish - start) / 1000.0,
                 args.sub(/\A\{/, "").sub(/\}\z/, "")))
      end
    end
  end

  # --- NFD table ------------------------------------------------------------
  #
  # Canonical decompositions for the precomposed Latin letters a path can
  # carry. Keys and values are codepoints; anything not listed is passed
  # through unchanged by to_nfd.

  NFD_TABLE = {
    # Latin-1 Supplement
    0x00C0 => [0x41, 0x0300], 0x00C1 => [0x41, 0x0301],
    0x00C2 => [0x41, 0x0302], 0x00C3 => [0x41, 0x0303],
    0x00C4 => [0x41, 0x0308], 0x00C5 => [0x41, 0x030A],
    0x00C7 => [0x43, 0x0327], 0x00C8 => [0x45, 0x0300],
    0x00C9 => [0x45, 0x0301], 0x00CA => [0x45, 0x0302],
    0x00CB => [0x45, 0x0308], 0x00CC => [0x49, 0x0300],
    0x00CD => [0x49, 0x0301], 0x00CE => [0x49, 0x0302],
    0x00CF => [0x49, 0x0308], 0x00D1 => [0x4E, 0x0303],
    0x00D2 => [0x4F, 0x0300], 0x00D3 => [0x4F, 0x0301],
    0x00D4 => [0x4F, 0x0302], 0x00D5 => [0x4F, 0x0303],
    0x00D6 => [0x4F, 0x0308], 0x00D9 => [0x55, 0x0300],
    0x00DA => [0x55, 0x0301], 0x00DB => [0x55, 0x0302],
    0x00DC => [0x55, 0x0308], 0x00DD => [0x59, 0x0301],
    0x00E0 => [0x61, 0x0300], 0x00E1 => [0x61, 0x0301],
    0x00E2 => [0x61, 0x0302], 0x00E3 => [0x61, 0x0303],
    0x00E4 => [0x61, 0x0308], 0x00E5 => [0x61, 0x030A],
    0x00E7 => [0x63, 0x0327], 0x00E8 => [0x65, 0x0300],
    0x00E9 => [0x65, 0x0301], 0x00EA => [0x65, 0x0302],
    0x00EB => [0x65, 0x0308], 0x00EC => [0x69, 0x0300],
    0x00ED => [0x69, 0x0301], 0x00EE => [0x69, 0x0302],
    0x00EF => [0x69, 0x0308], 0x00F1 => [0x6E, 0x0303],
    0x00F2 => [0x6F, 0x0300], 0x00F3 => [0x6F, 0x0301],
    0x00F4 => [0x6F, 0x0302], 0x00F5 => [0x6F, 0x0303],
    0x00F6 => [0x6F, 0x0308], 0x00F9 => [0x75, 0x0300],
    0x00FA => [0x75, 0x0301], 0x00FB => [0x75, 0x0302],
    0x00FC => [0x75, 0x0308], 0x00FD => [0x79, 0x0301],
    0x00FF => [0x79, 0x0308],
    # Latin Extended-A
    0x0100 => [0x41, 0x0304], 0x0101 => [0x61, 0x0304],
    0x0102 => [0x41, 0x0306], 0x0103 => [0x61, 0x0306],
    0x0104 => [0x41, 0x0328], 0x0105 => [0x61, 0x0328],
    0x0106 => [0x43, 0x0301], 0x0107 => [0x63, 0x0301],
    0x0108 => [0x43, 0x0302], 0x0109 => [0x63, 0x0302],
    0x010A => [0x43, 0x0307], 0x010B => [0x63, 0x0307],
    0x010C => [0x43, 0x030C], 0x010D => [0x63, 0x030C],
    0x010E => [0x44, 0x030C], 0x010F => [0x64, 0x030C],
    0x0110 => [0x44, 0x0305], 0x0111 => [0x64, 0x0305],
    0x0112 => [0x45, 0x0304], 0x0113 => [0x65, 0x0304],
    0x0114 => [0x45, 0x0306], 0x0115 => [0x65, 0x0306],
    0x0116 => [0x45, 0x0307], 0x0117 => [0x65, 0x0307],
    0x0118 => [0x45, 0x0328], 0x0119 => [0x65, 0x0328],
    0x011A => [0x45, 0x030C], 0x011B => [0x65, 0x030C],
    0x011C => [0x47, 0x0302], 0x011D => [0x67, 0x0302],
    0x011E => [0x47, 0x0306], 0x011F => [0x67, 0x0306],
    0x0120 => [0x47, 0x0307], 0x0121 => [0x67, 0x0307],
    0x0122 => [0x47, 0x0327], 0x0123 => [0x67, 0x0327],
    0x0124 => [0x48, 0x0302], 0x0125 => [0x68, 0x0302],
    0x0126 => [0x48, 0x0305], 0x0127 => [0x68, 0x0305],
    0x0128 => [0x49, 0x0303], 0x0129 => [0x69, 0x0303],
    0x012A => [0x49, 0x0304], 0x012B => [0x69, 0x0304],
    0x012C => [0x49, 0x0306], 0x012D => [0x69, 0x0306],
    0x012E => [0x49, 0x0328], 0x012F => [0x69, 0x0328],
    0x0130 => [0x49, 0x0307],
    0x0134 => [0x4A, 0x0302], 0x0135 => [0x6A, 0x0302],
    0x0136 => [0x4B, 0x0327], 0x0137 => [0x6B, 0x0327],
    0x0139 => [0x4C, 0x0301], 0x013A => [0x6C, 0x0301],
    0x013B => [0x4C, 0x0327], 0x013C => [0x6C, 0x0327],
    0x013D => [0x4C, 0x030C], 0x013E => [0x6C, 0x030C],
    0x013F => [0x4C, 0x0307], 0x0140 => [0x6C, 0x0307],
    0x0143 => [0x4E, 0x0301], 0x0144 => [0x6E, 0x0301],
    0x0145 => [0x4E, 0x0327], 0x0146 => [0x6E, 0x0327],
    0x0147 => [0x4E, 0x030C], 0x0148 => [0x6E, 0x030C],
    0x0149 => [0x02BC, 0x006E],
    0x014C => [0x4F, 0x0304], 0x014D => [0x6F, 0x0304],
    0x014E => [0x4F, 0x0306], 0x014F => [0x6F, 0x0306],
    0x0150 => [0x4F, 0x030B], 0x0151 => [0x6F, 0x030B],
    0x0154 => [0x52, 0x0301], 0x0155 => [0x72, 0x0301],
    0x0156 => [0x52, 0x0327], 0x0157 => [0x72, 0x0327],
    0x0158 => [0x52, 0x030C], 0x0159 => [0x72, 0x030C],
    0x015A => [0x53, 0x0301], 0x015B => [0x73, 0x0301],
    0x015C => [0x53, 0x0302], 0x015D => [0x73, 0x0302],
    0x015E => [0x53, 0x0327], 0x015F => [0x73, 0x0327],
    0x0160 => [0x53, 0x030C], 0x0161 => [0x73, 0x030C],
    0x0162 => [0x54, 0x0327], 0x0163 => [0x74, 0x0327],
    0x0164 => [0x54, 0x030C], 0x0165 => [0x74, 0x030C],
    0x0166 => [0x54, 0x0305], 0x0167 => [0x74, 0x0305],
    0x0168 => [0x55, 0x0303], 0x0169 => [0x75, 0x0303],
    0x016A => [0x55, 0x0304], 0x016B => [0x75, 0x0304],
    0x016C => [0x55, 0x0306], 0x016D => [0x75, 0x0306],
    0x016E => [0x55, 0x030A], 0x016F => [0x75, 0x030A],
    0x0170 => [0x55, 0x030B], 0x0171 => [0x75, 0x030B],
    0x0172 => [0x55, 0x0328], 0x0173 => [0x75, 0x0328],
    0x0174 => [0x57, 0x0302], 0x0175 => [0x77, 0x0302],
    0x0176 => [0x59, 0x0302], 0x0177 => [0x79, 0x0302],
    0x0178 => [0x59, 0x0308],
    0x0179 => [0x5A, 0x0301], 0x017A => [0x7A, 0x0301],
    0x017B => [0x5A, 0x0307], 0x017C => [0x7A, 0x0307],
    0x017D => [0x5A, 0x030C], 0x017E => [0x7A, 0x030C]
  }.freeze
end

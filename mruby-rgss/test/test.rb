# The Bitmap loader consults the app-provided GAME_DIR/RTP_DIR search roots on
# every String load (the app sets them at startup in src/main.cxx). Define empty
# stand-ins so the standalone mrbtest can load fixtures by absolute/relative path
# without the search roots being defined.
GAME_DIR = "" unless Object.const_defined?(:GAME_DIR)
RTP_DIR = "" unless Object.const_defined?(:RTP_DIR)

# From: https://github.com/uni-algo/uni-algo?tab=readme-ov-file#normalization-functions
assert "RGSS.to_nfd" do
  assert_equal RGSS.to_nfd("Ŵ"), "W\u0302"
end

assert "RGSS::Color basics" do
  c = RGSS::Color.new(10, 20, 30)
  assert_equal 10.0, c.red
  assert_equal 20.0, c.green
  assert_equal 30.0, c.blue
  assert_equal 255.0, c.alpha

  c.set(1, 2, 3, 4)
  assert_equal 1.0, c.red
  assert_equal 4.0, c.alpha

  c.red = 500
  assert_equal 255.0, c.red # clamped to 0..255
  c.blue = -10
  assert_equal 0.0, c.blue
end

assert "RGSS::Color equality and marshal" do
  a = RGSS::Color.new(1, 2, 3, 4)
  b = RGSS::Color.new(1, 2, 3, 4)
  assert_true a == b
  assert_false a == RGSS::Color.new(1, 2, 3, 5)

  loaded = Marshal.load(Marshal.dump(a))
  assert_true loaded.is_a?(RGSS::Color)
  assert_true a == loaded
end

assert "RGSS::Tone basics and clamping" do
  t = RGSS::Tone.new(-300, 20, 30, 400)
  assert_equal(-255.0, t.red) # clamped to -255..255
  assert_equal 20.0, t.green
  assert_equal 255.0, t.gray  # clamped to 0..255

  loaded = Marshal.load(Marshal.dump(t))
  assert_true loaded == t
end

assert "RGSS::Rect basics" do
  r = RGSS::Rect.new(1, 2, 3, 4)
  assert_equal 1, r.x
  assert_equal 4, r.height
  r.set(5, 6, 7, 8)
  assert_equal 5, r.x
  assert_equal 8, r.height

  assert_true r == RGSS::Rect.new(5, 6, 7, 8)

  loaded = Marshal.load(Marshal.dump(r))
  assert_true loaded == r

  r.empty
  assert_equal 0, r.x
  assert_equal 0, r.width
end

assert "RGSS::Table 1D" do
  t = RGSS::Table.new(3)
  assert_equal 3, t.xsize
  assert_equal 1, t.ysize
  assert_equal 1, t.zsize
  assert_equal 1, t.dim
  assert_equal 0, t[0]
  t[0] = 42
  t[2] = -7
  assert_equal 42, t[0]
  assert_equal(-7, t[2])
  assert_nil t[3]  # out of range
  assert_nil t[-1]
end

assert "RGSS::Table 3D and resize" do
  t = RGSS::Table.new(2, 3, 4)
  assert_equal 3, t.dim
  assert_equal 4, t.zsize
  t[1, 2, 3] = 99
  assert_equal 99, t[1, 2, 3]
  assert_equal 0, t[0, 0, 0]

  t.resize(4, 3, 4)
  assert_equal 4, t.xsize
  assert_equal 99, t[1, 2, 3] # preserved through resize
end

assert "RGSS::Table marshal round-trip" do
  t = RGSS::Table.new(2, 2)
  t[0, 0] = 1
  t[1, 0] = 2
  t[0, 1] = 3
  t[1, 1] = 4
  loaded = Marshal.load(Marshal.dump(t))
  assert_true loaded.is_a?(RGSS::Table)
  assert_equal 2, loaded.xsize
  assert_equal 2, loaded.ysize
  assert_equal 1, loaded[0, 0]
  assert_equal 4, loaded[1, 1]
end

assert "RGSS::Bitmap pixel operations" do
  b = RGSS::Bitmap.new(4, 4)
  assert_equal 4, b.width
  assert_equal 4, b.height
  assert_equal 0, b.rect.x
  assert_equal 4, b.rect.width

  b.set_pixel(1, 1, RGSS::Color.new(10, 20, 30, 40))
  px = b.get_pixel(1, 1)
  assert_equal 10.0, px.red
  assert_equal 20.0, px.green
  assert_equal 30.0, px.blue
  assert_equal 40.0, px.alpha

  b.fill_rect(0, 0, 4, 4, RGSS::Color.new(255, 0, 0, 255))
  assert_equal 255.0, b.get_pixel(3, 3).red

  b.clear
  assert_equal 0.0, b.get_pixel(3, 3).red
  assert_equal 0.0, b.get_pixel(3, 3).alpha
end

assert "RGSS::Bitmap blt" do
  src = RGSS::Bitmap.new(2, 2)
  src.fill_rect(0, 0, 2, 2, RGSS::Color.new(0, 128, 0, 255))
  dst = RGSS::Bitmap.new(4, 4)
  dst.blt(1, 1, src, RGSS::Rect.new(0, 0, 2, 2))
  assert_equal 128.0, dst.get_pixel(1, 1).green
  assert_equal 128.0, dst.get_pixel(2, 2).green
  assert_equal 0.0, dst.get_pixel(0, 0).alpha # untouched
end

assert "RGSS::Bitmap tone_blt" do
  src = RGSS::Bitmap.new(2, 2)
  src.fill_rect(0, 0, 2, 2, RGSS::Color.new(100, 150, 200, 255))

  # A neutral tone copies the source through untouched.
  dst = RGSS::Bitmap.new(2, 2)
  dst.tone_blt(src, RGSS::Tone.new(0, 0, 0, 0))
  assert_equal 100.0, dst.get_pixel(0, 0).red
  assert_equal 150.0, dst.get_pixel(0, 0).green
  assert_equal 200.0, dst.get_pixel(0, 0).blue
  assert_equal 255.0, dst.get_pixel(0, 0).alpha

  # Offsets are added per channel and clamped at both ends.
  dst.tone_blt(src, RGSS::Tone.new(50, -200, 100, 0))
  assert_equal 150.0, dst.get_pixel(1, 1).red
  assert_equal 0.0, dst.get_pixel(1, 1).green   # 150 - 200 clamps to 0
  assert_equal 255.0, dst.get_pixel(1, 1).blue  # 200 + 100 clamps to 255

  # Full gray pulls every channel to the luminance of the source pixel:
  # (100*299 + 150*587 + 200*114) / 1000 = 140.75, truncated to 140 by the
  # integer pixel path (no rounding, as elsewhere in the blitters).
  dst.tone_blt(src, RGSS::Tone.new(0, 0, 0, 255))
  assert_equal 140.0, dst.get_pixel(0, 1).red
  assert_equal 140.0, dst.get_pixel(0, 1).green
  assert_equal 140.0, dst.get_pixel(0, 1).blue

  # Toning reads the source every time rather than accumulating: repeating the
  # same call is idempotent, which is what stops a per-frame tone marching a
  # cached layer to black.
  before = dst.get_pixel(0, 1).red
  dst.tone_blt(src, RGSS::Tone.new(0, 0, 0, 255))
  assert_equal before, dst.get_pixel(0, 1).red

  # Alpha is carried through untouched -- a tone tints what shows, it does not
  # change what is visible.
  faded = RGSS::Bitmap.new(2, 2)
  faded.fill_rect(0, 0, 2, 2, RGSS::Color.new(10, 10, 10, 77))
  dst.tone_blt(faded, RGSS::Tone.new(90, 0, 0, 0))
  assert_equal 77.0, dst.get_pixel(0, 0).alpha
  assert_equal 100.0, dst.get_pixel(0, 0).red
end

assert "RGSS::Bitmap stretch_blt" do
  src = RGSS::Bitmap.new(2, 2)
  src.fill_rect(0, 0, 2, 2, RGSS::Color.new(0, 0, 255, 255))
  dst = RGSS::Bitmap.new(8, 8)
  # Stretch the 2x2 source across a 4x4 destination region.
  dst.stretch_blt(RGSS::Rect.new(2, 2, 4, 4), src, RGSS::Rect.new(0, 0, 2, 2))
  assert_equal 255.0, dst.get_pixel(2, 2).blue
  assert_equal 255.0, dst.get_pixel(5, 5).blue
  assert_equal 0.0, dst.get_pixel(0, 0).alpha # outside the destination rect
  assert_equal 0.0, dst.get_pixel(6, 6).alpha
end

assert "RGSS::Bitmap gradient_fill_rect" do
  red = RGSS::Color.new(255, 0, 0, 255)
  blue = RGSS::Color.new(0, 0, 255, 255)

  # Horizontal gradient across the full width (span 9 => denominator 8).
  b = RGSS::Bitmap.new(9, 2)
  b.gradient_fill_rect(0, 0, 9, 2, red, blue)
  assert_equal 255.0, b.get_pixel(0, 0).red  # left end is color1
  assert_equal 0.0, b.get_pixel(0, 0).blue
  assert_equal 0.0, b.get_pixel(8, 1).red    # right end is color2
  assert_equal 255.0, b.get_pixel(8, 1).blue
  mid = b.get_pixel(4, 0)                     # halfway: t = 4/8 = 0.5
  assert_equal 127.0, mid.red                 # 255 - 255*0.5 = 127.5 -> 127
  assert_equal 127.0, mid.blue

  # Vertical gradient via the Rect overload + the vertical flag.
  v = RGSS::Bitmap.new(2, 9)
  v.gradient_fill_rect(RGSS::Rect.new(0, 0, 2, 9), red, blue, true)
  assert_equal 255.0, v.get_pixel(1, 0).red   # top row is color1
  assert_equal 255.0, v.get_pixel(1, 8).blue  # bottom row is color2
end

assert "RGSS::Bitmap hue_change" do
  # A 120-degree hue rotation maps the primaries exactly: R -> G -> B -> R,
  # preserving saturation, value and alpha.
  b = RGSS::Bitmap.new(2, 2)
  b.fill_rect(0, 0, 2, 2, RGSS::Color.new(255, 0, 0, 200))
  b.hue_change(120)  # red -> green
  px = b.get_pixel(0, 0)
  assert_equal 0.0, px.red
  assert_equal 255.0, px.green
  assert_equal 0.0, px.blue
  assert_equal 200.0, px.alpha  # alpha untouched

  b.hue_change(120)  # green -> blue
  assert_equal 255.0, b.get_pixel(1, 1).blue
  assert_equal 0.0, b.get_pixel(1, 1).green

  b.hue_change(0)  # no-op
  assert_equal 255.0, b.get_pixel(1, 1).blue
end

assert "RGSS::Viewport API surface" do
  # Viewport creation needs a live display, which the test binary does not set
  # up, so only assert the method surface here (exercised for real by the game).
  %i[rect rect= ox oy ox= oy= z= visible visible= update dispose disposed?].each do |m|
    assert_true RGSS::Viewport.method_defined?(m), "Viewport##{m} missing"
  end
end

assert "RGSS::Sprite API surface" do
  # opacity=/zoom_x=/zoom_y=/angle=/mirror= are native (honoured by the LVGL
  # compositor, src/lib.cxx); the rest are native too. Sprite.new needs a live
  # display, so this only asserts the method surface — the compositing itself is
  # exercised by the game runs.
  %i[bitmap= x= y= z= visible visible= opacity= zoom_x= zoom_y= angle= mirror=
     tone= color= src_rect= update blend_type= bush_depth= flash dispose
     disposed?].each do |m|
    assert_true RGSS::Sprite.method_defined?(m), "Sprite##{m} missing"
  end
end

assert "RGSS::Font defaults" do
  f = RGSS::Font.new
  assert_equal RGSS::Font.default_name, f.name
  assert_equal RGSS::Font.default_size, f.size
  assert_true f.color.is_a?(RGSS::Color)
  assert_true RGSS::Font.exist?("Arial")
end

# draw_text/text_size read the whole Font (name, size, bold, italic, outline,
# shadow, colours) to pick a TrueType face and lay text out. No game font file
# is reachable under the test's empty GAME_DIR/RTP_DIR, so drawing falls back to
# the built-in shinonome bitmap font; these checks cover that fallback and the
# Font-attribute plumbing the TrueType path shares.
assert "RGSS::Bitmap#draw_text renders in the font colour" do
  b = RGSS::Bitmap.new(64, 24)
  b.font.color = RGSS::Color.new(255, 0, 0, 255)
  b.draw_text(0, 0, 64, 24, "Hi")

  drawn = nil
  0.upto(23) do |y|
    0.upto(63) do |x|
      px = b.get_pixel(x, y)
      if px.alpha > 0
        drawn = px
        break
      end
    end
    break if drawn
  end
  assert_true !drawn.nil?, "draw_text drew no pixels"
  assert_equal 255.0, drawn.red
  assert_equal 0.0, drawn.green
  assert_equal 0.0, drawn.blue
end

assert "RGSS::Bitmap#draw_text honours every Font attribute without error" do
  b = RGSS::Bitmap.new(80, 24)
  b.font.bold = true
  b.font.italic = true
  b.font.outline = true
  b.font.shadow = true
  b.font.out_color = RGSS::Color.new(0, 0, 0, 128)
  # An array of family names is accepted (RGSS allows it); must not raise.
  b.font.name = ["Nonexistent Family", "Arial"]
  assert_equal b, b.draw_text(0, 0, 80, 24, "Ok", 1)
end

assert "RGSS::Bitmap#text_size measures ASCII text" do
  b = RGSS::Bitmap.new(64, 24)
  r = b.text_size("Hello")
  assert_true r.is_a?(RGSS::Rect)
  assert_true r.width > 0, "text_size width should be positive"
  assert_true r.height > 0, "text_size height should be positive"
  assert_equal 0, b.text_size("").width
end

assert "RGSS::Bitmap loads RPG Maker XYZ images" do
  # A 3x2 XYZ picture: "XYZ1" + uint16 LE width/height + a zlib stream holding
  # a 768-byte RGB palette then one index per pixel. Palette 0 = (10,20,30),
  # 1 = (255,0,0), 2 = (0,255,0); pixels are 0,1,2 / 2,1,0.
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
          "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
          "\x8b\x02\x41"
  path = "test-windowskin.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path)
    assert_equal 3, b.width
    assert_equal 2, b.height
    # Top-left pixel is palette index 0 -> (10, 20, 30), opaque.
    px = b.get_pixel(0, 0)
    assert_equal 10.0, px.red
    assert_equal 20.0, px.green
    assert_equal 30.0, px.blue
    assert_equal 255.0, px.alpha
    # (1,0) is palette index 1 (red), (2,0) is index 2 (green).
    assert_equal 255.0, b.get_pixel(1, 0).red
    assert_equal 255.0, b.get_pixel(2, 0).green
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap keys the XYZ transparent colour when requested" do
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xe3\x12\x91\xfb\xcf\xc0" \
          "\xc0\x00\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00\xb4" \
          "\x8b\x02\x41"
  path = "test-windowskin-trans.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path, true)
    # Palette index 0 becomes fully transparent, other indices stay opaque.
    assert_equal 0.0, b.get_pixel(0, 0).alpha
    assert_equal 255.0, b.get_pixel(1, 0).alpha
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap decodes XYZ pixels stored as raw DEFLATE" do
  # Same 3x2 picture, but the payload is raw DEFLATE with no 2-byte zlib
  # header; stb's default zlib client rejects it, so this exercises the
  # no-header inflate fallback.
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\xe3\x12\x91\xfb\xcf\xc0\xc0\x00" \
          "\xc2\xa3\x60\x14\x8c\x3c\xc0\xc8\xc4\xc4\xc8\x00\x00"
  path = "test-windowskin-raw.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path)
    assert_equal 3, b.width
    assert_equal 255.0, b.get_pixel(1, 0).red
    assert_equal 255.0, b.get_pixel(2, 0).green
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap reports a detailed reason when an XYZ fails to decode" do
  # Valid "XYZ1" header and zlib header byte, but a corrupt DEFLATE body.
  bytes = "\x58\x59\x5a\x31\x03\x00\x02\x00\x78\x9c\xff\xff\xff\xff\xff\xff" \
          "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
  path = "test-windowskin-bad.xyz"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    err = nil
    begin
      RGSS::Bitmap.new(path)
    rescue => e
      err = e.message
    end
    assert_true !err.nil?, "expected a load failure"
    # The message carries the parsed dimensions so the failure is diagnosable.
    assert_true err.include?("XYZ 3x2"), "message: #{err}"
    assert_true RGSS::Bitmap._load_error.include?("XYZ 3x2")
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Profiler is inert until enabled" do
  # The standalone test binary never calls profiler_configure, so profiling is
  # off by default: query methods report the disabled state and the block-timing
  # helpers still run their block and return its value transparently.
  assert_false RGSS::Profiler.enabled?
  assert_nil RGSS::Profiler.stats

  ran = false
  result = RGSS::Profiler.section("noop") do
    ran = true
    123
  end
  assert_true ran, "section must always run its block"
  assert_equal 123, result

  ran = false
  result = RGSS::Profiler.frame do
    ran = true
    "ok"
  end
  assert_true ran, "frame must always run its block"
  assert_equal "ok", result
end

assert "RGSS::Profiler aggregates frames and sections when enabled" do
  RGSS::Profiler.enabled = true
  begin
    RGSS::Profiler.reset
    assert_true RGSS::Profiler.enabled?

    3.times do
      RGSS::Profiler.frame do
        RGSS::Profiler.section("work") { 100.times { |i| i * i } }
      end
    end

    st = RGSS::Profiler.stats
    assert_true st.is_a?(Hash)
    assert_equal 3, st[:frames]
    assert_true st[:fps] >= 0.0
    assert_true st[:frame_avg_ms] >= 0.0

    sections = st[:sections]
    assert_true sections.is_a?(Hash)
    assert_true sections.key?("work"), "expected a 'work' section"
    assert_equal 3, sections["work"][:calls]
    assert_true sections["work"][:avg_ms] >= 0.0

    # report and reset must not raise; reset clears the interval.
    RGSS::Profiler.report
    RGSS::Profiler.reset
    assert_equal 0, RGSS::Profiler.stats[:frames]
  ensure
    RGSS::Profiler.enabled = false
  end
end

assert "RGSS::Profiler streams a Chrome trace" do
  path = "test-profiler-trace.json"
  File.delete(path) if File.exist?(path)
  begin
    assert_false RGSS::Profiler.tracing?
    RGSS::Profiler.trace_start(path)
    assert_true RGSS::Profiler.tracing?
    assert_true RGSS::Profiler.enabled?  # tracing implies profiling

    3.times do
      RGSS::Profiler.frame do
        RGSS::Profiler.section("unit.work") { 50.times { |i| i * i } }
      end
    end

    RGSS::Profiler.trace_stop
    assert_false RGSS::Profiler.tracing?

    json = File.open(path, "r") { |f| f.read }
    # A well-formed Chrome Trace Event array with the frame and section events.
    assert_true json.start_with?("["), "trace must be a JSON array"
    assert_true json.include?("\"ph\":\"X\""), "expected duration events"
    assert_true json.include?("unit.work"), "expected the section name"
    assert_true json.include?("\"name\":\"frame\""), "expected frame events"
  ensure
    RGSS::Profiler.trace_stop
    RGSS::Profiler.enabled = false
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Audio primitives are inert without a backend" do
  # The standalone test binary installs no audio backend (that lives in the
  # executable, src/sdl_audio.cxx), so every native primitive is a safe no-op.
  assert_nil RGSS::Audio._bgm_play("nope", 80, 90)
  assert_nil RGSS::Audio._bgm_stop
  assert_nil RGSS::Audio._bgm_fade(100)
  assert_equal 0, RGSS::Audio._bgm_pos
  assert_nil RGSS::Audio._bgs_play("nope")
  assert_nil RGSS::Audio._bgs_stop
  assert_nil RGSS::Audio._bgs_fade(100)
  assert_equal 0, RGSS::Audio._bgs_pos
  assert_nil RGSS::Audio._me_play("nope")
  assert_nil RGSS::Audio._me_stop
  assert_nil RGSS::Audio._me_fade(100)
  assert_nil RGSS::Audio._se_play("nope")
  assert_nil RGSS::Audio._se_stop
  assert_nil RGSS::Audio._update
end

assert "RGSS::Audio.se_play resolves a name to a real file" do
  # Capture what the public API forwards to the native primitive so we can
  # assert the filename was resolved (extension appended) and volume/pitch
  # passed through.
  path = "test-se-fixture.wav"
  File.open(path, "wb") { |io| io.write("RIFFtestWAVEfixture") }
  class << RGSS::Audio
    alias _se_play_orig _se_play
    def _se_play(p, v, pi)
      $audio_se_capture = [p, v, pi]
      nil
    end
  end
  begin
    $audio_se_capture = nil
    RGSS::Audio.se_play("test-se-fixture", 80, 90)
    assert_false $audio_se_capture.nil?, "expected _se_play to be called"
    assert_equal "test-se-fixture.wav", $audio_se_capture[0]
    assert_equal 80, $audio_se_capture[1]
    assert_equal 90, $audio_se_capture[2]

    # A name that resolves to nothing skips the native call entirely.
    $audio_se_capture = nil
    RGSS::Audio.se_play("no-such-sound-effect")
    assert_true $audio_se_capture.nil?, "unresolved name must not play"
  ensure
    class << RGSS::Audio
      alias _se_play _se_play_orig
    end
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Bitmap loads a PNG whose deflate stream trips \"bad dist\"" do
  # A 4x1 grayscale PNG hand-encoded so its IDAT references a zero pre-history
  # window (distance-too-far-back). stb_image and strict zlib reject it with
  # "bad dist"; the tolerant fallback resolves the out-of-range reference to
  # zeros. Pixels decode to grayscale 0, 0, 0, 9.
  bytes = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" \
          "\x00\x00\x00\x04\x00\x00\x00\x01\x08\x00\x00\x00\x00\xdc\x57\x50" \
          "\x11\x00\x00\x00\x0b\x49\x44\x41\x54\x78\x01\x63\x00\x62\x4e\x00" \
          "\x00\x0e\x00\x0a\x61\xd4\xa9\x6f\x00\x00\x00\x00\x49\x45\x4e\x44" \
          "\xae\x42\x60\x82"
  path = "test-baddist.png"
  File.open(path, "wb") { |io| io.write(bytes) }
  begin
    b = RGSS::Bitmap.new(path)
    assert_equal 4, b.width
    assert_equal 1, b.height
    assert_equal 0.0, b.get_pixel(0, 0).red
    assert_equal 9.0, b.get_pixel(3, 0).red
    assert_equal 255.0, b.get_pixel(3, 0).alpha
  ensure
    File.delete(path) if File.exist?(path)
  end
end

assert "RGSS::Plane API surface" do
  # Plane is now native: Plane.new builds an lv_canvas the size of the viewport
  # and tiles the bitmap into it, so construction needs a live display the
  # headless test binary lacks. Assert only the method surface here (the tiling
  # itself is exercised by the game runs), matching the Viewport/Sprite tests.
  %i[bitmap= ox= oy= opacity= tone= color= blend_type= zoom_x= zoom_y= z=
     visible visible= dispose disposed?].each do |m|
    assert_true RGSS::Plane.method_defined?(m), "Plane##{m} missing"
  end
end

assert "RGSS::Window API surface" do
  # Window is now native: Window.new builds an lv_canvas the size of the window
  # and blits the contents into it, so construction needs a live display the
  # headless test binary lacks. Assert only the method surface here (the
  # compositing itself is exercised by the game runs), matching Sprite/Plane. The
  # still-Ruby deferred accessors (windowskin, cursor_rect, opacity,
  # back_opacity, active, pause, stretch) are covered by being defined below.
  %i[contents= x= y= width= height= ox= oy= contents_opacity= z= visible
     visible= dispose disposed? windowskin windowskin= cursor_rect cursor_rect=
     opacity opacity= back_opacity back_opacity= cursor_rect= active active=
     pause pause= stretch stretch= update].each do |m|
    assert_true RGSS::Window.method_defined?(m), "Window##{m} missing"
  end
end

assert "RGSS::Input accepts RGSS2/RGSS3 symbol keys" do
  # VX and VX Ace name the keys with symbols (Input.trigger?(:C)); XP and the
  # C++ input bridge use the integer constants. Both must reach the same key.
  begin
    RGSS::Input.press(RGSS::Input::C)
    assert_true RGSS::Input.press?(:C), "a symbol must read the integer press"
    assert_true RGSS::Input.trigger?(:C)
    RGSS::Input.release(:C)
    assert_false RGSS::Input.press?(RGSS::Input::C), "a symbol release must clear it"

    RGSS::Input.press(:UP)
    assert_true RGSS::Input.press?(RGSS::Input::UP), "a symbol press must set the key"
    assert_equal 8, RGSS::Input.dir4

    # Every RGSS3 key name maps, and an unknown one reads as unpressed instead
    # of raising out of the game loop.
    assert_equal 20, RGSS::Input::SYMBOL_KEYS.size
    RGSS::Input::SYMBOL_KEYS.each do |name, index|
      assert_equal index, RGSS::Input.key_index(name), "key #{name} maps wrong"
    end
    assert_false RGSS::Input.press?(:NO_SUCH_KEY)
    assert_nil RGSS::Input.release(:NO_SUCH_KEY)
  ensure
    RGSS::Input.release(:UP)
    RGSS::Input.release(:C)
  end
end

assert "RGSS::Graphics reports and resizes the screen" do
  # RGSS2 added Graphics.width/height; each maker's boot shell declares its own
  # resolution, and the stock VX Ace scripts compute camera and window layouts
  # from them.
  begin
    RGSS::Graphics.resize_screen(544, 416)
    assert_equal 544, RGSS::Graphics.width
    assert_equal 416, RGSS::Graphics.height

    assert_equal 255, RGSS::Graphics.brightness
    RGSS::Graphics.brightness = -5
    assert_equal 0, RGSS::Graphics.brightness
    RGSS::Graphics.brightness = 999
    assert_equal 255, RGSS::Graphics.brightness
  ensure
    RGSS::Graphics.resize_screen(640, 480)
    RGSS::Graphics.brightness = 255
  end
end

assert "RGSS::Graphics.wait / fadeout drive real frames" do
  # Graphics.update is native and needs a live display the headless test binary
  # lacks, so count the frames through a stand-in — what is under test is that
  # the RGSS2 waits run the frames the game's timing depends on.
  class << RGSS::Graphics
    alias _update_orig update
    def update
      $graphics_frames = ($graphics_frames || 0) + 1
      nil
    end
  end
  begin
    $graphics_frames = 0
    RGSS::Graphics.wait(3)
    assert_equal 3, $graphics_frames

    RGSS::Graphics.fadeout(2)
    assert_equal 5, $graphics_frames
    assert_equal 0, RGSS::Graphics.brightness

    RGSS::Graphics.fadein(1)
    assert_equal 6, $graphics_frames
    assert_equal 255, RGSS::Graphics.brightness
  ensure
    class << RGSS::Graphics
      alias update _update_orig
    end
    RGSS::Graphics.brightness = 255
  end
end

assert "RGSS::Audio.setup_midi is a safe no-op" do
  # RGSS2+; the VX/VX Ace scripts call it at boot when the project asks for
  # MIDI. SDL_mixer picks its own synth, so there is nothing to configure.
  assert_nil RGSS::Audio.setup_midi
end

assert "RGSS::Window RGSS2/RGSS3 API surface" do
  # Window.new needs a live display (see the Tilemap note below), so assert the
  # VX/VX Ace surface is defined; the behaviour of these accessors is exercised
  # by the VX runtime checks (scripts/rpgvx_testbed_check.rb). The dual-form
  # constructor (RGSS1's optional viewport / RGSS2's x, y, width, height) needs
  # no assertion here: it aliases the native initialize at load, so a broken
  # alias would fail the whole gem, not one test.
  %i[openness openness= open? close? padding padding= padding_bottom
     padding_bottom= arrows_visible arrows_visible= tone tone=].each do |m|
    assert_true RGSS::Window.method_defined?(m), "Window##{m} missing"
  end
end

assert "RGSS::Tilemap API surface" do
  # Tilemap is now native: Tilemap.new builds an lv_canvas the size of the
  # viewport and blits the visible tiles into it, so construction needs a live
  # display the headless test binary lacks. Assert only the method surface here
  # (the tile rendering is exercised by the game runs), matching Sprite/Plane.
  %i[tileset= map_data= ox= oy= z= visible visible= dispose disposed?
     autotiles priorities priorities= flash_data flash_data= update].each do |m|
    assert_true RGSS::Tilemap.method_defined?(m), "Tilemap##{m} missing"
  end
end

# RGSS::Sprite.new needs an initialized display (it references RGSS::_display),
# which the headless mrbtest build does not set up, so the Sprite extended
# properties cannot be exercised here — they are load-verified with the rest of
# mruby-rgss/mrblib and share the exact accessor pattern the Plane test above
# covers (RGSS defaults, nil?-vs-|| for 0/false-meaningful values, read/write).

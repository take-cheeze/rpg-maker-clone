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
  %i[bitmap= x= y= z= visible visible= opacity= zoom_x= zoom_y= angle= mirror= dispose disposed?].each do |m|
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
  %i[bitmap= ox= oy= opacity= z= visible visible= dispose disposed?].each do |m|
    assert_true RGSS::Plane.method_defined?(m), "Plane##{m} missing"
  end
end

assert("RGSS::Window property defaults and accessors") do
  w = RGSS::Window.new
  # RGSS defaults.
  assert_true w.windowskin.nil?
  assert_true w.contents.nil?
  assert_true w.cursor_rect.is_a?(RGSS::Rect)
  assert_equal 0, w.x
  assert_equal 0, w.y
  assert_equal 0, w.width
  assert_equal 0, w.height
  assert_equal 0, w.ox
  assert_equal 0, w.oy
  assert_equal 255, w.opacity
  assert_equal 255, w.back_opacity
  assert_equal 255, w.contents_opacity
  assert_true w.visible
  assert_equal 0, w.z
  assert_true w.active
  assert_false w.pause
  assert_true w.stretch
  assert_true w.viewport.nil?
  assert_false w.disposed?

  # Writable — the stock Window_Base sets these on every window.
  w.x = 80
  w.y = 64
  w.width = 160
  w.height = 128
  w.back_opacity = 200
  w.contents_opacity = 128
  w.active = false
  w.pause = true
  w.z = 100
  w.cursor_rect = RGSS::Rect.new(0, 0, 32, 32)
  assert_equal 80, w.x
  assert_equal 64, w.y
  assert_equal 160, w.width
  assert_equal 128, w.height
  assert_equal 200, w.back_opacity
  assert_equal 128, w.contents_opacity
  assert_false w.active
  assert_true w.pause
  assert_equal 100, w.z
  assert_equal 32, w.cursor_rect.width

  # A viewport-bound window remembers whatever viewport it was constructed with.
  # (A real RGSS::Viewport needs a live display the headless test binary lacks,
  # so a marker object stands in — Window only stores the reference.)
  marker = Object.new
  assert_equal marker, RGSS::Window.new(marker).viewport

  w.update
  w.dispose
  assert_true w.disposed?
end

assert("RGSS::Tilemap property defaults and accessors") do
  t = RGSS::Tilemap.new
  # RGSS defaults.
  assert_true t.tileset.nil?
  assert_true t.map_data.nil?
  assert_true t.flash_data.nil?
  assert_true t.priorities.nil?
  assert_true t.visible
  assert_equal 0, t.ox
  assert_equal 0, t.oy
  assert_true t.viewport.nil?
  assert_false t.disposed?
  # Seven autotile slots, all empty, indexable and assignable.
  assert_equal 7, t.autotiles.size
  assert_true t.autotiles[0].nil?
  auto = RGSS::Bitmap.new(96, 128)
  t.autotiles[3] = auto
  assert_equal auto, t.autotiles[3]

  # Writable — Spriteset_Map sets these from $game_map.
  ts = RGSS::Bitmap.new(256, 256)
  data = RGSS::Table.new(20, 15, 3)
  prio = RGSS::Table.new(384)
  t.tileset = ts
  t.map_data = data
  t.priorities = prio
  t.ox = 32
  t.oy = 16
  t.visible = false
  assert_equal ts, t.tileset
  assert_equal data, t.map_data
  assert_equal prio, t.priorities
  assert_equal 32, t.ox
  assert_equal 16, t.oy
  assert_false t.visible

  # A viewport-bound tilemap remembers whatever viewport it was constructed with
  # (a real RGSS::Viewport needs a live display the headless test binary lacks).
  marker = Object.new
  assert_equal marker, RGSS::Tilemap.new(marker).viewport

  t.update
  t.dispose
  assert_true t.disposed?
end

# RGSS::Sprite.new needs an initialized display (it references RGSS::_display),
# which the headless mrbtest build does not set up, so the Sprite extended
# properties cannot be exercised here — they are load-verified with the rest of
# mruby-rgss/mrblib and share the exact accessor pattern the Plane test above
# covers (RGSS defaults, nil?-vs-|| for 0/false-meaningful values, read/write).

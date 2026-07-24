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
  %i[bitmap= x= y= z= visible visible= dispose disposed?].each do |m|
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

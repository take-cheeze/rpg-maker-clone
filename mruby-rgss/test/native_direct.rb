# frozen_string_literal: true

# ADR 0263: the RGSS natives whose bindings were split into a mrb_get_args
# wrapper and a frame-independent `rgss::*_direct` entry point. The entry point
# is what compiled code calls without a frame, so on the same objects it must
# answer and change state exactly as the binding does. RGSS::DirectProbe
# (test/native_direct_probe.cxx, generated table) calls an entry point by name.
#
# Only classes that need no display can be built here; the Sprite/Window/
# Viewport/Plane/Tilemap entry points share their bodies with their bindings by
# construction (scripts/native_binding_split_check.rb) and are exercised by the
# render smoke tests.
probe = RGSS::DirectProbe

assert 'the probe table lists the split entry points' do
  names = probe.names
  assert_true names.size >= 60, "expected the generated entry points, got #{names.size}"
  assert_equal names.size, names.uniq.size
  %w[color_eq_direct rect_eq_direct tone_eq_direct table_load_direct bmp_text_size_direct
     spr_set_zoom_x_direct window_set_ox_direct].each { |n| assert_include names, n }
  assert_raise(ArgumentError) { probe.call('nope_direct', nil) }
end

assert 'a direct entry point rejects a call with the wrong number of arguments before running' do
  assert_raise(ArgumentError) { probe.call('color_eq_direct', RGSS::Color.new(0, 0, 0, 0)) }
end

assert 'Color#==, #to_s, #_dump and ._load: binding and direct entry point agree' do
  a = RGSS::Color.new(1, 2, 3, 4)
  same = RGSS::Color.new(1, 2, 3, 4)
  other = RGSS::Color.new(1, 2, 3, 5)
  [same, other, 5, nil, RGSS::Tone.new(1, 2, 3, 4)].each do |o|
    assert_equal a == o, probe.call('color_eq_direct', a, o), "Color#== #{o.inspect}"
  end
  assert_equal a.to_s, probe.call('color_to_s_direct', a)
  assert_equal a._dump(0), probe.call('color_dump_direct', a)
  packed = a._dump(0)
  assert_true RGSS::Color._load(packed) == probe.call('color_load_direct', RGSS::Color, packed)
  # a short blob is zero-padded the same way by both
  assert_true RGSS::Color._load('') == probe.call('color_load_direct', RGSS::Color, '')
end

assert 'Tone#==, #to_s, #_dump and ._load: binding and direct entry point agree' do
  a = RGSS::Tone.new(10, 20, 30, 40)
  [RGSS::Tone.new(10, 20, 30, 40), RGSS::Tone.new(0, 20, 30, 40), 'x'].each do |o|
    assert_equal a == o, probe.call('tone_eq_direct', a, o)
  end
  assert_equal a.to_s, probe.call('tone_to_s_direct', a)
  assert_equal a._dump(0), probe.call('tone_dump_direct', a)
  packed = a._dump(0)
  assert_true RGSS::Tone._load(packed) == probe.call('tone_load_direct', RGSS::Tone, packed)
end

assert 'Rect#==, #to_s, #_dump, #empty and ._load: binding and direct entry point agree' do
  a = RGSS::Rect.new(1, 2, 3, 4)
  [RGSS::Rect.new(1, 2, 3, 4), RGSS::Rect.new(1, 2, 3, 5), :sym].each do |o|
    assert_equal a == o, probe.call('rect_eq_direct', a, o)
  end
  assert_equal a.to_s, probe.call('rect_to_s_direct', a)
  assert_equal a._dump(0), probe.call('rect_dump_direct', a)
  packed = a._dump(0)
  assert_true RGSS::Rect._load(packed) == probe.call('rect_s_load_direct', RGSS::Rect, packed)
  by_binding = RGSS::Rect.new(5, 6, 7, 8)
  by_direct = RGSS::Rect.new(5, 6, 7, 8)
  by_binding.empty
  probe.call('rect_empty_direct', by_direct)
  assert_true by_binding == by_direct
end

assert 'Table#_dump, ._load and the size readers: binding and direct entry point agree' do
  t = RGSS::Table.new(3, 2, 2)
  t[1, 1, 1] = 7
  assert_equal t.xsize, probe.call('table_xsize_direct', t)
  assert_equal t.ysize, probe.call('table_ysize_direct', t)
  assert_equal t.zsize, probe.call('table_zsize_direct', t)
  assert_equal t.dim, probe.call('table_dim_direct', t)
  assert_equal t._dump(0), probe.call('table_dump_direct', t)
  loaded = probe.call('table_load_direct', RGSS::Table, t._dump(0))
  assert_true loaded.is_a?(RGSS::Table)
  assert_equal 7, loaded[1, 1, 1]
  assert_equal RGSS::Table._load(t._dump(0))[1, 1, 1], loaded[1, 1, 1]
end

assert 'Bitmap#text_size and #blur: binding and direct entry point agree' do
  b = RGSS::Bitmap.new(64, 24)
  %w[Hello a].each do |text|
    r = b.text_size(text)
    d = probe.call('bmp_text_size_direct', b, text)
    assert_equal [r.x, r.y, r.width, r.height], [d.x, d.y, d.width, d.height], "text_size #{text.inspect}"
  end
  b.set_pixel(1, 1, RGSS::Color.new(255, 255, 255, 255))
  clone = b.clone
  b.blur
  probe.call('bmp_blur_direct', clone)
  assert_true b.get_pixel(0, 1) == clone.get_pixel(0, 1)
  assert_equal b.get_pixel(1, 1).red, clone.get_pixel(1, 1).red
end

assert 'Bitmap#_init_size sets up the same bitmap through the binding and the direct entry point' do
  by_binding = RGSS::Bitmap.new(3, 2)
  by_direct = RGSS::Bitmap.allocate
  probe.call('bmp_init_size_direct', by_direct, 3, 2)
  assert_equal by_binding.width, by_direct.width
  assert_equal by_binding.height, by_direct.height
end

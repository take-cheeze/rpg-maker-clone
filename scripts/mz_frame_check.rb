#!/usr/bin/env ruby
# encoding: UTF-8
#
# Assert that the frames scripts/mz_boot_check.bash captures actually show what
# each mode claims. The boot check reads the engine's *log*: it proves MZ
# reached Scene_Map, that `$gameMessage` is busy with `Window_Message` open,
# that `Scene_Menu` was entered, that the save chain settled. None of that looks
# at a pixel — which is how MZ spent a milestone passing every probe while the
# captured PNGs were nearly empty (ADR 0004, M6.3e: `texSubImage2D` was a no-op
# and `bufferData` dropped bare `ArrayBuffer`s, so the tile atlas, every window's
# contents and every batched sprite were missing from frames the log called a
# success). This script is the pixel half of those claims.
#
# It asks two different kinds of question, because one kind is not enough:
#
# **Did this frame keep its pixels?** (per frame, absolute)
#   The M6.3e frames were not blank — the player sprite and the touch-UI button
#   still drew — so "not a flat fill" passes on them. What they had lost was the
#   *map*: 99.5% of the play frame was the clear colour against 68.5% for the
#   fixed build. So a map-bearing frame must not be overwhelmingly one colour,
#   and the message frame's window band must carry enough distinct colours to
#   mean glyphs (antialiased text lands dozens of intermediate colours in it; a
#   window whose contents bitmap never uploaded has only the skin's gradient —
#   measured 105 colours against 18).
#
# **Did the thing this mode claims to show actually reach the frame?**
#   (per mode, relational — each frame against the plain map frame from `play`)
#   message  the bottom band changed a lot and the top band barely at all
#            (a message window drew over the map, and only there)
#   menu     nearly the whole screen changed (Scene_Menu replaced the map)
#   battle   nearly the whole screen changed (Scene_Battle replaced the map),
#   battle_play  and the same for the fight that gets played out
#   animation  the middle of the frame changed and its edges did not (the burst
#            drew on the player, and only there)
#   save     almost nothing changed (the round-trip landed back on an intact
#            map — a save that returns to a wrecked or empty scene fails here)
#
# The relational half alone would *not* have caught M6.3e: that bug degraded
# every frame the same way, so the differences between modes survived it intact
# (the message window's skin still drew over a black map). The absolute half
# alone would not catch a window that stops drawing while the map still does.
# Verified rather than assumed: rebuilding with the M6.3e fix reverted, every
# `mz_boot_check.bash` mode still reports OK, and this script fails on the play
# frame's dominant colour (99.5%) and the message band's colour count (18).
#
# The thresholds come from measured runs of data/mz-sample and sit an order of
# magnitude clear of the values they reject, so they are bounds on a nearly
# binary signal rather than tuned tolerances. One assumption is specific to that
# bed and is noted at the constant: its map is one screen wide, so it does not
# scroll between captures.
#
# This file used to carry a second bed-specific assumption — that the battle
# frame is legitimately near-black, the sample shipping no battler art — and it
# was wrong. The battle scene was throwing an exception every frame (ADR 0004
# M6.3i), and the exemption written around the symptom was what let it keep
# doing so. Its removal is the general lesson: an exemption written to
# accommodate a frame nobody understood is a place for a bug to live.
#
# Modes whose frame is absent are skipped, so this is useful after a single
# mode's run as well as after all of them. With no frames at all it skips rather
# than fails, the way the boot check skips a missing engine.
#
# Usage: ruby scripts/mz_frame_check.rb [ss_dir]        (default: ss)
#        ruby scripts/mz_frame_check.rb --frame <png>   (one frame, no compare)

require 'zlib'

# -- a small PNG reader -------------------------------------------------------
#
# Only the subset stb_image_write emits (mruby-mvjs/src/mvjs.cxx writes the
# screenshots through it): 8 bits per channel, RGB or RGBA, non-interlaced,
# zlib-deflated, with any of the five per-row filters — stb picks among them per
# row. Anything else raises rather than guessing.
class Frame
  attr_reader :path, :width, :height, :channels, :pixels

  def initialize(path)
    @path = path
    data = File.binread(path)
    raise 'not a PNG' unless data[0, 8] == "\x89PNG\r\n\x1a\n".b

    idat = ''.b
    bit_depth = colour_type = nil
    pos = 8
    while pos + 8 <= data.bytesize
      length = data[pos, 4].unpack1('N')
      type = data[pos + 4, 4]
      body = data[pos + 8, length]
      raise "truncated #{type} chunk" if body.nil? || body.bytesize < length

      case type
      when 'IHDR'
        @width, @height, bit_depth, colour_type, _, _, interlace =
          body.unpack('NNCCCCC')
        raise 'interlaced PNGs are not supported' unless interlace.zero?
      when 'IDAT' then idat << body
      when 'IEND' then break
      end
      pos += 12 + length
    end

    unless bit_depth == 8 && [2, 6].include?(colour_type)
      raise "#{bit_depth}-bit colour type #{colour_type} is not supported"
    end
    raise 'no image data' if idat.empty?

    @channels = colour_type == 6 ? 4 : 3
    @pixels = unfilter(Zlib::Inflate.inflate(idat))
  end

  # RGB at (x, y) as a 3-byte string. Alpha is ignored: these are opaque
  # presented frames, and comparing colour alone keeps a frame captured as RGB
  # comparable with one captured as RGBA.
  def rgb(x, y)
    @pixels.byteslice((y * @width + x) * @channels, 3)
  end

  def size
    [@width, @height]
  end

  # Colour census of rows [y0, y1): [number of distinct colours, percentage of
  # those pixels that are the single most common colour].
  def census(y0 = 0, y1 = @height)
    counts = Hash.new(0)
    (y0...y1).each do |y|
      (0...@width).each { |x| counts[rgb(x, y)] += 1 }
    end
    total = (y1 - y0) * @width
    return [0, 0.0] if total.zero?

    [counts.size, 100.0 * counts.values.max / total]
  end

  # Percentage of pixels in rows [y0, y1) whose colour differs from `other`'s.
  def band_change(other, y0, y1)
    box_change(other, 0, y0, @width, y1)
  end

  # The same, over an arbitrary rectangle — for things that occupy a part of the
  # screen rather than a full-width strip.
  def box_change(other, x0, y0, x1, y1)
    changed = 0
    total = 0
    (y0...y1).each do |y|
      (x0...x1).each do |x|
        total += 1
        changed += 1 if rgb(x, y) != other.rgb(x, y)
      end
    end
    total.zero? ? 0.0 : 100.0 * changed / total
  end

  private

  def unfilter(raw)
    bpp = @channels
    stride = @width * bpp
    out = ''.b
    prev = "\0".b * stride
    off = 0
    @height.times do |row|
      filter = raw.getbyte(off)
      raise "the image ends after #{row} of #{@height} rows" if filter.nil?

      off += 1
      line = raw.byteslice(off, stride)
      raise "row #{row} is short" if line.nil? || line.bytesize < stride

      off += stride
      b = line.bytes
      case filter
      when 0 then nil
      when 1 then (bpp...stride).each { |i| b[i] = (b[i] + b[i - bpp]) & 0xff }
      when 2 then (0...stride).each { |i| b[i] = (b[i] + prev.getbyte(i)) & 0xff }
      when 3
        (0...stride).each do |i|
          left = i >= bpp ? b[i - bpp] : 0
          b[i] = (b[i] + ((left + prev.getbyte(i)) >> 1)) & 0xff
        end
      when 4
        (0...stride).each do |i|
          a = i >= bpp ? b[i - bpp] : 0
          up = prev.getbyte(i)
          c = i >= bpp ? prev.getbyte(i - bpp) : 0
          p = a + up - c
          pa = (p - a).abs
          pb = (p - up).abs
          pc = (p - c).abs
          pred = pa <= pb && pa <= pc ? a : (pb <= pc ? up : c)
          b[i] = (b[i] + pred) & 0xff
        end
      else raise "unknown row filter #{filter}"
      end
      line = b.pack('C*')
      out << line
      prev = line
    end
    out
  end
end

# -- thresholds (all measured on data/mz-sample) ------------------------------

# A frame of one colour is a dead renderer. A floor, not the load-bearing check:
# the M6.3e frames had a sprite and a button in them and clear it easily.
MIN_COLOURS = 2

# A frame that still has its scene is a mix of art; one that lost it is the
# clear colour with a few sprites on top. Measured: 68.5% for the fixed play
# frame, 99.5% with the M6.3e fix reverted.
#
# This used to exempt `battle`, on the reading that its 82.1% near-black frame
# was what a bed shipping no battler art looks like. That reading was wrong:
# the scene was throwing every frame (ADR 0004 M6.3i — an enemy with an empty
# `battlerName` leaves `Sprite_Enemy`'s bitmap undefined and `updateFrame`
# reads `.width` off it), so the frame was dark because nothing after the
# exception ran. With the bed fixed the battle frame is 57.7% dominant across
# 101 colours, and it takes the same check as every other mode. An exemption
# written to accommodate a broken frame is an exemption that hides it.
MAP_DOMINANT_MAX = 90.0

# The message window covers roughly the bottom quarter of the screen: four lines
# of text and its frame.
MESSAGE_BAND_TOP = 0.75
# Antialiased glyphs scatter dozens of intermediate colours through that band;
# a window skin on its own is a short gradient. Measured: 105 colours with the
# contents uploading, 18 without.
MESSAGE_BAND_COLOURS_MIN = 40
# How much of the band must differ from the plain map frame. Measured: 93.0%.
MESSAGE_BAND_MIN = 40.0
# Everything above the halfway line is map in both frames. Measured: 0.3%. The
# allowance is what a scrolled map would cost; the sample's map is one screen
# wide, so it does not scroll, and this stays near zero. On a bed whose map
# scrolls between the two captures this is the assertion that would need
# rethinking — its job is to prove the change was *the window* and not the whole
# frame moving for an unrelated reason.
MESSAGE_OUTSIDE_MAX = 25.0

# A scene change repaints everything. Measured: 100.0% for both menu and battle.
SCENE_CHANGE_MIN = 50.0

# The animation plays centred on the player, who stands mid-screen, so the burst
# lands inside the middle 30% of each axis. Measured: 36.2% of that box changes
# (a disc of radius 72 in it), and it is the same 36.2% run after run because
# the bed's cells are equal-area — see gen-mz-sample.py's gen_animation.
ANIM_BOX_MIN_F = 0.35
ANIM_BOX_MAX_F = 0.65
ANIM_BOX_MIN = 15.0
# Nothing the animation does may reach the left quarter of the screen. Measured:
# 0.0%. This is what separates "the burst drew" from "the frame changed" — a
# screen flash, a scrolled map or a scene swap would move this too.
ANIM_OUTSIDE_MAX = 5.0

# The save probe re-enters the map the way Scene_Load does, so its frame is the
# map again. Measured: 0.2% (the player stands where the move probe left it).
SAVE_CHANGE_MAX = 15.0

# Every mode's frame must carry its scene's art, so MAP_DOMINANT_MAX applies to
# all of them — `menu` included, which draws its windows over a blurred
# snapshot of the map, and both battle modes, which draw a battler and the
# status window over the battleback.
MODES = %w[play message menu save battle battle_play animation].freeze

$failures = 0
$checks = 0

def check(name)
  $checks += 1
  yield
  puts "  ok   #{name}"
rescue StandardError => e
  $failures += 1
  warn "  FAIL #{name}: #{e.message}"
end

def expect(cond, msg)
  raise msg unless cond
end

def load_frame(path)
  Frame.new(path)
rescue StandardError => e
  raise "#{File.basename(path)}: #{e.message}"
end

# -- per-frame checks ---------------------------------------------------------

def check_frame(frame, label, reference_size, map_scene)
  check "#{label}: is a readable frame" do
    expect(frame.width.positive? && frame.height.positive?,
           "#{frame.width}x#{frame.height} is not a picture")
    expect(frame.size == reference_size,
           "#{frame.width}x#{frame.height}, but the other frames are " \
           "#{reference_size.join('x')} — the frames are not comparable")
  end

  colours, dominant = frame.census
  check "#{label}: is not a flat fill" do
    expect(colours >= MIN_COLOURS,
           "the whole frame is one colour — nothing was drawn, or the " \
           'presented buffer never reached the screenshot')
  end

  return unless map_scene

  check "#{label}: the scene's art reached the frame" do
    expect(dominant <= MAP_DOMINANT_MAX,
           format('%.1f%% of the frame is a single colour (allow <= %.1f%%) — ' \
                  'the scene reported itself drawn but its tiles are missing ' \
                  'from the frame', dominant, MAP_DOMINANT_MAX))
    puts format('       %d colours, %.1f%% dominant', colours, dominant)
  end
end

# -- entry point --------------------------------------------------------------

if ARGV.first == '--frame'
  path = ARGV[1]
  abort "usage: #{$PROGRAM_NAME} --frame <png>" if path.nil?
  unless File.file?(path)
    puts "skip: #{path} was not captured"
    exit 0
  end

  puts "== #{path}"
  name = File.basename(path, '.png')
  frame = load_frame(path)
  check_frame(frame, name, frame.size, true)
  puts format('%d checks, %d failures', $checks, $failures)
  exit($failures.zero? ? 0 : 1)
end

dir = ARGV[0] || 'ss'
paths = {}
MODES.each do |mode|
  path = File.join(dir, "mz_#{mode}.png")
  paths[mode] = path if File.file?(path)
end

if paths.empty?
  puts "skip #{dir}: no mz_*.png frames were captured " \
       '(run scripts/mz_boot_check.bash first)'
  exit 0
end

puts "== #{dir} (#{paths.keys.join(', ')})"

loaded = {}
paths.each do |mode, path|
  loaded[mode] = load_frame(path)
rescue StandardError => e
  $checks += 1
  $failures += 1
  warn "  FAIL #{mode}: #{e.message}"
end

reference_size = loaded.values.first&.size
loaded.each { |mode, frame| check_frame(frame, mode, reference_size, true) }

if (message = loaded['message'])
  band_top = (message.height * MESSAGE_BAND_TOP).to_i
  check 'message: the window has text in it' do
    colours, = message.census(band_top, message.height)
    expect(colours >= MESSAGE_BAND_COLOURS_MIN,
           format('the message band has %d distinct colours (need >= %d) — ' \
                  "the window's frame drew but its contents (the text) never " \
                  'reached the texture', colours, MESSAGE_BAND_COLOURS_MIN))
    puts format('       %d colours in the message band', colours)
  end
end

play = loaded['play']
if play.nil?
  puts '  note: no play frame, so the cross-frame checks are skipped ' \
       '(they all compare against the plain map)'
else
  height = play.height

  if (message = loaded['message'])
    check 'message: a window drew over the map, and only over the map' do
      inside = message.band_change(play, (height * MESSAGE_BAND_TOP).to_i, height)
      outside = message.band_change(play, 0, height / 2)
      expect(inside >= MESSAGE_BAND_MIN,
             format('the bottom band is %.1f%% different from the plain map ' \
                    '(need >= %.1f%%) — Window_Message reported itself open ' \
                    'but never reached the frame', inside, MESSAGE_BAND_MIN))
      expect(outside <= MESSAGE_OUTSIDE_MAX,
             format('the top half changed %.1f%% too (allow <= %.1f%%) — the ' \
                    'whole frame moved, so the bottom band proves nothing ' \
                    'about the message window', outside, MESSAGE_OUTSIDE_MAX))
      puts format('       bottom %.1f%% changed, outside %.1f%%', inside, outside)
    end
  end

  { 'menu' => 'Scene_Menu', 'battle' => 'Scene_Battle',
    'battle_play' => 'Scene_Battle' }.each do |mode, scene|
    next unless (frame = loaded[mode])

    check "#{mode}: #{scene} repainted the screen" do
      changed = frame.band_change(play, 0, height)
      expect(changed >= SCENE_CHANGE_MIN,
             format('only %.1f%% of the frame differs from the map ' \
                    '(need >= %.1f%%) — %s was entered but the map is still ' \
                    'what is on screen', changed, SCENE_CHANGE_MIN, scene))
      puts format('       %.1f%% changed', changed)
    end
  end

  if (anim = loaded['animation'])
    check 'animation: the burst drew on the player, and nowhere else' do
      x0 = (anim.width * ANIM_BOX_MIN_F).to_i
      x1 = (anim.width * ANIM_BOX_MAX_F).to_i
      y0 = (height * ANIM_BOX_MIN_F).to_i
      y1 = (height * ANIM_BOX_MAX_F).to_i
      inside = anim.box_change(play, x0, y0, x1, y1)
      outside = anim.box_change(play, 0, 0, anim.width / 4, height)
      expect(inside >= ANIM_BOX_MIN,
             format('the middle of the frame is %.1f%% different from the ' \
                    'plain map (need >= %.1f%%) — the animation reported its ' \
                    'cells drawing but they are not in the picture',
                    inside, ANIM_BOX_MIN))
      expect(outside <= ANIM_OUTSIDE_MAX,
             format('the left quarter changed %.1f%% too (allow <= %.1f%%) — ' \
                    'something moved the whole frame, so the middle proves ' \
                    'nothing about the animation', outside, ANIM_OUTSIDE_MAX))
      puts format('       centre %.1f%% changed, outside %.1f%%', inside, outside)
    end
  end

  if (save = loaded['save'])
    check 'save: the round-trip landed back on an intact map' do
      changed = save.band_change(play, 0, height)
      expect(changed <= SAVE_CHANGE_MAX,
             format('%.1f%% of the frame differs from the plain map ' \
                    '(allow <= %.1f%%) — the save/load round-trip left ' \
                    'something other than the map on screen',
                    changed, SAVE_CHANGE_MAX))
      puts format('       %.1f%% changed', changed)
    end
  end
end

puts format('%d checks, %d failures', $checks, $failures)
exit($failures.zero? ? 0 : 1)

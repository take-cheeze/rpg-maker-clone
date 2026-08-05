module RGSS
  class Timeout < StandardError; end

  # Emit a warning the first time an unimplemented stub method is called.
  # Warning on every call would flood the log from within the game loop, so
  # each method name is reported only once.
  @warned_stubs = {}
  def self.warn_stub(name)
    return if @warned_stubs[name]
    @warned_stubs[name] = true
    $stderr.puts "[RGSS] #{name} is not implemented yet (stub, does nothing)"
  end

  # Color, Rect, Table and Tone are implemented in C (see src/lib.cxx).

  # The game's encrypted archive, for assets that are not on disk.
  #
  # A released RPG Maker game ships one Game.rgssad / .rgss2a / .rgss3a holding
  # its whole tree — Data/ *and* Graphics/ and Audio/ — with nothing loose. The
  # data layers open the archive themselves to read Data/, but assets are asked
  # for by name from anywhere (`Cache.tileset(n)` -> `Bitmap.new("Graphics/...")`
  # deep inside a game's own scripts), with no handle to thread through. So each
  # maker's boot shell registers its archive here once and the loaders consult
  # it after a loose file misses — loose shadows packed, as in RGSS.
  #
  # Anything answering `read(name) -> String or nil` will do; in practice it is
  # an RPGXP::RGSSAD. nil means an unpacked project.
  class << self
    attr_accessor :asset_archive
  end

  # The mean R/G/B of the rendered frame, sampled on an 8px grid (a full
  # per-pixel walk through get_pixel would take seconds). nil when the backend
  # cannot snapshot. This is the measurement ADR 0021 used to prove the RPG2000
  # fade reached the display, available to any caller now that
  # Graphics.snap_to_bitmap exists.
  def self.frame_mean
    bmp = Graphics.snap_to_bitmap
    return nil if bmp.nil?
    r = 0
    g = 0
    b = 0
    n = 0
    y = 0
    while y < bmp.height
      x = 0
      while x < bmp.width
        c = bmp.get_pixel(x, y)
        r += c.red.to_i
        g += c.green.to_i
        b += c.blue.to_i
        n += 1
        x += 8
      end
      y += 8
    end
    bmp.dispose
    return nil if n.zero?
    [r / n, g / n, b / n]
  end

  # Prove the viewport screen effects actually reach the display.
  #
  # Every effect below is native rendering that no unit test can see: the test
  # binary has no display, so a Viewport cannot even be constructed there. The
  # failure mode that leaves is the dangerous one — the code runs, the values are
  # stored, and the screen never changes (exactly what happened to an earlier
  # RPG2000 screen-tint attempt, see docs/TODO.md). So this drives the real
  # renderer on a real display and *measures* the frame: grey screen, then a red
  # colour overlay, then an additive-blue tone, each against the last, and
  # finally a freeze/transition round trip.
  #
  # Run by `rpg_maker_clone --rgss_effect_probe` (under xvfb in CI). Returns true
  # when every effect moved the pixels it should.
  def self.effect_probe
    # Take the screen size from a snapshot rather than Graphics.width/height:
    # those are the values a game's resize_screen set, and there is no game here
    # — the sprite has to cover what is actually on the display. Doubles as the
    # check that this backend can snapshot at all.
    shape = Graphics.snap_to_bitmap
    if shape.nil?
      $stderr.puts "[RGSS-PROBE] snap_to_bitmap unavailable on this backend"
      return false
    end
    w = shape.width
    h = shape.height
    shape.dispose

    viewport = Viewport.new(0, 0, w, h)
    bitmap = Bitmap.new(w, h)
    bitmap.fill_rect(0, 0, w, h, Color.new(128, 128, 128, 255))
    sprite = Sprite.new(viewport)
    sprite.bitmap = bitmap
    Graphics.update
    base = frame_mean

    viewport.color = Color.new(255, 0, 0, 128)
    viewport.update
    Graphics.update
    colored = frame_mean

    viewport.color = Color.new(0, 0, 0, 0)
    viewport.tone = Tone.new(0, 0, 255, 0)
    viewport.update
    Graphics.update
    toned = frame_mean

    viewport.tone = Tone.new(0, 0, 0, 0)
    viewport.update

    # The scene change: freeze the grey screen, then take the scene away — as a
    # game does when it swaps scenes — and dissolve. `cleared` is the empty
    # screen the dissolve runs over, `mid` is a frame from inside it (sampled by
    # the hook below, since transition blocks until it is done) and `after` is
    # where it ended. Between them they pin down both halves: the frozen still
    # really goes up over the new scene, and it really comes down again.
    Graphics.freeze
    sprite.visible = false
    Graphics.update
    cleared = frame_mean

    $rgss_probe_mid = nil
    class << Graphics
      alias_method :_probe_update, :update
      def update
        _probe_update
        $rgss_probe_mid = RGSS.frame_mean if $rgss_probe_mid.nil?
      end
    end
    Graphics.transition(4)
    class << Graphics
      alias_method :update, :_probe_update
    end
    mid = $rgss_probe_mid
    after = frame_mean

    $stderr.puts "[RGSS-PROBE] base=#{base.inspect} color=#{colored.inspect} " \
                 "tone=#{toned.inspect} cleared=#{cleared.inspect} " \
                 "mid=#{mid.inspect} after=#{after.inspect}"

    ok = true
    # A half-opaque red overlay pushes red up and the other channels down.
    unless colored[0] > base[0] + 20 && colored[2] < base[2] - 20
      $stderr.puts "[RGSS-PROBE] FAIL Viewport#color did not tint the frame"
      ok = false
    end
    # An additive blue tone pushes blue up and leaves red alone.
    unless toned[2] > base[2] + 20
      $stderr.puts "[RGSS-PROBE] FAIL Viewport#tone did not tint the frame"
      ok = false
    end
    if (cleared[0] - base[0]).abs < 20
      $stderr.puts "[RGSS-PROBE] FAIL hiding the sprite did not change the frame"
      ok = false
    else
      # Mid-dissolve the still is partly transparent, so the frame sits between
      # the frozen screen and the scene behind it.
      unless mid && (mid[0] - cleared[0]).abs > 20 && (mid[0] - base[0]).abs > 8
        $stderr.puts "[RGSS-PROBE] FAIL Graphics.transition did not show the " \
                     "frozen screen"
        ok = false
      end
      if (after[0] - cleared[0]).abs > 8
        $stderr.puts "[RGSS-PROBE] FAIL Graphics.transition left the frozen " \
                     "screen up"
        ok = false
      end
    end
    sprite.dispose
    bitmap.dispose
    viewport.dispose
    ok = false unless window_probe
    $stderr.puts "[RGSS-PROBE] #{ok ? "ok" : "failed"}"
    ok
  end

  # Prove RGSS::Window is the native widget and that it draws.
  #
  # This exists because it silently was not. Every maker gem reopens the shared
  # RGSS namespace and loads after mruby-rgss, so a class one of them defines
  # under RGSS replaces this one for the whole process — which is what RPG2000's
  # window did, leaving `Window.new` returning an object with no LVGL object
  # behind it and `window_refresh` returning early forever. Nothing in-tree
  # noticed, because nothing in-tree constructs an RGSS::Window: only a real
  # XP/VX game's own scripts do (`Window_Base < Window`), through the script
  # host.
  #
  # So: build one on an empty screen with a solid-blue background tile in its
  # skin, and require that it is alive and that it covers the area it should.
  def self.window_probe
    skin = Bitmap.new(192, 128)
    # The windowskin layout the native drawing reads: background tile at
    # (0,0,128,128), frame at (128,0,64,64). Only the background is filled, so
    # the frame contributes nothing and the measurement is pure area.
    skin.fill_rect(0, 0, 128, 128, Color.new(0, 0, 255, 255))

    win = Window.new(0, 0, 320, 240)
    alive = !win.disposed?
    win.windowskin = skin
    Graphics.update
    drawn = frame_mean

    $stderr.puts "[RGSS-PROBE] window alive=#{alive} drawn=#{drawn.inspect}"

    ok = true
    unless alive
      $stderr.puts "[RGSS-PROBE] FAIL Window.new produced no native object — " \
                   "RGSS::Window has been replaced by another gem's class"
      ok = false
    end
    unless drawn[2] > 20
      $stderr.puts "[RGSS-PROBE] FAIL the window did not draw"
      ok = false
    end
    win.dispose
    skin.dispose
    ok
  end

  # A 16-bit mono PCM WAV of `ms` milliseconds of a quiet square wave, built
  # here so the audio probe below needs no fixture on disk. Long enough that a
  # few frames of playback land inside it.
  def self.probe_wav(ms = 2000)
    rate = 11025
    samples = rate * ms / 1000
    pcm = []
    i = 0
    while i < samples
      # ~440Hz at a low amplitude; the dummy audio driver discards it anyway,
      # but a real device should not be handed a full-scale tone.
      pcm << (((i * 2 / (rate / 440)) % 2).zero? ? 2000 : -2000)
      i += 1
    end
    data = pcm.pack("s<*")
    header = ["RIFF"].pack("a4") + [36 + data.bytesize].pack("V") +
             ["WAVEfmt "].pack("a8") + [16].pack("V") +
             [1, 1].pack("v2") + [rate, rate * 2].pack("V2") +
             [2, 16].pack("v2") + ["data"].pack("a4") + [data.bytesize].pack("V")
    header + data
  end

  # Prove audio packed into an encrypted archive actually reaches the mixer.
  #
  # Like the render probe above, this exists because the interesting half is
  # native and invisible to `mruby-rgss/test`: that binary installs no audio
  # backend, so every Audio call there is a no-op and a broken memory path would
  # look exactly like a working one. Here the real SDL_mixer backend runs (under
  # SDL_AUDIODRIVER=dummy in CI, which decodes and mixes with no sound card).
  #
  # It is an A/B/A. The same sound is played first from a loose file, then
  # stopped, then played out of an archive:
  #
  #   loose   > 0   the observable works at all (an SDL_mixer older than 2.6
  #                 cannot report a position, and would make everything below
  #                 look like a failure to play rather than passing vacuously)
  #   stopped = 0   nothing is playing between the arms
  #   packed  > 0   the archived sound really started
  #
  # The middle step is the one that earns the others. Without it the packed arm
  # passes against an *empty* archive, because the position it reads is the
  # loose track's — measured, not assumed: that is exactly what this probe did
  # before Audio.bgm_pos learned to check Mix_PlayingMusic().
  #
  # Run by `rpg_maker_clone --rgss_audio_probe`. Returns true when both play.
  def self.audio_probe
    wav = probe_wav
    ok = true

    path = "rgss-audio-probe.wav"
    File.open(path, "wb") { |io| io.write(wav) }
    Audio.bgm_play(path)
    loose = wait_for_bgm_pos
    Audio.bgm_stop
    Graphics.update
    stopped = Audio.bgm_pos
    File.delete(path) if File.exist?(path)

    archive = Object.new
    entries = { "Audio/BGM/Probe.wav" => wav, "Audio/SE/Beep.wav" => wav }
    archive.instance_variable_set(:@entries, entries)
    def archive.read(name)
      @entries[name]
    end
    previous = asset_archive
    self.asset_archive = archive
    begin
      # The name a game uses: no folder, no extension. Finding it means the
      # candidate crossing in Audio.play_packed works, not just the decoder.
      Audio.bgm_play("Probe")
      packed = wait_for_bgm_pos
      Audio.se_play("Beep")
      Audio.bgm_stop
    ensure
      self.asset_archive = previous
    end

    $stderr.puts "[RGSS-AUDIO] loose=#{loose} stopped=#{stopped} " \
                 "packed=#{packed}"
    if loose.zero?
      $stderr.puts "[RGSS-AUDIO] FAIL a loose file did not play (no audio " \
                   "device, or this SDL_mixer cannot report a position) — the " \
                   "packed result proves nothing either way"
      ok = false
    elsif !stopped.zero?
      $stderr.puts "[RGSS-AUDIO] FAIL bgm_pos still reports #{stopped} after " \
                   "bgm_stop, so it cannot tell the two arms apart"
      ok = false
    elsif packed.zero?
      $stderr.puts "[RGSS-AUDIO] FAIL archived BGM did not reach the mixer"
      ok = false
    end
    $stderr.puts "[RGSS-AUDIO] #{ok ? "ok" : "failed"}"
    ok
  end

  # Run frames until the BGM reports a position, and answer it (0 if it never
  # does). Frames, not sleeps: Graphics.update is what drives the audio
  # backend's per-frame work.
  def self.wait_for_bgm_pos(frames = 120)
    n = 0
    while n < frames
      Graphics.update
      pos = Audio.bgm_pos
      return pos if pos > 0
      n += 1
    end
    0
  end

  class Bitmap
    # RGSS resolves a bare asset name against several image formats, and the RPG
    # Maker XP RTP genuinely mixes them: its windowskins and charsets are .png
    # while its title backgrounds are .jpg, so a png-only search left every XP
    # title screen on the fallback background (found by
    # scripts/compare-rpgxp-wine.bash). stb decodes JPEG, so both spellings of
    # the extension are just more candidates.
    EXTENSIONS = [:png, :jpg, :jpeg, :xyz, :bmp].freeze

    def initialize f, s = nil
      if f.kind_of? String
        i = self._init_file(f, s)
        [GAME_DIR, RTP_DIR].each do |d|
          next if d.nil? || d.empty?
          i = self._init_file("#{d}/#{f}", s) unless i
          EXTENSIONS.each do |ext|
            i = self._init_file("#{d}/#{f}.#{ext}", s) unless i
          end
        end
        # A released game packs its whole Graphics/ tree into the encrypted
        # archive with nothing loose on disk, so try that last — loose files
        # shadow the archive, which is what RGSS itself does.
        i = init_from_archive(f, s) unless i
        # Surface the decoder's own reason (e.g. an XYZ "bad dist" zlib error)
        # so failures are diagnosable instead of a bare "Failed to init bitmap".
        unless i
          detail = Bitmap._load_error
          detail = Bitmap._stbi_error if detail.nil? || detail.empty?
          detail = detail.nil? || detail.empty? ? "" : " (#{detail})"
          raise "Failed to init bitmap: #{f}#{detail}"
        end
      else
        self._init_size(f, s)
      end
    end

    # Font used by #draw_text. Created lazily from the current defaults.
    def font
      @font ||= Font.new
    end

    def font=(f)
      @font = f
    end

    private

    # Decode `f` out of the game's encrypted archive, if one is registered (see
    # RGSS.asset_archive). Entry names are project-relative with the extension
    # spelled out, so the same candidate list the loose-file search uses applies
    # here — the archive itself normalises the '/' separators.
    #
    # Best effort: a broken archive must not take down a Bitmap.new that would
    # otherwise raise its own diagnostic, so the read failure is logged and
    # treated as a miss.
    def init_from_archive(f, s)
      archive = RGSS.asset_archive
      return nil if archive.nil?
      bytes = archive.read(f)
      if bytes.nil?
        EXTENSIONS.each do |ext|
          bytes = archive.read("#{f}.#{ext}")
          break if bytes
        end
      end
      return nil if bytes.nil?
      self._init_memory(bytes, s)
    rescue StandardError => e
      $stderr.puts "[RGSS] archive read failed for #{f}: #{e.message}"
      nil
    end
  end

  # RGSS Font. Bitmap#draw_text rasterises with the game's TrueType font (found
  # under the project's Fonts/ folder, selected by #name and sized by #size,
  # honouring bold/italic/outline/shadow and the colours) and falls back to the
  # built-in shinonome bitmap font when no font file is available. Only the
  # attributes scripts read/write are modelled here.
  class Font
    @default_name = "Arial"
    @default_size = 22
    @default_bold = false
    @default_italic = false
    @default_shadow = false
    @default_outline = true
    @default_color = Color.new(255, 255, 255, 255)
    @default_out_color = Color.new(0, 0, 0, 128)

    class << self
      attr_accessor :default_name, :default_size, :default_bold,
                    :default_italic, :default_shadow, :default_outline,
                    :default_color, :default_out_color

      def exist?(name)
        true
      end
    end

    attr_accessor :name, :size, :bold, :italic, :outline, :shadow,
                  :color, :out_color

    def initialize(name = Font.default_name, size = Font.default_size)
      @name = name
      @size = size
      @bold = Font.default_bold
      @italic = Font.default_italic
      @shadow = Font.default_shadow
      @outline = Font.default_outline
      c = Font.default_color
      @color = Color.new(c.red, c.green, c.blue, c.alpha)
      oc = Font.default_out_color
      @out_color = Color.new(oc.red, oc.green, oc.blue, oc.alpha)
    end
  end

  # RGSS Plane: a tiling, scrolling full-viewport bitmap (map parallax / fog).
  # The tiling render is native (src/lib.cxx creates an lv_canvas the size of the
  # viewport and fills it by tiling the bitmap with the ox/oy scroll — see
  # plane_init/plane_retile); `initialize`, `bitmap=`, `ox=`, `oy=`, `opacity=`,
  # `z=`, `visible`/`visible=`, `dispose`/`disposed?` are all native. This
  # reopening adds the plain readers plus the properties the native renderer does
  # not yet honour visually (zoom, blend mode, tone, colour) — stored so scripts
  # that set them run (tracked in docs/rpgxp-rgss-api-gap.md).
  class Plane
    attr_reader :bitmap, :ox, :oy, :z, :viewport
    # `opacity=`, `tone=`, `color=`, `blend_type=` and `zoom_x=`/`zoom_y=` are all
    # native (src/lib.cxx): opacity/blend map onto the plane canvas's LVGL object,
    # and tone/colour/zoom are baked into the tiled buffer by plane_retile (zoom
    # samples the source at the reciprocal rate). The readers below return the set
    # values; native #initialize does not set these ivars, so they fall back to
    # RGSS defaults here.

    def opacity
      @opacity.nil? ? 255 : @opacity
    end

    def zoom_x
      @zoom_x.nil? ? 1.0 : @zoom_x
    end

    def zoom_y
      @zoom_y.nil? ? 1.0 : @zoom_y
    end

    def blend_type
      @blend_type || 0
    end

    def tone
      @tone ||= Tone.new(0, 0, 0, 0)
    end

    def color
      @color ||= Color.new(0, 0, 0, 0)
    end
  end

  class Sprite
    attr_reader :bitmap
    attr_reader :x, :y, :z

    # RGSS Sprite properties the stock scripts set — opacity fades, zoom, angle,
    # tone/colour, scroll origin, mirror, bush depth, blend mode, source rect,
    # flash. `opacity=`, `zoom_x=`, `zoom_y=`, `angle=`, `mirror=`, `tone=`,
    # `color=`, `src_rect=`, `blend_type=`, `bush_depth=` and `flash` are all now
    # honoured natively (src/lib.cxx sets the sprite canvas's LVGL object opacity /
    # image scale / image rotation / blend mode; mirror, tone, colour, the src_rect
    # crop, the bush-depth bottom fade and the timed flash pulse are baked into a
    # scratch copy the canvas points at, and `update` re-composites so per-frame
    # `src_rect.set` shows and an active flash decays). `bush_depth=` and `flash`
    # are native methods, so they must NOT be redefined by an `attr_writer` here —
    # that would shadow them. Only `ox`/`oy` (read by the native tone/flash pass
    # but not otherwise wired) stay Ruby-side. The readers below fall back to
    # RGSS's defaults because the native #initialize does not set these ivars (and
    # cannot be wrapped from here without replacing it). `nil?` checks — not `||` —
    # where 0/false is a meaningful value (opacity 0 = transparent).
    attr_writer :ox, :oy

    def opacity
      @opacity.nil? ? 255 : @opacity
    end

    def ox
      @ox || 0
    end

    def oy
      @oy || 0
    end

    def zoom_x
      @zoom_x.nil? ? 1.0 : @zoom_x
    end

    def zoom_y
      @zoom_y.nil? ? 1.0 : @zoom_y
    end

    def angle
      @angle || 0
    end

    def mirror
      @mirror || false
    end

    def bush_depth
      @bush_depth || 0
    end

    def blend_type
      @blend_type || 0
    end

    def tone
      @tone ||= Tone.new(0, 0, 0, 0)
    end

    def color
      @color ||= Color.new(0, 0, 0, 0)
    end

    def src_rect
      @src_rect ||= Rect.new(0, 0, 0, 0)
    end
  end

  # RGSS Tilemap: the layered, autotiled map ground Spriteset_Map builds from the
  # tileset, the seven autotiles, and the map's data/priority Tables. Now native
  # (src/lib.cxx): Tilemap.new builds an lv_canvas the size of the viewport and
  # tilemap_refresh draws the visible tiles of the three map_data layers scrolled
  # by ox/oy — regular tiles from the tileset and autotiles assembled from their
  # four quads (the seven `autotiles` bitmaps are read by the native renderer).
  # `initialize`, `tileset=`, `map_data=`, `priorities=`, `ox=`/`oy=`, `z=`,
  # `update`, `visible`/`visible=`, `dispose`/`disposed?` are native. `update`
  # advances the autotile animation (frames cycle through the wider autotile
  # bitmaps). `priorities=` routes priority >= 1 tiles to a separate "above" layer
  # that sorts over the characters (an interim flat approximation of RMXP's
  # per-row priority — see docs/adr/0022-rpgxp-tilemap-priority-layering.md). This
  # reopening keeps the plain readers, the `autotiles` slot array (which the
  # native renderer reads), and `flash_data` — still stored-only — so scripts run.
  class Tilemap
    attr_reader :tileset, :map_data, :ox, :oy, :viewport, :priorities
    attr_accessor :flash_data

    # RGSS exposes exactly seven autotile slots (0..6); the game assigns each with
    # `tilemap.autotiles[i] = bitmap` and reads them back to dispose. A fixed-size
    # Array holds the references (there is no `autotiles=` in RGSS).
    def autotiles
      @autotiles ||= Array.new(7)
    end

    # RGSS2/RGSS3 (VX, VX Ace) replace the tileset + autotiles with nine sheets
    # (`bitmaps`, native) and the tileset `flags` table. A tilemap that has been
    # given any sheet is drawn the VX way; `flags=` is native (it re-tiles), so
    # this only adds the reader.
    attr_reader :flags
  end

  # RGSS Window: the framed, scrollable box every Window_Base subclass (message,
  # command, menu, shop, battle status) builds on. Now native (src/lib.cxx):
  # Window.new builds an lv_canvas the size of the window and blits the game's
  # `contents` Bitmap into the content area (inset 16px, scrolled by ox/oy) at
  # contents_opacity, and — when a `windowskin` is set — draws the stretched
  # background at `back_opacity`, the 9-slice frame at `opacity`, the blinking
  # cursor highlight at `cursor_rect` (when `active`) and the pause arrow (when
  # `pause`). `update` advances the blink/pause animation and redraws. Almost the
  # whole surface is native — `initialize`, `contents=`, `windowskin=`, `x=`,
  # `y=`, `width=`, `height=`, `ox=`, `oy=`, `opacity=`, `back_opacity=`,
  # `contents_opacity=`, `cursor_rect=`, `active=`, `pause=`, `stretch=`,
  # `update`, `z=`, `visible`/`visible=`, `dispose`/`disposed?`. `stretch=` picks
  # between the stretched (default) and tiled windowskin background. This reopening
  # only adds the plain readers and their RGSS defaults.
  class Window
    attr_reader :contents, :windowskin, :x, :y, :width, :height, :ox, :oy, :z,
                :viewport, :contents_opacity

    def opacity
      @opacity.nil? ? 255 : @opacity
    end

    def back_opacity
      @back_opacity.nil? ? 255 : @back_opacity
    end

    def cursor_rect
      @cursor_rect ||= Rect.new(0, 0, 0, 0)
    end

    def active
      @active.nil? ? true : @active
    end

    def pause
      @pause || false
    end

    def stretch
      @stretch.nil? ? true : @stretch
    end

    # ---- RGSS2 / RGSS3 (VX, VX Ace) additions ------------------------------
    #
    # The VX and VX Ace window model adds an open/close animation and a content
    # padding the scripts drive themselves: `Window_Base#open`/`#close` step
    # `openness` by 48 a frame and wait on `open?`/`close?`, and every VX window
    # lays its contents out relative to `padding`. Measured in the stock VX Ace
    # scripts: openness x16, open?/close? x15, padding x8, arrows_visible x1 (see
    # docs/rpgvx-rgss-api-gap.md).
    #
    # These are plain state here: the native window is drawn at full size
    # whatever `openness` says, so the open/close *animation* is not shown yet —
    # but because the scripts only ever wait on the value they set, a window
    # still opens, closes and lays out correctly.

    # 0 (fully closed) .. 255 (fully open).
    def openness
      @openness.nil? ? 255 : @openness
    end

    def openness=(value)
      value = 0 if value < 0
      value = 255 if value > 255
      @openness = value
    end

    def open?
      openness == 255
    end

    def close?
      openness.zero?
    end

    # The margin between the window frame and its contents. RGSS3's default is
    # 12; the native drawing still insets contents by its own border, so this is
    # the value the scripts compute layouts with.
    def padding
      @padding.nil? ? 12 : @padding
    end

    attr_writer :padding

    def padding_bottom
      @padding_bottom.nil? ? padding : @padding_bottom
    end

    attr_writer :padding_bottom

    # Whether the scroll arrows are drawn on a window whose contents overflow.
    def arrows_visible
      @arrows_visible.nil? ? true : @arrows_visible
    end

    attr_writer :arrows_visible

    def tone
      @tone ||= Tone.new(0, 0, 0, 0)
    end

    attr_writer :tone

    # RGSS2/RGSS3 construct a window with its geometry — `Window.new(x, y,
    # width, height)` — where RGSS1 (XP) took an optional viewport and had the
    # geometry assigned afterwards. Every VX/VX Ace window does the former
    # (`Window_Base#initialize` calls `super(x, y, width, height)`), so accept
    # both forms: four numbers are the VX shape, anything else goes to the
    # native initializer unchanged.
    alias_method :_rgss1_initialize, :initialize

    def initialize(x = nil, y = nil, width = nil, height = nil)
      if x.is_a?(Integer) && y.is_a?(Integer)
        _rgss1_initialize
        self.x = x
        self.y = y
        self.width = width.to_i
        self.height = height.to_i
      elsif x.nil?
        _rgss1_initialize
      else
        _rgss1_initialize(x)
      end
    end
  end

  # RGSS Viewport. Native (src/lib.cxx): the clipping frame, its scrolled
  # content layer, `rect`/`ox`/`oy`/`z`/`visible`, and — for the RGSS2/RGSS3
  # screen effects — `color`/`color=` and `flash`, drawn as a colour overlay
  # above the viewport's contents and refreshed from `update`. This reopening
  # only adds the tone.
  class Viewport
    # `tone`/`tone=` are native now too (src/lib.cxx). Unlike `color` — one more
    # layer over the viewport's contents — a tone *rescales what is drawn*
    # (desaturate toward luminance, then offset each channel), so it cannot be an
    # overlay: every display object in the viewport folds the tone into its own
    # composite, and the viewport re-composites them when the value changes
    # (including the in-place `viewport.tone.set(...)` the scripts use, which
    # #update re-reads each frame). Nothing to add here.
  end

  class RGSSError < StandardError
  end

  # RGSS Audio module. The public methods resolve a game-supplied name to a real
  # file (mirroring how Bitmap searches GAME_DIR/RTP_DIR) and hand it to the
  # native SDL_mixer backend defined in src/audio.cxx + src/sdl_audio.cxx. When
  # no backend is installed (the standalone test build, or a build/host without
  # an audio device) the native primitives are graceful no-ops.
  module Audio
    # Sub-folders searched for each kind of audio, relative to GAME_DIR/RTP_DIR.
    # "" lets a name that already carries its folder (or an absolute path)
    # resolve as given. RPG2000 keeps music under Music/ and effects under
    # Sound/; the Audio/* folders cover RPG Maker XP-style layouts.
    MUSIC_DIRS = ["", "Music", "Audio/BGM", "Audio/BGS", "Audio/ME"].freeze
    SOUND_DIRS = ["", "Sound", "Audio/SE"].freeze
    # Tried in order after the name as-is; the data usually omits the extension.
    EXTS = ["", ".ogg", ".wav", ".mid", ".midi", ".mp3", ".flac"].freeze

    # The archive sub-folders each kind of audio lives in, for a packed release.
    # Unlike the disk search these are exact: an archive entry name is whatever
    # the editor wrote, and RGSS2/RGSS3 projects keep the four kinds apart.
    # Ordered so the usual home of each kind is tried first.
    ARCHIVE_DIRS = {
      bgm: ["Audio/BGM", "Audio/ME", "Audio/BGS", "Music", ""],
      bgs: ["Audio/BGS", "Audio/BGM", "Music", ""],
      me: ["Audio/ME", "Audio/BGM", "Music", ""],
      se: ["Audio/SE", "Sound", ""]
    }.freeze

    class << self
      def bgm_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, MUSIC_DIRS)
        return _bgm_play(path, volume, pitch) if path
        play_packed(:bgm, filename, volume, pitch)
      end

      def bgm_stop
        _bgm_stop
      end

      def bgm_fade(time)
        _bgm_fade(time)
      end

      def bgm_pos
        _bgm_pos
      end

      def bgs_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, MUSIC_DIRS)
        return _bgs_play(path, volume, pitch) if path
        play_packed(:bgs, filename, volume, pitch)
      end

      def bgs_stop
        _bgs_stop
      end

      def bgs_fade(time)
        _bgs_fade(time)
      end

      def bgs_pos
        _bgs_pos
      end

      def me_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, MUSIC_DIRS)
        return _me_play(path, volume, pitch) if path
        play_packed(:me, filename, volume, pitch)
      end

      def me_stop
        _me_stop
      end

      def me_fade(time)
        _me_fade(time)
      end

      def se_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, SOUND_DIRS)
        return _se_play(path, volume, pitch) if path
        play_packed(:se, filename, volume, pitch)
      end

      def se_stop
        _se_stop
      end

      # RGSS2+. The VX/VX Ace scripts call it once at boot when the project asks
      # for MIDI playback; SDL_mixer picks its own synth, so there is nothing to
      # set up here.
      def setup_midi
        RGSS.warn_stub("Audio.setup_midi")
      end

      private

      # Play +filename+ out of the game's encrypted archive, if one is
      # registered (see RGSS.asset_archive). A released game packs its whole
      # Audio/ tree in there with nothing loose, so this is the only route to
      # its music; it runs after the disk search misses, so loose files still
      # shadow packed ones as in RGSS.
      #
      # Returns nil either way — RGSS's Audio.*_play has no return value, and a
      # miss here is the same "asset not found" silence the disk path gives.
      def play_packed(kind, filename, volume, pitch)
        archive = RGSS.asset_archive
        return nil if archive.nil? || filename.nil? || filename.empty?
        name, bytes = find_packed(archive, kind, filename)
        return nil if bytes.nil?
        # Say so once rather than dropping every play silently: on a build with
        # no audio backend (or one predating the memory entry points) a packed
        # game would otherwise be mysteriously mute.
        unless _can_play_mem?
          RGSS.warn_stub("Audio: playing from an encrypted archive")
          return nil
        end
        case kind
        when :bgm then _bgm_play_mem(name, bytes, volume, pitch)
        when :bgs then _bgs_play_mem(name, bytes, volume, pitch)
        when :me then _me_play_mem(name, bytes, volume, pitch)
        else _se_play_mem(name, bytes, volume, pitch)
        end
        nil
      end

      # The first archive entry matching +filename+ for +kind+, as
      # [entry name, bytes], or nil. Crosses the kind's folders with the same
      # extensions the disk search uses, because the data usually names a track
      # without either.
      def find_packed(archive, kind, filename)
        ARCHIVE_DIRS[kind].each do |dir|
          base = dir.empty? ? filename : "#{dir}/#{filename}"
          EXTS.each do |ext|
            cand = "#{base}#{ext}"
            bytes = archive.read(cand)
            return [cand, bytes] if bytes
          end
        end
        nil
      rescue StandardError => e
        # A broken archive must not take down a play call; report and stay quiet.
        $stderr.puts "[RGSS] archive read failed for #{filename}: #{e.message}"
        nil
      end

      # First existing file for +filename+ under any (root, dir, extension)
      # combination, or nil. The name is first tried as given (an absolute path
      # or one relative to the current directory), then under GAME_DIR and
      # RTP_DIR crossed with +dirs+; an accented name stored decomposed on disk
      # is retried in NFD form, as Bitmap does.
      def resolve(filename, dirs)
        return nil if filename.nil? || filename.empty?
        found = exist_with_ext(filename)
        return found if found
        [GAME_DIR, RTP_DIR].each do |root|
          next if root.nil? || root.empty?
          dirs.each do |dir|
            base = dir.empty? ? "#{root}/#{filename}" : "#{root}/#{dir}/#{filename}"
            found = exist_with_ext(base)
            return found if found
          end
        end
        nil
      end

      # First of +base+ with each known extension appended that exists on disk
      # (also trying the decomposed NFD form), or nil.
      def exist_with_ext(base)
        EXTS.each do |ext|
          cand = "#{base}#{ext}"
          return cand if File.exist?(cand)
          nfd = RGSS.to_nfd(cand)
          return nfd if nfd != cand && File.exist?(nfd)
        end
        nil
      end
    end
  end

  module Graphics
    @frame_count = 0
    @frame_rate = 40
    # The game screen, in pixels. RGSS2 added Graphics.width/height, and the
    # stock VX Ace scripts lean on them heavily (measured: width x50, height
    # x32) for camera and window-layout maths, so a boot shell declares its
    # resolution here with resize_screen — the VX/VX Ace one does (544x416,
    # matching the window src/main.cxx opens). RGSS1 has no such method, so the
    # XP resolution is the default and the XP/RPG2000 shells leave it alone.
    @width = 640
    @height = 480
    @brightness = 255
    # The frozen screen a transition dissolves away sits above every game
    # object; RGSS z values are ordinary integers, so pick one past anything a
    # game would set.
    TRANSITION_Z = 0x40000000

    class << self
      attr_accessor :frame_count, :frame_rate
      attr_reader :width, :height, :brightness

      # RGSS2+. Also what the boot shells call to declare the screen size.
      def resize_screen(width, height)
        @width = width
        @height = height
      end

      # Run `duration` frames. Real behaviour, not a stub: the scripts use it to
      # hold a scene (fade-ins, message waits), and each update is a real frame.
      def wait(duration)
        duration.to_i.times { update }
      end

      # 0 (black) .. 255 (normal). Stored so a script's fade bookkeeping is
      # consistent; the value is not applied to what is drawn yet — that needs
      # the same native screen-tone support the RPG2000 tint is waiting on, so
      # say so once rather than pretending the screen darkened.
      def brightness=(value)
        value = 0 if value < 0
        value = 255 if value > 255
        RGSS.warn_stub("Graphics.brightness= (tracked, not drawn)") unless value == 255
        @brightness = value
      end

      # RGSS2+ fades: run the frames the fade would take (so the game's timing
      # is right) and leave the brightness at its end value.
      def fadeout(duration)
        wait(duration)
        self.brightness = 0
      end

      def fadein(duration)
        wait(duration)
        self.brightness = 255
      end

      # RGSS's scene change: `freeze` grabs the current screen and `transition`
      # dissolves it away over `duration` frames, so the next scene builds itself
      # behind a still of the last one. Both are real now, on the native
      # snap_to_bitmap: freeze keeps the snapshot, and transition shows it on a
      # full-screen sprite above everything (z at the maximum) whose opacity is
      # stepped to zero — which is exactly RGSS's default fade.
      #
      # The `filename`/`vague` form (dissolve through a transition *image*) is
      # not modelled; such a transition still runs, as a plain fade over the same
      # number of frames, and says so once.
      def freeze
        # nil when the backend cannot snapshot (it says so itself, once);
        # transition copes by falling back to a plain wait.
        @frozen = snap_to_bitmap
        nil
      end

      def transition(duration = 8, filename = nil, vague = 40)
        RGSS.warn_stub("Graphics.transition with a transition image") if filename
        frozen = @frozen
        @frozen = nil
        @brightness = 255
        return wait(duration) if frozen.nil? || duration <= 0

        sprite = Sprite.new
        sprite.bitmap = frozen
        sprite.z = TRANSITION_Z
        duration.times do |i|
          sprite.opacity = 255 - (255 * (i + 1) / duration)
          update
        end
        sprite.dispose
        frozen.dispose
        nil
      end

      def frame_reset
        RGSS.warn_stub("Graphics.frame_reset")
      end
    end
  end

  module Input
    # Key constants
    UP = 0
    DOWN = 1
    LEFT = 2
    RIGHT = 3
    A = 4
    B = 5
    C = 6
    X = 7
    Y = 8
    Z = 9
    L = 10
    R = 11
    SHIFT = 12
    CTRL = 13
    ALT = 14
    F5 = 15
    F6 = 16
    F7 = 17
    F8 = 18
    F9 = 19

    # RGSS2 (VX) and RGSS3 (VX Ace) name the keys with **symbols** —
    # `Input.trigger?(:C)` — where RGSS1 (XP) used the integer constants above.
    # The stock VX Ace scripts use symbols exclusively (measured: :C, :UP/:DOWN/
    # :LEFT/:RIGHT, :B, :A, :L, :R, :CTRL, :F9 — see docs/rpgvx-rgss-api-gap.md),
    # so map them onto the same key indices instead of keeping two key tables.
    # An Integer is passed through untouched, so every XP / RPG2000 caller and
    # the C++ input bridge are unaffected.
    SYMBOL_KEYS = {
      UP: UP, DOWN: DOWN, LEFT: LEFT, RIGHT: RIGHT,
      A: A, B: B, C: C, X: X, Y: Y, Z: Z, L: L, R: R,
      SHIFT: SHIFT, CTRL: CTRL, ALT: ALT,
      F5: F5, F6: F6, F7: F7, F8: F8, F9: F9
    }.freeze

    @pressed = Array.new(20, false)
    @triggered = Array.new(20, false)
    @repeated = Array.new(20, false)
    @count = Array.new(20, 0)

    # Key index for either spelling. An unrecognised key reads as unpressed
    # rather than raising (a script may probe a key this build has no name for),
    # but it is reported once so the omission is visible in the log.
    def self.key_index(key)
      return key if key.is_a?(Integer)
      index = SYMBOL_KEYS[key]
      RGSS.warn_stub("Input key #{key.inspect}") if index.nil?
      index
    end

    def self.update
      # Key transitions are pushed in from C++ via .press / .release: the SDL
      # window backend (src/sdl_input.cxx -> rgss_sdl_poll) and the terminal
      # backends (rgss_terminal_poll) both drain their events during
      # Graphics.update. This method only advances the per-frame trigger/repeat
      # bookkeeping over that state.

      # Reset triggered state after each frame
      @triggered.each_index do |i|
        @triggered[i] = false
      end

      # Update repeat state
      @pressed.each_index do |i|
        if @pressed[i]
          @count[i] += 1
          if @count[i] >= 30 && @count[i] % 6 == 0
            @repeated[i] = true
          else
            @repeated[i] = false
          end
        else
          @repeated[i] = false
          @count[i] = 0
        end
      end
    end

    def self.press(key)
      index = key_index(key)
      return if index.nil?
      @pressed[index] = true
      @triggered[index] = true
      @count[index] = 0
    end

    # A release clears the held state but deliberately leaves `triggered` alone.
    # Transitions arrive in a buffer that is drained once a frame (the SDL key
    # watch, the browser's on-screen keypad, the terminal backends), so a quick
    # tap can deliver its press *and* its release into the same drain. Clearing
    # the trigger here swallowed that tap completely -- the game saw a key that
    # was never pressed. `update` clears every trigger at the end of the frame,
    # so nothing can outlive the frame it arrived in either way.
    def self.release(key)
      index = key_index(key)
      return if index.nil?
      @pressed[index] = false
      @count[index] = 0
    end

    def self.press?(key)
      index = key_index(key)
      index.nil? ? false : @pressed[index]
    end

    def self.trigger?(key)
      index = key_index(key)
      index.nil? ? false : @triggered[index]
    end

    def self.repeat?(key)
      index = key_index(key)
      index.nil? ? false : @repeated[index]
    end

    def self.dir4
      return 2 if press?(DOWN)
      return 4 if press?(LEFT)
      return 6 if press?(RIGHT)
      return 8 if press?(UP)
      return 0
    end

    def self.dir8
      return 1 if press?(DOWN) && press?(LEFT)
      return 3 if press?(DOWN) && press?(RIGHT)
      return 7 if press?(UP) && press?(LEFT)
      return 9 if press?(UP) && press?(RIGHT)
      return dir4
    end

    # Pointer state, captured by the SDL window backend (see input_bridge.cxx).
    # In game/canvas pixels; (0, 0) and unpressed under backends with no mouse.
    # MV's TouchInput bridge reads these for menu/title clicking.
    def self.mouse_x
      RGSS.mouse_x
    end

    def self.mouse_y
      RGSS.mouse_y
    end

    def self.mouse_pressed?
      RGSS.mouse_pressed?
    end
  end
end

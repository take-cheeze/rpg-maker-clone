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

  class Bitmap
    def initialize f, s = nil
      if f.kind_of? String
        i = self._init_file(f, s)
        [GAME_DIR, RTP_DIR].each do |d|
          next if d.nil? || d.empty?
          i = self._init_file("#{d}/#{f}", s) unless i
          # RGSS resolves a bare asset name against several image formats, and
          # the RPG Maker XP RTP genuinely mixes them: its windowskins and
          # charsets are .png while its title backgrounds are .jpg, so a
          # png-only search left every XP title screen on the fallback
          # background (found by scripts/compare-rpgxp-wine.bash). stb decodes
          # JPEG, so both spellings of the extension are just more candidates.
          [:png, :jpg, :jpeg, :xyz, :bmp].each do |ext|
            i = self._init_file("#{d}/#{f}.#{ext}", s) unless i
          end
        end
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
    # A viewport `tone` rescales what is already drawn (desaturate toward
    # luminance, then offset each channel), which — unlike `color` — cannot be
    # expressed as one more layer on top: it needs the same per-pixel pass the
    # RPG2000 screen tint is waiting on (docs/TODO.md, docs/rpgvx-rgss-api-gap.md).
    # The value is kept so a script's bookkeeping is consistent and so the tint
    # lands the moment that pass exists; it is not drawn, and says so once.
    def tone
      @tone ||= Tone.new(0, 0, 0, 0)
    end

    def tone=(value)
      RGSS.warn_stub("Viewport#tone= (tracked, not drawn)")
      @tone = value
    end
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

    class << self
      def bgm_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, MUSIC_DIRS)
        _bgm_play(path, volume, pitch) if path
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
        _bgs_play(path, volume, pitch) if path
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
        _me_play(path, volume, pitch) if path
      end

      def me_stop
        _me_stop
      end

      def me_fade(time)
        _me_fade(time)
      end

      def se_play(filename, volume = 100, pitch = 100)
        path = resolve(filename, SOUND_DIRS)
        _se_play(path, volume, pitch) if path
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

      def freeze
        RGSS.warn_stub("Graphics.freeze")
      end

      def transition(duration = 8, filename = nil, vague = 40)
        RGSS.warn_stub("Graphics.transition")
        wait(duration)
        @brightness = 255
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

    def self.release(key)
      index = key_index(key)
      return if index.nil?
      @pressed[index] = false
      @triggered[index] = false
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

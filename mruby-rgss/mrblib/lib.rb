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
          [:png, :xyz, :bmp].each do |ext|
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

  # RGSS Font. Rendering currently uses the built-in shinonome bitmap font, so
  # only the attributes that scripts read/write are modelled here.
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

  class Plane
  end

  class Sprite
    attr_reader :bitmap
    attr_reader :x, :y, :z
  end

  class Tilemap
  end

  class Window
  end

  class RGSSError < StandardError
  end

  # RGSS Audio module. Playback back-ends are not wired up yet, so these are
  # inert stubs that keep scripts calling the standard API from crashing.
  module Audio
    class << self
      def bgm_play(filename, volume = 100, pitch = 100)
        RGSS.warn_stub("Audio.bgm_play")
      end

      def bgm_stop
        RGSS.warn_stub("Audio.bgm_stop")
      end

      def bgm_fade(time)
        RGSS.warn_stub("Audio.bgm_fade")
      end

      def bgm_pos
        RGSS.warn_stub("Audio.bgm_pos")
        0
      end

      def bgs_play(filename, volume = 100, pitch = 100)
        RGSS.warn_stub("Audio.bgs_play")
      end

      def bgs_stop
        RGSS.warn_stub("Audio.bgs_stop")
      end

      def bgs_fade(time)
        RGSS.warn_stub("Audio.bgs_fade")
      end

      def bgs_pos
        RGSS.warn_stub("Audio.bgs_pos")
        0
      end

      def me_play(filename, volume = 100, pitch = 100)
        RGSS.warn_stub("Audio.me_play")
      end

      def me_stop
        RGSS.warn_stub("Audio.me_stop")
      end

      def me_fade(time)
        RGSS.warn_stub("Audio.me_fade")
      end

      def se_play(filename, volume = 100, pitch = 100)
        RGSS.warn_stub("Audio.se_play")
      end

      def se_stop
        RGSS.warn_stub("Audio.se_stop")
      end
    end
  end

  module Graphics
    @frame_count = 0
    @frame_rate = 40

    class << self
      attr_accessor :frame_count, :frame_rate

      def freeze
        RGSS.warn_stub("Graphics.freeze")
      end

      def transition(duration = 8, filename = nil, vague = 40)
        RGSS.warn_stub("Graphics.transition")
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

    @pressed = Array.new(20, false)
    @triggered = Array.new(20, false)
    @repeated = Array.new(20, false)
    @count = Array.new(20, 0)

    def self.update
      # This would normally be implemented in C++ to read actual input
      # For now, we'll just have a stub implementation

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
      @pressed[key] = true
      @triggered[key] = true
      @count[key] = 0
    end

    def self.release(key)
      @pressed[key] = false
      @triggered[key] = false
      @count[key] = 0
    end

    def self.press?(key)
      @pressed[key]
    end

    def self.trigger?(key)
      @triggered[key]
    end

    def self.repeat?(key)
      @repeated[key]
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
  end
end

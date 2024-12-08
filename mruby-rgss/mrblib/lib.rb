module RGSS
  class Timeout < StandardError; end

  class Bitmap
    def initialize f, s = nil
      if f.kind_of? String
        i = self._init_file(f, s)
        [GAME_DIR, RTP_DIR].each do |d|
          i = self._init_file("#{d}/#{f}") unless i
          [:png, :xyz, :bmp].each do |ext|
            i = self._init_file("#{d}/#{f}.#{ext}") unless i
          end
        end
        raise "Failed to init bitmap: #{f}" unless i
      else
        self._init_size(f, s)
      end
    end
  end

  class Color
  end

  class Font
    attr_accessor :name, :size, :bold, :italic, :outline, :shadow, :color, :out_color

    class <<self
      attr_accessor \
        :default_name, :default_size, :default_bold, :default_italic, \
        :default_shadow, :default_outline, :default_color, :default_out_color
    end
  end

  class Plane
  end

  class Rect
  end

  class Sprite
    attr_reader :bitmap
    attr_reader :z
  end

  class Table
  end

  class Tilemap
  end

  class Tone
  end

  class Viewport
  end

  class Window
  end

  class RGSSError < StandardError
  end

  module Audio
  end

  module Graphics
  end

  module Input
  end
end

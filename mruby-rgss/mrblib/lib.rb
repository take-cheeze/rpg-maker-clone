module RGSS
  class Timeout < StandardError; end

  class Bitmap
    def initialize f, s = nil
      if f.kind_of? String
        i = self._init_file(f, s)
        i = self._init_file("#{GAME_DIR}/#{f}") unless i
        i = self._init_file("#{GAME_DIR}/#{f}.png") unless i
        i = self._init_file("#{GAME_DIR}/#{f}.xyz") unless i
        raise "Failed to init bitmap: #{f}" unless i
      else
        self._init_size(f, s)
      end
    end
  end

  class Color
  end

  class Font
  end

  class Plane
  end

  class Rect
  end

  class Sprite
    attr_reader :bitmap
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

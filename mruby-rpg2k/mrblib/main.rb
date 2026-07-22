class Object
  include RGSS
end

module RGSS
  # RPG Maker 2000 style window. The visual is assembled from a "windowskin"
  # System graphic laid out in the classic 160x80 arrangement:
  #
  #   (0, 0, 32, 32)   background fill (stretched over the interior)
  #   (32, 0, 32, 32)  8px-thick frame border, split into 4 corners and 4 edges
  #   (64, 0, 32, 32)  selection cursor, nine-sliced the same way as the frame
  #
  # Background, frame, the selection cursor and the window contents are all
  # composited into a single Bitmap that backs one Sprite.
  class Window
    # Windows are drawn above ordinary background sprites (which default to
    # z == 0), so give the backing sprite a high z by default.
    DEFAULT_Z = 100

    # Thickness of the RPG2k frame border, in pixels.
    BORDER = 8

    # Origin of the selection cursor region within the windowskin (the third
    # 32px column, after the background and the frame).
    CURSOR_SX = 64
    CURSOR_SY = 0

    def initialize(x = 0, y = 0, width = 0, height = 0)
      @x = x
      @y = y
      @width = width
      @height = height
      @contents = nil
      @windowskin = nil
      @cursor_rect = Rect.new(0, 0, 0, 0)
      @active = true
      @visible = true
      # Back the window with a Sprite so its contents are actually drawn.
      @sprite = Sprite.new
      @sprite.x = x
      @sprite.y = y
      @sprite.z = DEFAULT_Z
      allocate_skin
    end

    attr_reader :x, :y, :width, :height, :contents, :windowskin, :cursor_rect
    attr_reader :active, :visible

    def x=(v)
      @x = v
      @sprite.x = v
    end

    def y=(v)
      @y = v
      @sprite.y = v
    end

    def z=(v)
      @sprite.z = v
    end

    def width=(v)
      @width = v
      allocate_skin
    end

    def height=(v)
      @height = v
      allocate_skin
    end

    def windowskin=(bmp)
      @windowskin = bmp
      redraw
      bmp
    end

    def contents=(bmp)
      @contents = bmp
      redraw
      bmp
    end

    def cursor_rect=(rect)
      @cursor_rect = rect
      redraw
      rect
    end

    def active=(v)
      @active = v
      redraw
    end

    def visible=(v)
      @visible = v
      redraw
    end

    # Present so the game loop can drive per-frame behaviour (cursor blinking,
    # etc.). The cursor is drawn steadily for now, so this is a no-op.
    def update; end

    def dispose
      @sprite.dispose
    end

    private

    # (Re)create the backing bitmap whenever the window is resized, then redraw.
    def allocate_skin
      @skin = Bitmap.new([@width, 1].max, [@height, 1].max)
      @sprite.bitmap = @skin
      redraw
    end

    def redraw
      @skin.clear
      return unless @visible

      if @windowskin
        draw_background
        draw_frame
      else
        draw_fallback
      end

      draw_cursor
      draw_contents
    end

    # Stretch the 32x32 background tile over the whole window; the frame border
    # is drawn on top of its outer edge afterwards.
    def draw_background
      @skin.stretch_blt Rect.new(0, 0, @width, @height), @windowskin,
                        Rect.new(0, 0, 32, 32)
    end

    def draw_frame
      # The frame is a hollow nine-slice: the interior is left to
      # draw_background, so do not fill the centre here.
      draw_nine_slice 0, 0, @width, @height, 32, 0, false
    end

    # Nine-slice a 32x32 windowskin region (rooted at sx, sy, with 8px corners)
    # to cover the rectangle (x, y, w, h): the four corners are blitted 1:1
    # while the edges — and, when fill_center is set, the middle — are stretched
    # along their free axes. Shared by the window frame and the selection
    # cursor. stretch_blt ignores zero-sized pieces, so a rect as short as one
    # 16px row (where the centre and side edges collapse) renders correctly.
    def draw_nine_slice(x, y, w, h, sx, sy, fill_center)
      b = BORDER
      sk = @windowskin

      # Corners (8x8, drawn 1:1).
      @skin.blt x, y, sk, Rect.new(sx, sy, b, b)
      @skin.blt x + w - b, y, sk, Rect.new(sx + 24, sy, b, b)
      @skin.blt x, y + h - b, sk, Rect.new(sx, sy + 24, b, b)
      @skin.blt x + w - b, y + h - b, sk, Rect.new(sx + 24, sy + 24, b, b)

      # Edges (stretched along the free axis).
      @skin.stretch_blt Rect.new(x + b, y, w - 2 * b, b), sk,
                        Rect.new(sx + 8, sy, 16, b)
      @skin.stretch_blt Rect.new(x + b, y + h - b, w - 2 * b, b), sk,
                        Rect.new(sx + 8, sy + 24, 16, b)
      @skin.stretch_blt Rect.new(x, y + b, b, h - 2 * b), sk,
                        Rect.new(sx, sy + 8, b, 16)
      @skin.stretch_blt Rect.new(x + w - b, y + b, b, h - 2 * b), sk,
                        Rect.new(sx + 24, sy + 8, b, 16)

      return unless fill_center

      # Centre: the translucent selection glass behind the highlighted item.
      @skin.stretch_blt Rect.new(x + b, y + b, w - 2 * b, h - 2 * b), sk,
                        Rect.new(sx + 8, sy + 8, 16, 16)
    end

    # Used when no windowskin could be loaded: a plain dark panel with a light
    # border so the window is still visible.
    def draw_fallback
      @skin.fill_rect 0, 0, @width, @height, Color.new(8, 8, 40, 224)
      edge = Color.new(200, 200, 216, 255)
      @skin.fill_rect 0, 0, @width, 1, edge
      @skin.fill_rect 0, @height - 1, @width, 1, edge
      @skin.fill_rect 0, 0, 1, @height, edge
      @skin.fill_rect @width - 1, 0, 1, @height, edge
    end

    # Selection cursor behind the highlighted item. cursor_rect is expressed in
    # contents coordinates, so it is offset by the border thickness.
    def draw_cursor
      return unless @active
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0

      x = BORDER + r.x
      y = BORDER + r.y
      if @windowskin
        # Draw the authentic RPG2k cursor nine-sliced from the windowskin.
        draw_nine_slice x, y, r.width, r.height, CURSOR_SX, CURSOR_SY, true
      else
        draw_fallback_cursor x, y, r.width, r.height
      end
    end

    # Used when no windowskin is available: fill_rect overwrites (it does not
    # alpha-blend onto the window background), so use an opaque highlight — a
    # solid blue bar with a brighter border.
    def draw_fallback_cursor(x, y, w, h)
      @skin.fill_rect x, y, w, h, Color.new(24, 40, 176, 255)
      border = Color.new(180, 200, 255, 255)
      @skin.fill_rect x, y, w, 1, border
      @skin.fill_rect x, y + h - 1, w, 1, border
      @skin.fill_rect x, y, 1, h, border
      @skin.fill_rect x + w - 1, y, 1, h, border
    end

    def draw_contents
      return unless @contents
      @skin.blt BORDER, BORDER, @contents, @contents.rect
    end
  end
end

class RPG2k
  WIDTH = 320
  HEIGHT = 240

  module Scene
    class Base
      def initialize parent
        @db = parent.db
        @map_tree = parent.map_tree
      end
      def update ; end

      attr_reader :db, :map_tree
    end

    class Title < Base
      # Height of one selectable line. The shinonome font is 12px tall; the
      # extra space gives a little breathing room between entries.
      LINE_HEIGHT = 16
      # draw_text is top-aligned, so nudge the 12px glyphs down to sit centred
      # within the line (and the selection cursor).
      TEXT_PAD_Y = (LINE_HEIGHT - 12) / 2

      def initialize parent
        super parent

        @title = Sprite.new
        @title.bitmap = Bitmap.new "Title/#{db.system.title}"

        @menu_items =
          [db.term.new_game, db.term.continue, db.term.shutdown].map(&:to_s)
        @selected_index = 0

        # Size the contents to the widest menu label (plus a small right pad).
        measure = Bitmap.new 1, 1
        text_w = @menu_items.map { |t| measure.text_size(t).width }.max
        content_w = text_w + 8
        content_h = @menu_items.length * LINE_HEIGHT

        window_width = content_w + Window::BORDER * 2
        window_height = content_h + Window::BORDER * 2

        # Centre the window horizontally, sitting in the lower third of the
        # screen like the reference title layout.
        window_x = (WIDTH - window_width) / 2
        window_y = 160

        @window = Window.new window_x, window_y, window_width, window_height
        @window.windowskin = load_windowskin

        # Render the (unchanging) menu labels once. White text reads clearly on
        # the dark window background.
        contents = Bitmap.new content_w, content_h
        contents.font.color = Color.new(255, 255, 255, 255)
        @menu_items.each_with_index do |item, index|
          contents.draw_text 0, index * LINE_HEIGHT + TEXT_PAD_Y, content_w,
                             LINE_HEIGHT, item
        end
        @window.contents = contents

        refresh_cursor
      end

      def update
        # Cursor movement wraps around the ends and honours auto-repeat, so a
        # held UP/DOWN keeps scrolling the selection like RPG Maker's menus.
        if menu_move?(Input::DOWN)
          @selected_index = (@selected_index + 1) % @menu_items.length
          refresh_cursor
        elsif menu_move?(Input::UP)
          @selected_index = (@selected_index - 1) % @menu_items.length
          refresh_cursor
        end

        if Input.trigger?(Input::C)  # C is usually the confirm button (Enter/Z)
          case @selected_index
          when 0  # New Game
            # TODO: Implement new game logic
          when 1  # Continue
            # TODO: Implement continue game logic
          when 2  # Shutdown
            exit
          end
        end

        @window.update
      end

      private

      # A direction counts as "moved" on the initial press and on every
      # auto-repeat tick while the key is held. Input.repeat? does not fire on
      # the first frame in this engine, so trigger? covers that case.
      def menu_move?(key)
        Input.trigger?(key) || Input.repeat?(key)
      end

      # Load the System/ windowskin declared in the database. Returns nil when
      # it is missing so the Window falls back to a plain panel instead of
      # crashing.
      def load_windowskin
        name = db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}"
      rescue StandardError
        nil
      end

      def refresh_cursor
        @window.cursor_rect =
          Rect.new(0, @selected_index * LINE_HEIGHT, @window.contents.width,
                   LINE_HEIGHT)
      end
    end
  end

  attr_reader :db, :map_tree

  def initialize args
    @db = LCF::Database.new File.open "#{GAME_DIR}/RPG_RT.ldb"
    @map_tree = LCF::MapTree.new File.open "#{GAME_DIR}/RPG_RT.lmt"
    @scenes = []
    push Scene::Title.new self
  end

  def push scene
    @scenes.push scene
  end

  def main_loop
    @scenes.last.update
    Input.update
    Graphics.update
  end

  def start
    loop do
      main_loop
    end
  rescue RGSS::Timeout
  end
end

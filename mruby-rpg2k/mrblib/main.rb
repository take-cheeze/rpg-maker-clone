class Object
  include RGSS
end

module RGSS
  # RPG Maker 2000 style window. The visual is assembled from a "windowskin"
  # System graphic laid out in the classic 160x80 arrangement:
  #
  #   (0, 0, 32, 32)   background fill (stretched over the interior)
  #   (32, 0, 32, 32)  8px-thick frame border, split into 4 corners and 4 edges
  #
  # Background, frame, the selection cursor and the window contents are all
  # composited into a single Bitmap that backs one Sprite.
  class Window
    # Windows are drawn above ordinary background sprites (which default to
    # z == 0), so give the backing sprite a high z by default.
    DEFAULT_Z = 100

    # Thickness of the RPG2k frame border, in pixels.
    BORDER = 8

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
      w = @width
      h = @height
      b = BORDER
      sk = @windowskin

      # Corners (8x8, drawn 1:1).
      @skin.blt 0, 0, sk, Rect.new(32, 0, b, b)
      @skin.blt w - b, 0, sk, Rect.new(56, 0, b, b)
      @skin.blt 0, h - b, sk, Rect.new(32, 24, b, b)
      @skin.blt w - b, h - b, sk, Rect.new(56, 24, b, b)

      # Edges (stretched along the free axis).
      @skin.stretch_blt Rect.new(b, 0, w - 2 * b, b), sk, Rect.new(40, 0, 16, b)
      @skin.stretch_blt Rect.new(b, h - b, w - 2 * b, b), sk,
                        Rect.new(40, 24, 16, b)
      @skin.stretch_blt Rect.new(0, b, b, h - 2 * b), sk, Rect.new(32, 8, b, 16)
      @skin.stretch_blt Rect.new(w - b, b, b, h - 2 * b), sk,
                        Rect.new(56, 8, b, 16)
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

    # Highlight box behind the selected item. cursor_rect is expressed in
    # contents coordinates, so it is offset by the border thickness.
    def draw_cursor
      return unless @active
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0

      # fill_rect overwrites (it does not alpha-blend onto the window
      # background), so use an opaque highlight: a solid blue bar with a
      # brighter border, matching the reference title screen's selection box.
      x = BORDER + r.x
      y = BORDER + r.y
      @skin.fill_rect x, y, r.width, r.height, Color.new(24, 40, 176, 255)
      border = Color.new(180, 200, 255, 255)
      @skin.fill_rect x, y, r.width, 1, border
      @skin.fill_rect x, y + r.height - 1, r.width, 1, border
      @skin.fill_rect x, y, 1, r.height, border
      @skin.fill_rect x + r.width - 1, y, 1, r.height, border
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
        @parent = parent
        @db = parent.db
        @map_tree = parent.map_tree
      end
      def update ; end
      def dispose ; end

      attr_reader :parent, :db, :map_tree
    end

    # Play scene: renders the loaded map and lets the party leader walk around
    # it. Tiles are drawn as solid colour blocks derived from their tile id (a
    # placeholder until real chipset blitting lands — see docs/TODO.md); the
    # player is drawn from its real CharSet graphic. Movement is grid based with
    # smooth pixel interpolation, walk animation, tile/edge/event collision and
    # a camera that follows the player and clamps to the map edges.
    class Map < Base
      TILE = Game::TILE
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      # Visible tiles plus a one-tile margin so partially scrolled edges show.
      COLS = SCREEN_W / TILE + 1
      ROWS = SCREEN_H / TILE + 1
      # Pixels moved per frame while stepping between tiles (must divide TILE).
      SPEED = 2

      def initialize parent, state
        super parent
        @state = state
        @map = state.map
        @chipset = build_chipset
        @charset = load_charset
        @event_tiles = collect_event_tiles

        # Player pixel position and step state.
        @moving = false
        @move_count = 0
        @dest_x = @state.x
        @dest_y = @state.y
        @tile_colors = {}
        @last_frame = nil

        setup_sprites
        render
      end

      attr_reader :state

      def dispose
        [@lower_sprite, @upper_sprite, @player_sprite].each do |s|
          s.dispose if s
        end
      end

      def update
        step_movement
        render
      end

      private

      def setup_sprites
        @lower_sprite = Sprite.new
        @lower_sprite.z = 0
        @lower_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @lower_sprite.bitmap = @lower_bmp

        @upper_sprite = Sprite.new
        @upper_sprite.z = 200
        @upper_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @upper_sprite.bitmap = @upper_bmp

        @player_sprite = Sprite.new
        @player_sprite.z = 100
        @player_bmp = Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
        @player_sprite.bitmap = @player_bmp
        # Fallback marker when the CharSet graphic is unavailable.
        unless @charset
          @player_bmp.fill_rect 4, 0, TILE, Game::CharSet::HEIGHT,
                                Color.new(240, 240, 80, 255)
        end
      end

      def build_chipset
        Game::ChipSet.new(@db, @map.chipset_id)
      rescue StandardError
        nil
      end

      # Load the leader's CharSet graphic. Returns nil (falling back to a marker)
      # when there is no party or the file is missing.
      def load_charset
        leader = @state.party.leader
        return nil if leader.nil?
        name = leader.charset_name
        @charset_index = leader.charset_index || 0
        return nil if name.nil? || name.empty?
        Bitmap.new "CharSet/#{name}"
      rescue StandardError
        nil
      end

      def collect_event_tiles
        tiles = {}
        evs = @map.unit.events
        evs.each { |_id, ev| tiles[[ev.x, ev.y]] = true } if evs
        tiles
      rescue StandardError
        {}
      end

      def step_movement
        if @moving
          @move_count += SPEED
          if @move_count >= TILE
            @state.x = @dest_x
            @state.y = @dest_y
            @moving = false
            @move_count = 0
          end
          return
        end

        dir = Input.dir4
        return if dir == 0

        @state.direction = dir
        nx, ny = target_tile(@state.x, @state.y, dir)
        return unless passable?(nx, ny, dir)

        @dest_x = nx
        @dest_y = ny
        @moving = true
        @move_count = 0
      end

      def target_tile(x, y, dir)
        case dir
        when 2 then [x, y + 1]
        when 4 then [x - 1, y]
        when 6 then [x + 1, y]
        when 8 then [x, y - 1]
        else [x, y]
        end
      end

      def passable?(x, y, dir)
        return false unless @map.in_bounds?(x, y)
        return false if @event_tiles[[x, y]]
        return true if @chipset.nil?
        @chipset.passable?(@map.lower(x, y), dir)
      end

      # Current player position in map pixels, interpolated during a step.
      def player_pixel
        if @moving
          [@state.x * TILE + (@dest_x - @state.x) * @move_count,
           @state.y * TILE + (@dest_y - @state.y) * @move_count]
        else
          [@state.x * TILE, @state.y * TILE]
        end
      end

      def render
        px, py = player_pixel
        cam_x = Game.camera_offset(px + TILE / 2, SCREEN_W, @map.width * TILE)
        cam_y = Game.camera_offset(py + TILE / 2, SCREEN_H, @map.height * TILE)

        draw_layers cam_x, cam_y

        @player_sprite.x = px - cam_x - (Game::CharSet::WIDTH - TILE) / 2
        @player_sprite.y = py - cam_y - (Game::CharSet::HEIGHT - TILE)
        draw_player_frame
      end

      def draw_layers cam_x, cam_y
        @lower_bmp.clear
        @upper_bmp.clear
        first_tx = cam_x / TILE
        first_ty = cam_y / TILE
        ox = cam_x % TILE
        oy = cam_y % TILE

        (0...ROWS).each do |ry|
          (0...COLS).each do |rx|
            tx = first_tx + rx
            ty = first_ty + ry
            dx = rx * TILE - ox
            dy = ry * TILE - oy

            lower = @map.lower(tx, ty)
            @lower_bmp.fill_rect dx, dy, TILE, TILE, tile_color(lower)

            upper = @map.upper(tx, ty)
            @upper_bmp.fill_rect dx, dy, TILE, TILE, tile_color(upper) if upper && upper != 0

            if @event_tiles[[tx, ty]]
              @lower_bmp.fill_rect dx + 3, dy + 3, TILE - 6, TILE - 6,
                                   Color.new(230, 90, 90, 255)
            end
          end
        end
      end

      def draw_player_frame
        return unless @charset
        pat = @moving ? Game::CharSet::WALK_PATTERNS[(@move_count / 4) % 4] : 1
        frame = [@state.direction, pat]
        return if frame == @last_frame
        @last_frame = frame

        rx, ry, rw, rh = Game::CharSet.frame_rect(@charset_index, @state.direction, pat)
        @player_bmp.clear
        @player_bmp.blt 0, 0, @charset, Rect.new(rx, ry, rw, rh)
      end

      # Deterministic, memoised colour for a tile id so distinct tiles read as
      # distinct blocks. Empty (0/nil) tiles are a dark "void".
      def tile_color id
        return (@void ||= Color.new(16, 16, 28, 255)) if id.nil? || id == 0
        @tile_colors[id] ||= Color.new(40 + (id * 37) % 180,
                                       40 + (id * 71) % 180,
                                       60 + (id * 143) % 160, 255)
      end
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
        if Input.trigger?(Input::DOWN) && @selected_index < @menu_items.length - 1
          @selected_index += 1
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @selected_index > 0
          @selected_index -= 1
          refresh_cursor
        end

        if Input.trigger?(Input::C)  # C is usually the confirm button (Enter/Z)
          case @selected_index
          when 0  # New Game
            parent.start_new_game
          when 1  # Continue
            parent.continue_game
          when 2  # Shutdown
            exit
          end
        end

        @window.update
      end

      def dispose
        @title.dispose
        @window.dispose
      end

      private

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

  # Load one map (.lmu) by id. Map files are named Map0001.lmu, Map0002.lmu, ...
  def load_map id
    num = id.to_s
    num = "0#{num}" while num.size < 4
    path = "#{GAME_DIR}/Map#{num}.lmu"
    Game::Map.new id, LCF::MapUnit.new(File.open(path))
  end

  # New Game: build the initial party from the database, read the start
  # position from the map tree, load the starting map and enter the map scene.
  # The map/player renderer is not wired up yet, so this establishes the running
  # game state and transitions scenes without drawing the map.
  def start_new_game
    init = map_tree.initial
    state = Game::State.new Game::Party.new(@db), init.initial_map_id,
                            init.initial_x, init.initial_y
    state.map = load_map state.map_id
    # Build the play scene first; only tear down the title once it succeeds so a
    # data problem leaves the title intact instead of a blank screen.
    scene = Scene::Map.new(self, state)
    @scenes.last.dispose
    @scenes = [scene]
  rescue StandardError => e
    # Never let a data problem crash the title screen; report and stay put.
    $stderr.puts "[RPG2k] Failed to start new game: #{e.message}"
  end

  # Continue: loading a saved game (LcfSaveData) is not implemented yet — the
  # save schema and load path are still to be written (see docs/TODO.md). Warn
  # once so selecting Continue is an explicit no-op rather than a silent gap.
  def continue_game
    RGSS.warn_stub "Continue (load saved game)"
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

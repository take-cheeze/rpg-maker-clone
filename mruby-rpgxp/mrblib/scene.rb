# RPG Maker XP scenes: the title screen and the first walkable map scene, plus a
# small XP-styled window helper. The title reproduces the default RMXP flow
# (title graphic + New Game / Continue / Shutdown) directly against the database;
# the map scene renders the three tile layers as placeholder colour blocks (real
# tileset/autotile blitting is future work, mirroring the RPG2000 side) and lets
# the party leader walk with tileset collision and a follow camera.

class RPGXP
  # A compact RMXP-style window: a Viewport that clips a skin layer, a selection
  # cursor and a contents bitmap. The windowskin is the 192x128 RMXP layout — a
  # 128x128 stretched background with a 64x64 nine-slice border at (128,0). When
  # no skin is available (e.g. the RTP graphics are absent) it falls back to a
  # plain translucent panel so the UI is still legible.
  class Panel
    BORDER = 16

    def initialize(x, y, width, height, skin = nil)
      @x = x
      @y = y
      @width = width
      @height = height
      @skin = skin
      @active = true
      @cursor_rect = nil

      @viewport = Viewport.new(x, y, [width, 1].max, [height, 1].max)
      @viewport.z = 100

      @skin_sprite = Sprite.new(@viewport)
      @skin_sprite.z = 0
      @cursor_sprite = Sprite.new(@viewport)
      @cursor_sprite.z = 1
      @contents_sprite = Sprite.new(@viewport)
      @contents_sprite.z = 2
      @contents_sprite.x = BORDER
      @contents_sprite.y = BORDER

      @skin_bmp = Bitmap.new([width, 1].max, [height, 1].max)
      @skin_sprite.bitmap = @skin_bmp
      @cursor_bmp = Bitmap.new([width, 1].max, [height, 1].max)
      @cursor_sprite.bitmap = @cursor_bmp

      draw_skin
    end

    # The usable interior size (inside the border) for a contents bitmap.
    def inner_width;  @width - BORDER * 2;  end
    def inner_height; @height - BORDER * 2; end

    def z=(v)
      @viewport.z = v
    end

    def contents=(bmp)
      @contents = bmp
      @contents_sprite.bitmap = bmp if bmp
    end

    def active=(v)
      @active = v
      draw_cursor
    end

    # Selection highlight, in contents coordinates (offset by the border).
    def cursor_rect=(rect)
      @cursor_rect = rect
      draw_cursor
    end

    def dispose
      [@skin_sprite, @cursor_sprite, @contents_sprite].each { |s| s.dispose if s }
      @viewport.dispose
    end

    private

    def draw_skin
      @skin_bmp.clear
      if @skin
        draw_skin_background
        draw_skin_border
      else
        draw_fallback
      end
    end

    def draw_skin_background
      @skin_bmp.stretch_blt Rect.new(2, 2, @width - 4, @height - 4), @skin,
                            Rect.new(0, 0, 128, 128)
    rescue StandardError
      draw_fallback
    end

    # Nine-slice the 64x64 border block at (128,0): 16x16 corners with stretched
    # edges between them.
    def draw_skin_border
      w = @width
      h = @height
      b = BORDER
      s = @skin
      sx = 128
      # Corners.
      @skin_bmp.blt 0, 0, s, Rect.new(sx, 0, b, b)
      @skin_bmp.blt w - b, 0, s, Rect.new(sx + 48, 0, b, b)
      @skin_bmp.blt 0, h - b, s, Rect.new(sx, 48, b, b)
      @skin_bmp.blt w - b, h - b, s, Rect.new(sx + 48, 48, b, b)
      # Edges.
      @skin_bmp.stretch_blt Rect.new(b, 0, w - 2 * b, b), s, Rect.new(sx + b, 0, b, b)
      @skin_bmp.stretch_blt Rect.new(b, h - b, w - 2 * b, b), s, Rect.new(sx + b, 48, b, b)
      @skin_bmp.stretch_blt Rect.new(0, b, b, h - 2 * b), s, Rect.new(sx, b, b, b)
      @skin_bmp.stretch_blt Rect.new(w - b, b, b, h - 2 * b), s, Rect.new(sx + 48, b, b, b)
    rescue StandardError
      draw_fallback
    end

    def draw_fallback
      @skin_bmp.fill_rect 0, 0, @width, @height, Color.new(8, 16, 56, 224)
      edge = Color.new(200, 208, 232, 255)
      @skin_bmp.fill_rect 0, 0, @width, 2, edge
      @skin_bmp.fill_rect 0, @height - 2, @width, 2, edge
      @skin_bmp.fill_rect 0, 0, 2, @height, edge
      @skin_bmp.fill_rect @width - 2, 0, 2, @height, edge
    end

    def draw_cursor
      @cursor_bmp.clear
      return unless @active && @cursor_rect
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0
      x = BORDER + r.x
      y = BORDER + r.y
      @cursor_bmp.fill_rect x, y, r.width, r.height, Color.new(40, 72, 200, 160)
      border = Color.new(200, 216, 255, 255)
      @cursor_bmp.fill_rect x, y, r.width, 2, border
      @cursor_bmp.fill_rect x, y + r.height - 2, r.width, 2, border
      @cursor_bmp.fill_rect x, y, 2, r.height, border
      @cursor_bmp.fill_rect x + r.width - 2, y, 2, r.height, border
    end
  end

  module Scene
    class Base
      def initialize(parent)
        @parent = parent
        @db = parent.db
      end

      attr_reader :parent, :db

      def update; end
      def dispose; end

      # Load the System windowskin (Graphics/Windowskins/) declared in the
      # database, or nil so Panel falls back to a plain panel.
      def load_windowskin
        name = @db.system.windowskin_name
        return nil if name.nil? || name.empty?
        Bitmap.new "Graphics/Windowskins/#{name}"
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      # Play a System sound effect (RPG::AudioFile), best effort.
      def play_se(audio)
        return unless audio && audio.name && !audio.name.empty?
        Audio.se_play(audio.name, audio.volume || 100, audio.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RGSS] SE playback failed: #{e.message}"
      end
    end

    # Title screen: the title graphic behind a command window offering New Game,
    # Continue and Shutdown. These command labels live in the game's Ruby scripts
    # (not the database), so the default English set is used.
    class Title < Base
      WIDTH = RPGXP::WIDTH
      HEIGHT = RPGXP::HEIGHT
      LINE_H = 32
      COMMANDS = ["New Game", "Continue", "Shutdown"].freeze

      def initialize(parent)
        super parent
        @index = 0
        @skin = load_windowskin
        build_background
        build_command_window
        start_title_bgm
      end

      def dispose
        @bg.dispose if @bg
        @command.dispose if @command
      end

      def update
        if Input.trigger?(Input::DOWN) && @index < COMMANDS.size - 1
          @index += 1
          play_se(@db.system.cursor_se)
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @index > 0
          @index -= 1
          play_se(@db.system.cursor_se)
          refresh_cursor
        elsif Input.trigger?(Input::C)
          play_se(@db.system.decision_se)
          select_command
        end
      end

      private

      def build_background
        @bg = Sprite.new
        @bg.z = 0
        name = @db.system.title_name
        @bg.bitmap =
          if name && !name.empty?
            Bitmap.new "Graphics/Titles/#{name}"
          else
            fallback_background
          end
      rescue StandardError => e
        $stderr.puts "[RGSS] title graphic load failed, using plain background: #{e.message}"
        @bg.bitmap = fallback_background
      end

      def fallback_background
        bmp = Bitmap.new(WIDTH, HEIGHT)
        bmp.fill_rect 0, 0, WIDTH, HEIGHT, Color.new(12, 20, 48, 255)
        bmp.font.color = Color.new(240, 240, 248, 255)
        bmp.draw_text 0, HEIGHT / 3, WIDTH, 40, @parent.title.to_s, 1
        bmp
      end

      def build_command_window
        w = 240
        h = COMMANDS.size * LINE_H + Panel::BORDER * 2
        @command = Panel.new((WIDTH - w) / 2, HEIGHT - h - 64, w, h, @skin)
        @command.z = 200
        contents = Bitmap.new(@command.inner_width, @command.inner_height)
        contents.font.color = Color.new(255, 255, 255, 255)
        COMMANDS.each_with_index do |c, i|
          contents.draw_text 4, i * LINE_H + 4, contents.width - 8, LINE_H - 4, c
        end
        @command.contents = contents
        refresh_cursor
      end

      def refresh_cursor
        @command.cursor_rect = Rect.new(0, @index * LINE_H, @command.inner_width, LINE_H)
      end

      def select_command
        case @index
        when 0 then @parent.start_new_game
        when 1 then @parent.continue_game
        when 2 then exit
        end
      end

      def start_title_bgm
        bgm = @db.system.title_bgm
        return unless bgm && bgm.name && !bgm.name.empty?
        Audio.bgm_play(bgm.name, bgm.volume || 100, bgm.pitch || 100)
      rescue StandardError => e
        $stderr.puts "[RGSS] title BGM playback failed: #{e.message}"
      end
    end

    # First walkable map slice: renders the three tile layers as placeholder
    # colour blocks (real chipset/autotile blitting is future work), draws the
    # party leader from its Character graphic and moves it on the grid with pixel
    # interpolation, tileset collision and an edge-clamped follow camera. Map
    # events are drawn as markers for now; running their command lists is the
    # next milestone.
    class Map < Base
      TILE = RPGXP::TILE
      SCREEN_W = RPGXP::WIDTH
      SCREEN_H = RPGXP::HEIGHT
      COLS = SCREEN_W / TILE + 1
      ROWS = SCREEN_H / TILE + 1
      SPEED = 4 # pixels/frame while stepping (must divide TILE)

      def initialize(parent, state)
        super parent
        @state = state
        @map = state.map
        @tileset = Game::TileSet.new(@db, @map.tileset_id)
        @charset = load_charset
        @tile_colors = {}

        @moving = false
        @move_count = 0
        @dest_x = @state.x
        @dest_y = @state.y
        @last_frame = nil

        collect_events
        setup_sprites
        render
      end

      attr_reader :state

      def dispose
        [@lower_sprite, @upper_sprite, @player_sprite].each { |s| s.dispose if s }
      end

      def update
        step_movement
        render
      end

      private

      def load_charset
        actor = @state.leader
        return nil unless actor
        name = actor.character_name
        return nil if name.nil? || name.empty?
        Bitmap.new "Graphics/Characters/#{name}"
      rescue StandardError => e
        $stderr.puts "[RGSS] leader charset load failed, using marker: #{e.message}"
        nil
      end

      # Cache the tiles map events occupy so they can be drawn and collided with.
      def collect_events
        @event_tiles = {}
        (@map.events || {}).each do |_id, ev|
          @event_tiles[[ev.x, ev.y]] = ev
        end
      rescue StandardError => e
        $stderr.puts "[RGSS] event collection failed: #{e.message}"
        @event_tiles = {}
      end

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
        pw = @charset ? Game::CharSet.cell_width(@charset) : TILE
        ph = @charset ? Game::CharSet.cell_height(@charset) : TILE
        @player_bmp = Bitmap.new(pw, ph)
        @player_sprite.bitmap = @player_bmp
        unless @charset
          @player_bmp.fill_rect 4, 0, TILE - 8, ph, Color.new(240, 240, 80, 255)
        end
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
        return false unless in_bounds?(x, y)
        return false if @event_tiles[[x, y]]
        @tileset.passable?(@map, x, y, dir)
      end

      def in_bounds?(x, y)
        x >= 0 && y >= 0 && x < @map.width && y < @map.height
      end

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

        pw = @player_bmp.width
        ph = @player_bmp.height
        @player_sprite.x = px - cam_x - (pw - TILE) / 2
        @player_sprite.y = py - cam_y - (ph - TILE)
        draw_player_frame
      end

      def draw_layers(cam_x, cam_y)
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
            next unless in_bounds?(tx, ty)
            dx = rx * TILE - ox
            dy = ry * TILE - oy

            # Layers 0/1 to the lower sprite, layer 2 to the upper (drawn above
            # the player), matching RMXP's three-layer stack.
            b0 = @map.data[tx, ty, 0]
            b1 = @map.data[tx, ty, 1]
            @lower_bmp.fill_rect dx, dy, TILE, TILE, tile_color(b0)
            @lower_bmp.fill_rect dx, dy, TILE, TILE, tile_color(b1) if b1 && b1 != 0

            top = @map.data[tx, ty, 2]
            @upper_bmp.fill_rect dx, dy, TILE, TILE, tile_color(top) if top && top != 0

            if @event_tiles[[tx, ty]]
              @lower_bmp.fill_rect dx + 4, dy + 4, TILE - 8, TILE - 8,
                                   Color.new(230, 90, 90, 255)
            end
          end
        end
      end

      def draw_player_frame
        return unless @charset
        pat = @moving ? Game::CharSet::PATTERNS[(@move_count / 8) % 4] : 0
        frame = [@state.direction, pat]
        return if frame == @last_frame
        @last_frame = frame
        rect = Game::CharSet.frame_rect(@charset, @state.direction, pat)
        @player_bmp.clear
        @player_bmp.blt 0, 0, @charset, rect
      end

      # Deterministic placeholder colour per tile id (empty tiles are a dark
      # void), the same navigable stand-in the RPG2000 map scene uses.
      def tile_color(id)
        return (@void ||= Color.new(16, 16, 28, 255)) if id.nil? || id == 0
        @tile_colors[id] ||= Color.new(40 + (id * 37) % 180,
                                       40 + (id * 71) % 180,
                                       60 + (id * 143) % 160, 255)
      end
    end
  end
end

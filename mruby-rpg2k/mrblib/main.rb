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
  # The window is a Viewport that clips its contents to the window rectangle.
  # Rather than compositing everything into one Bitmap, three separate Sprites
  # are layered inside the viewport by their `z`: the windowskin (background +
  # frame), the selection cursor, and the contents (text and other graphics
  # drawn by callers). Keeping them apart means updating the cursor or the text
  # no longer forces the skin to be re-blitted.
  class Window
    # Windows are drawn above ordinary background sprites (which default to
    # z == 0), so give the backing viewport a high z by default.
    DEFAULT_Z = 100

    # Thickness of the RPG2k frame border, in pixels.
    BORDER = 8

    # z of each layer within the window's viewport (skin at the back, text on
    # top, cursor highlight sandwiched between them).
    SKIN_Z = 0
    CURSOR_Z = 1
    CONTENTS_Z = 2

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

      # The viewport groups and clips the three layers to the window rect.
      @viewport = Viewport.new(x, y, [width, 1].max, [height, 1].max)
      @viewport.z = DEFAULT_Z

      @skin_sprite = Sprite.new(@viewport)
      @skin_sprite.z = SKIN_Z
      @cursor_sprite = Sprite.new(@viewport)
      @cursor_sprite.z = CURSOR_Z
      # Contents are drawn inside the frame, so offset the sprite by the border.
      @contents_sprite = Sprite.new(@viewport)
      @contents_sprite.z = CONTENTS_Z
      @contents_sprite.x = BORDER
      @contents_sprite.y = BORDER
      @contents_sprite.visible = false

      allocate_skin
    end

    attr_reader :x, :y, :width, :height, :contents, :windowskin, :cursor_rect
    attr_reader :active, :visible

    def x=(v)
      @x = v
      update_rect
    end

    def y=(v)
      @y = v
      update_rect
    end

    def z=(v)
      @viewport.z = v
    end

    def width=(v)
      @width = v
      allocate_skin
      update_rect
    end

    def height=(v)
      @height = v
      allocate_skin
      update_rect
    end

    def windowskin=(bmp)
      @windowskin = bmp
      draw_skin
      bmp
    end

    def contents=(bmp)
      @contents = bmp
      @contents_sprite.visible = !bmp.nil?
      @contents_sprite.bitmap = bmp if bmp
      bmp
    end

    def cursor_rect=(rect)
      @cursor_rect = rect
      draw_cursor
      rect
    end

    def active=(v)
      @active = v
      draw_cursor
    end

    def visible=(v)
      @visible = v
      @viewport.visible = v
    end

    # Present so the game loop can drive per-frame behaviour (cursor blinking,
    # etc.). The cursor is drawn steadily for now, so this is a no-op.
    def update; end

    def dispose
      # Dispose the layers before the viewport so each Sprite tears its own
      # LVGL object down; disposing the viewport then only frees the frame.
      [@skin_sprite, @cursor_sprite, @contents_sprite].each(&:dispose)
      @viewport.dispose
    end

    private

    # Move/resize the viewport to track the window rectangle.
    def update_rect
      @viewport.rect = Rect.new(@x, @y, [@width, 1].max, [@height, 1].max)
    end

    # (Re)create the skin and cursor bitmaps whenever the window is resized,
    # then redraw both layers.
    def allocate_skin
      @skin_bmp = Bitmap.new([@width, 1].max, [@height, 1].max)
      @skin_sprite.bitmap = @skin_bmp
      @cursor_bmp = Bitmap.new([@width, 1].max, [@height, 1].max)
      @cursor_sprite.bitmap = @cursor_bmp
      draw_skin
      draw_cursor
    end

    # Redraw the windowskin layer (background + frame, or the fallback panel).
    def draw_skin
      @skin_bmp.clear
      if @windowskin
        draw_background
        draw_frame
      else
        draw_fallback
      end
    end

    # Stretch the 32x32 background tile over the whole window; the frame border
    # is drawn on top of its outer edge afterwards.
    def draw_background
      @skin_bmp.stretch_blt Rect.new(0, 0, @width, @height), @windowskin,
                            Rect.new(0, 0, 32, 32)
    end

    def draw_frame
      w = @width
      h = @height
      b = BORDER
      sk = @windowskin

      # Corners (8x8, drawn 1:1).
      @skin_bmp.blt 0, 0, sk, Rect.new(32, 0, b, b)
      @skin_bmp.blt w - b, 0, sk, Rect.new(56, 0, b, b)
      @skin_bmp.blt 0, h - b, sk, Rect.new(32, 24, b, b)
      @skin_bmp.blt w - b, h - b, sk, Rect.new(56, 24, b, b)

      # Edges (stretched along the free axis).
      @skin_bmp.stretch_blt Rect.new(b, 0, w - 2 * b, b), sk,
                            Rect.new(40, 0, 16, b)
      @skin_bmp.stretch_blt Rect.new(b, h - b, w - 2 * b, b), sk,
                            Rect.new(40, 24, 16, b)
      @skin_bmp.stretch_blt Rect.new(0, b, b, h - 2 * b), sk,
                            Rect.new(32, 8, b, 16)
      @skin_bmp.stretch_blt Rect.new(w - b, b, b, h - 2 * b), sk,
                            Rect.new(56, 8, b, 16)
    end

    # Used when no windowskin could be loaded: a plain dark panel with a light
    # border so the window is still visible.
    def draw_fallback
      @skin_bmp.fill_rect 0, 0, @width, @height, Color.new(8, 8, 40, 224)
      edge = Color.new(200, 200, 216, 255)
      @skin_bmp.fill_rect 0, 0, @width, 1, edge
      @skin_bmp.fill_rect 0, @height - 1, @width, 1, edge
      @skin_bmp.fill_rect 0, 0, 1, @height, edge
      @skin_bmp.fill_rect @width - 1, 0, 1, @height, edge
    end

    # Highlight box behind the selected item, on its own layer. cursor_rect is
    # expressed in contents coordinates, so it is offset by the border
    # thickness (the contents layer carries the same offset).
    def draw_cursor
      @cursor_bmp.clear
      return unless @active
      r = @cursor_rect
      return if r.width <= 0 || r.height <= 0

      # fill_rect overwrites (it does not alpha-blend onto the window
      # background), so use an opaque highlight: a solid blue bar with a
      # brighter border, matching the reference title screen's selection box.
      x = BORDER + r.x
      y = BORDER + r.y
      @cursor_bmp.fill_rect x, y, r.width, r.height, Color.new(24, 40, 176, 255)
      border = Color.new(180, 200, 255, 255)
      @cursor_bmp.fill_rect x, y, r.width, 1, border
      @cursor_bmp.fill_rect x, y + r.height - 1, r.width, 1, border
      @cursor_bmp.fill_rect x, y, 1, r.height, border
      @cursor_bmp.fill_rect x + r.width - 1, y, 1, r.height, border
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

      # Load the System/ windowskin declared in the database (nil when missing,
      # so Window falls back to a plain panel).
      def make_windowskin
        name = @db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}"
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end
    end

    # Adapter that exposes the running map to the movement engine
    # (Game::MoveRoute / Game::MoveType). It bridges their small `world` protocol
    # — passability, hero position, switch and sound side effects, randomness —
    # onto the owning Scene::Map and its Game::State.
    class MapWorld
      def initialize(scene, rng)
        @scene = scene
        @rng = rng
      end

      def passable?(character, dir)
        @scene.char_passable?(character, dir)
      end

      def hero_position
        s = @scene.state
        [s.x, s.y]
      end

      def set_switch(id, on)
        @scene.state.switches[id] = on
      end

      def play_sound(name, volume, tempo, _balance)
        return if name.nil? || name.empty?
        RGSS::Audio.se_play(name, volume, tempo)
      rescue StandardError
        nil
      end

      def random(n)
        @rng.random(n)
      end
    end

    # Play scene: renders the loaded map and lets the party leader walk around
    # it. Tiles are drawn as solid colour blocks derived from their tile id (a
    # placeholder until real chipset blitting lands — see docs/TODO.md); the
    # player is drawn from its real CharSet graphic. Movement is grid based with
    # smooth pixel interpolation, walk animation, tile/edge/event collision and
    # a camera that follows the player and clamps to the map edges. Events roam
    # the map per their page's movement type (random / vertical / horizontal /
    # toward or away from the hero) or run a custom move route.
    class Map < Base
      TILE = Game::TILE
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      # Visible tiles plus a one-tile margin so partially scrolled edges show.
      COLS = SCREEN_W / TILE + 1
      ROWS = SCREEN_H / TILE + 1
      # Pixels moved per frame while stepping between tiles (must divide TILE).
      SPEED = 2

      # Frames waited between autonomous event steps, keyed by RPG2000 move
      # frequency (1 slowest .. 8 fastest). Placeholder pacing while events are
      # drawn as markers (no per-step pixel interpolation yet).
      EVENT_MOVE_DELAY = { 1 => 96, 2 => 64, 3 => 40, 4 => 24,
                           5 => 12, 6 => 6, 7 => 3, 8 => 1 }.freeze

      def initialize parent, state
        super parent
        @state = state
        @map = state.map
        @chipset = build_chipset
        @charset = load_charset
        @windowskin = load_windowskin
        @interpreter = Game::Interpreter.new(@state)
        @started_auto = {}
        @started_common = {}
        @common = Game::CommonEvent.load(@db)
        # Deterministic RNG (mruby has no Kernel#rand here) and the adapter that
        # lets move routes / autonomous movement query the map.
        @rng = Game::Rng.new(0x2000)
        @world = MapWorld.new(self, @rng)
        build_events
        @message = nil
        @wait_timer = nil
        @choice_index = 0

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
        close_message
        [@lower_sprite, @upper_sprite, @player_sprite].each do |s|
          s.dispose if s
        end
      end

      def update
        @state.tick_timer # the timer keeps counting during events too
        if event_busy?
          drive_event
        else
          start_autostart
          if event_busy?
            drive_event
          else
            step_events
            step_movement
            try_action_trigger
            try_open_menu
          end
        end
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

      # Load the System/ windowskin for message windows (nil -> plain panel).
      def load_windowskin
        name = @db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      # Build the runtime event list for the current map: the active page of
      # each event (per switch/variable/party conditions) becomes a movable
      # Game::Character, tagged with its trigger, command list and how it moves
      # (autonomous move type, or a custom Game::MoveRoute). @event_tiles caches
      # the tiles events occupy, for collision and markers.
      def build_events
        @events = []
        @event_tiles = {}
        evs = @map.unit.events
        return unless evs
        evs.each do |id, ev|
          selected = Game::EventPage.select(ev.pages, @state.switches,
                                            @state.variables, @state.party)
          next unless selected
          page = selected[1]
          @events.push(build_event(id, ev, page))
        end
        rebuild_event_tiles
      rescue StandardError
        @events = []
        @event_tiles = {}
      end

      def build_event(id, ev, page)
        ch = Game::Character.new(ev.x, ev.y, page_direction(page))
        ch.move_speed = page_move_speed(page)
        ch.move_frequency = page_move_frequency(page)
        ch.set_graphic(page_charset_name(page), page_charset_index(page))
        move_type = page_move_type(page)
        route = move_type == Game::MoveType::CUSTOM ?
                Game::MoveRoute.from_page(page_move_route(page)) : nil
        { id: id, char: ch, trigger: page_trigger(page),
          commands: page_commands(page), move_type: move_type, route: route,
          move_timer: EVENT_MOVE_DELAY[ch.move_frequency] || 40 }
      end

      # Recompute the occupied-tile set from the events' current positions.
      def rebuild_event_tiles
        @event_tiles = {}
        @events.each { |e| @event_tiles[[e[:char].x, e[:char].y]] = e }
      end

      def page_trigger(page); page.trigger; rescue StandardError; 0; end
      def page_commands(page); page.event_commands; rescue StandardError; nil; end
      def page_direction(page); d = page.direction; d && d > 0 ? d : 2; rescue StandardError; 2; end
      def page_move_type(page); page.move_type || 0; rescue StandardError; 0; end
      def page_move_speed(page); page.move_speed || 3; rescue StandardError; 3; end
      def page_move_frequency(page); page.move_frequency || 3; rescue StandardError; 3; end
      def page_move_route(page); page.move_route; rescue StandardError; nil; end
      def page_charset_name(page); page.charset_name; rescue StandardError; nil; end
      def page_charset_index(page); page.charset_index || 0; rescue StandardError; 0; end

      # -- event execution ----------------------------------------------------

      def event_busy?
        @message || @interpreter.running? || @interpreter.waiting?
      end

      # Start the first eligible not-yet-run auto-start/parallel process: map
      # events with an auto-start trigger, then eligible common events. Each is
      # started at most once per visit so an ungated process cannot hard-loop.
      def start_autostart
        ev = @events.find do |e|
          e[:trigger] == 3 && e[:commands] && !@started_auto[e[:id]]
        end
        if ev
          @started_auto[ev[:id]] = true
          @interpreter.start(ev[:commands])
          return
        end

        ce = Game::CommonEvent.eligible(@common, @state.switches).find do |c|
          c[:commands] && !@started_common[c[:id]]
        end
        return unless ce
        @started_common[ce[:id]] = true
        @interpreter.start(ce[:commands])
      end

      # On the action button, run the event the player is facing (trigger 0).
      # The faced event turns toward the player before its commands run.
      def try_action_trigger
        return unless Input.trigger?(Input::C)
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        ev = @events.find do |e|
          e[:char].x == fx && e[:char].y == fy && e[:trigger] == 0 && e[:commands]
        end
        return unless ev
        ev[:char].face(Game::Character::TURN_180[@state.direction] || 2)
        @interpreter.start(ev[:commands])
      end

      # Advance autonomous / custom-route event movement one frame. Skipped
      # while an event process is running so the map holds still during messages.
      def step_events
        @events.each { |e| step_event(e) }
      end

      def step_event(e)
        ch = e[:char]
        e[:move_timer] -= 1
        return if e[:move_timer] > 0
        e[:move_timer] = EVENT_MOVE_DELAY[ch.move_frequency] || 40
        ox = ch.x
        oy = ch.y
        if e[:route]
          e[:route].step(ch, @world) unless e[:route].done?
        else
          dir = Game::MoveType.next_direction(e[:move_type], ch, @world)
          # Bumping into an obstacle still turns the event to face it.
          @world.passable?(ch, dir) ? ch.move(dir) : ch.face(dir) if dir
        end
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy
      rescue StandardError
        nil
      end

      # Update the occupied-tile cache after event `e` moved off (ox, oy). Done
      # eagerly (rather than a single end-of-frame rebuild) so an event that has
      # already moved this frame blocks the next event from stepping onto it.
      def reoccupy(e, ox, oy)
        @event_tiles.delete([ox, oy]) if @event_tiles[[ox, oy]].equal?(e)
        @event_tiles[[e[:char].x, e[:char].y]] = e
      end

      # Collision test for an event stepping one tile in `dir`: in bounds, not
      # onto the player or another event, and passable per the chipset. A
      # "through" character ignores all of this. Only the destination tile is
      # tested, so a character never blocks itself (it stands on its own tile,
      # not the one ahead).
      def char_passable?(character, dir)
        return true if character.through
        nx, ny = Game::Character.step_tile(character.x, character.y, dir)
        return false unless @map.in_bounds?(nx, ny)
        return false if nx == @state.x && ny == @state.y
        return false if @event_tiles[[nx, ny]]
        return true if @chipset.nil?
        @chipset.passable?(@map.lower(nx, ny), dir)
      end
      # Called by MapWorld (an external collaborator) with an explicit receiver.
      public :char_passable?

      # The cancel button opens the main menu over the map.
      def try_open_menu
        return unless Input.trigger?(Input::B)
        @parent.push Scene::Menu.new(@parent, @state)
      end

      def drive_event
        if @message
          drive_message
          return
        end

        if @interpreter.waiting?
          case @interpreter.wait_kind
          when :message then open_message(@interpreter.message_lines, false)
          when :choice then open_message(@interpreter.choice_labels, true)
          when :wait then drive_wait
          when :teleport then perform_teleport(@interpreter.teleport)
          end
        else
          @interpreter.update
        end
      end

      def drive_wait
        if @wait_timer.nil?
          fr = Graphics.frame_rate
          fr = 60 if fr.nil? || fr <= 0
          @wait_timer = @interpreter.wait_frames * fr / 10
        end
        if @wait_timer <= 0
          @wait_timer = nil
          @interpreter.resume
        else
          @wait_timer -= 1
        end
      end

      def perform_teleport(t)
        map_id, x, y, dir = t
        @map = @parent.load_map(map_id)
        @state.map = @map
        @state.map_id = map_id
        @state.x = x
        @state.y = y
        @state.direction = dir if dir && dir > 0
        @chipset = build_chipset
        @started_auto = {}
        @started_common = {}
        build_events
        @moving = false
        @move_count = 0
        @last_frame = nil
        @interpreter.stop
      rescue StandardError => e
        $stderr.puts "[RPG2k] Teleport failed: #{e.message}"
        @interpreter.stop
      end

      # -- message / choice window --------------------------------------------

      MSG_LINE_H = 14

      # Look up an actor name by id for the \n[] message control code.
      def actor_name(id)
        a = @db.player[id]
        a ? a.name.to_s : ''
      rescue StandardError
        ''
      end

      def open_message(lines, choice)
        return if @message
        names = ->(id) { actor_name(id) }
        lines = (lines || []).map do |l|
          Game::Message.expand(l.to_s, @state.variables, names)
        end
        lines = [''] if lines.empty?
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = lines.length * MSG_LINE_H
        win = Window.new(10, SCREEN_H - (inner_h + Window::BORDER * 2) - 6,
                         SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin

        contents = Bitmap.new(inner_w, inner_h)
        contents.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          contents.draw_text 0, i * MSG_LINE_H, inner_w, MSG_LINE_H, line
        end
        win.contents = contents

        @message = { window: win, choice: choice, count: lines.length }
        @choice_index = 0
        set_choice_cursor if choice
      end

      def set_choice_cursor
        return unless @message
        @message[:window].cursor_rect =
          Rect.new(0, @choice_index * MSG_LINE_H,
                   @message[:window].contents.width, MSG_LINE_H)
      end

      def drive_message
        if @message[:choice]
          if Input.trigger?(Input::DOWN) && @choice_index < @message[:count] - 1
            @choice_index += 1
            set_choice_cursor
          elsif Input.trigger?(Input::UP) && @choice_index > 0
            @choice_index -= 1
            set_choice_cursor
          elsif Input.trigger?(Input::C)
            index = @choice_index
            close_message
            @interpreter.choose(index)
          end
        elsif Input.trigger?(Input::C) || Input.trigger?(Input::B)
          close_message
          @interpreter.resume
        end
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
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

    # Main menu, opened over the map with the cancel button. Shows party status
    # and a command list. Save and End Game are wired up; the item/skill/equip/
    # status screens are placeholders that report they are not implemented.
    class Menu < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      LINE_H = 16
      COMMANDS = ["Item", "Skill", "Equip", "Status", "Save", "End Game"].freeze

      def initialize parent, state
        super parent
        @state = state
        @index = 0
        @message = nil
        @skin = make_windowskin
        build_windows
      end

      def dispose
        close_message
        @command.dispose if @command
        @status.dispose if @status
      end

      def update
        return drive_message if @message

        if Input.trigger?(Input::DOWN) && @index < COMMANDS.size - 1
          @index += 1
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @index > 0
          @index -= 1
          refresh_cursor
        elsif Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::C)
          select_command
        end
      end

      private

      def build_windows
        cw = 108
        @command = Window.new(0, 0, cw, COMMANDS.size * LINE_H + Window::BORDER * 2)
        @command.z = 400
        @command.windowskin = @skin
        cc = Bitmap.new(cw - Window::BORDER * 2, COMMANDS.size * LINE_H)
        cc.font.color = Color.new(255, 255, 255, 255)
        COMMANDS.each_with_index do |c, i|
          cc.draw_text 0, i * LINE_H + 2, cc.width, LINE_H, c
        end
        @command.contents = cc
        refresh_cursor

        @status = Window.new(cw, 0, SCREEN_W - cw, SCREEN_H)
        @status.z = 400
        @status.windowskin = @skin
        sc = Bitmap.new(SCREEN_W - cw - Window::BORDER * 2, SCREEN_H - Window::BORDER * 2)
        sc.font.color = Color.new(255, 255, 255, 255)
        @state.party.actors.each_with_index do |a, i|
          y = i * 40
          sc.draw_text 0, y, sc.width, 14, a.name.to_s
          sc.draw_text 0, y + 16, sc.width, 14,
                       "Lv #{a.level}  HP #{a.hp}/#{a.max_hp}  MP #{a.mp}/#{a.max_mp}"
        end
        @status.contents = sc
      end

      def refresh_cursor
        @command.cursor_rect =
          Rect.new(0, @index * LINE_H, @command.contents.width, LINE_H)
      end

      def select_command
        case COMMANDS[@index]
        when "Save"
          show_message(@parent.save_game(@state) ? "Game saved." : "Save failed.")
        when "End Game"
          show_message("Returning to title...", :end_game)
        else
          show_message("#{COMMANDS[@index]} is not implemented yet.")
        end
      end

      def drive_message
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        done = @message[:done]
        close_message
        @parent.return_to_title if done == :end_game
      end

      def show_message(text, done = nil)
        return if @message
        w = SCREEN_W - 40
        win = Window.new(20, SCREEN_H - 40, w, 14 + Window::BORDER * 2)
        win.z = 500
        win.windowskin = @skin
        c = Bitmap.new(w - Window::BORDER * 2, 14)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, 14, text
        win.contents = c
        @message = { window: win, done: done }
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message = nil
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
          play_cursor_se
          refresh_cursor
        elsif Input.trigger?(Input::UP) && @selected_index > 0
          @selected_index -= 1
          play_cursor_se
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
        Bitmap.new "System/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      def refresh_cursor
        @window.cursor_rect =
          Rect.new(0, @selected_index * LINE_HEIGHT, @window.contents.width,
                   LINE_HEIGHT)
      end

      # Play the database's "cursor move" sound effect (System > cursor SE) when
      # the menu selection changes. A no-op when the game defines no cursor SE,
      # the file is missing, or no audio backend is installed.
      def play_cursor_se
        se = db.system.cursor_se
        return unless se
        name = se.file
        return if name.nil? || name.empty?
        Audio.se_play name, se.volume, se.pitch
      rescue StandardError => e
        $stderr.puts "[RGSS] cursor SE playback failed: #{e.message}"
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

  # Pop the top scene (e.g. closing the menu), disposing it. The base scene is
  # never popped so the loop always has something to update.
  def pop
    return if @scenes.size <= 1
    scene = @scenes.pop
    scene.dispose if scene.respond_to?(:dispose)
  end

  # Tear down all scenes and return to a fresh title screen.
  def return_to_title
    @scenes.each { |s| s.dispose if s.respond_to?(:dispose) }
    @scenes = [Scene::Title.new(self)]
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

  # Save file path for a slot. We use our own portable Marshal format rather
  # than the LCF .lsd save schema (which is not modelled yet).
  def save_path slot = 1
    "#{GAME_DIR}/save#{slot}.mrb"
  end

  def save_exists? slot = 1
    File.exist? save_path(slot)
  rescue StandardError
    false
  end

  # Persist the running game state to a slot.
  def save_game state, slot = 1
    data = Marshal.dump state.to_h
    File.open(save_path(slot), "wb") { |f| f.write data }
    true
  rescue StandardError => e
    $stderr.puts "[RPG2k] Failed to save: #{e.message}"
    false
  end

  # Continue: load the most recent save (our Marshal format) and resume on its
  # map. Warns and stays on the title when there is no save to load.
  def continue_game
    unless save_exists?
      RGSS.warn_stub "Continue (no save data found)"
      return
    end
    data = File.open(save_path, "rb") { |f| f.read }
    state = Game::State.load(@db, Marshal.load(data))
    state.map = load_map state.map_id
    scene = Scene::Map.new(self, state)
    @scenes.last.dispose
    @scenes = [scene]
  rescue StandardError => e
    $stderr.puts "[RPG2k] Failed to continue: #{e.message}"
  end

  def main_loop
    RGSS::Profiler.frame do
      RGSS::Profiler.section("scene.update") { @scenes.last.update }
      RGSS::Profiler.section("input.update") { Input.update }
      Graphics.update
    end
  end

  def start
    loop do
      main_loop
    end
  rescue RGSS::Timeout
  end
end

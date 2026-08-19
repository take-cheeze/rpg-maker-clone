class RPG2k
  module Scene
    # Debug-only overview of the whole current map, opened from the F9 debug
    # menu's Map page (see DebugMenu#activate_row). Existing tools -- the
    # ordinary field view and the Switch/Variable pages -- only ever show a
    # 320x240 window onto the map or a couple of numbers; neither answers "am I
    # actually standing where I think I am" on a map bigger than one screen.
    # This draws the whole thing at one pixel per tile (passable tiles green,
    # blocked ones dark red, tiles with no chipset data grey), plus a marker
    # for the player and one for each currently-active map event, so that's
    # visible at a glance.
    #
    # Reads only Game::State and a Game::ChipSet rebuilt the same way
    # Scene::Map builds its own (see #build_chipset there) -- it never writes
    # anything back and never touches the on-disk project, so it cannot drift
    # from or collide with a real RPG Maker project the way an authoring tool
    # would.
    #
    # Arrow keys pan the viewport when the map doesn't fit on screen at once;
    # C recentres on the player; B closes back to the debug menu.
    class MapViewer < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      HEADER_H = 16
      FOOTER_H = 16
      PAN_STEP = 8

      PASSABLE_COLOR = Color.new(64, 160, 64, 255)
      BLOCKED_COLOR = Color.new(160, 48, 48, 255)
      UNKNOWN_COLOR = Color.new(96, 96, 96, 255)
      PLAYER_COLOR = Color.new(255, 255, 0, 255)
      EVENT_COLOR = Color.new(80, 200, 255, 255)
      TEXT_COLOR = Color.new(255, 255, 255, 255)
      HINT_COLOR = Color.new(200, 200, 200, 255)

      def initialize(parent, state)
        super parent
        @state = state
        @map = state.map
        @chipset = build_chipset
        @skin = make_windowskin
        @background = build_field_background(@skin)
        @window = Window.new(0, 0, SCREEN_W, SCREEN_H)
        @window.z = 400
        @window.windowskin = @skin
        @contents = Bitmap.new(SCREEN_W - Window::BORDER * 2, SCREEN_H - Window::BORDER * 2)
        @window.contents = @contents
        @view_w = @contents.width
        @view_h = @contents.height - HEADER_H - FOOTER_H
        @pannable = @map && (@map.width > @view_w || @map.height > @view_h)
        @ox = 0
        @oy = 0
        center_on_player
        refresh
      end

      def dispose
        @background.dispose if @background
        @window.dispose if @window
      end

      def update
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::C)
          center_on_player
          refresh
        elsif @pannable
          refresh if pan
        end
      end

      private

      def build_chipset
        return nil unless @map
        Game::ChipSet.new(@db, @map.chipset_id)
      rescue StandardError => e
        $stderr.puts "[RPG2k] map viewer chipset load failed, tiles shown as " \
                     "unknown: #{e.message}"
        nil
      end

      # Handles one frame of held-arrow panning, clamped to the map edges.
      # Returns whether the viewport actually moved (so the caller only pays
      # for a redraw when something changed).
      def pan
        moved = false
        if (Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)) && @ox.positive?
          @ox = [@ox - PAN_STEP, 0].max
          moved = true
        elsif (Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)) && @ox < max_ox
          @ox = [@ox + PAN_STEP, max_ox].min
          moved = true
        end
        if (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && @oy.positive?
          @oy = [@oy - PAN_STEP, 0].max
          moved = true
        elsif (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) && @oy < max_oy
          @oy = [@oy + PAN_STEP, max_oy].min
          moved = true
        end
        moved
      end

      def max_ox
        return 0 unless @map
        [@map.width - @view_w, 0].max
      end

      def max_oy
        return 0 unless @map
        [@map.height - @view_h, 0].max
      end

      def center_on_player
        return unless @map
        @ox = clamp(@state.x - @view_w / 2, 0, max_ox)
        @oy = clamp(@state.y - @view_h / 2, 0, max_oy)
      end

      def clamp(v, lo, hi)
        return lo if v < lo
        return hi if v > hi
        v
      end

      def refresh
        @contents.clear
        draw_header
        draw_tiles
        draw_events
        draw_player
        draw_footer
      end

      def draw_header
        @contents.font.color = TEXT_COLOR
        text = @map ? "Map #{@map.id}  #{@map.width}x#{@map.height}  " \
                      "x:#{@state.x} y:#{@state.y}" : 'No map loaded'
        @contents.draw_text 0, 0, @contents.width, HEADER_H, text
      end

      def draw_footer
        @contents.font.color = HINT_COLOR
        hint = @pannable ? 'Arrows:Pan  C:Center  B:Close' : 'B:Close'
        @contents.draw_text 0, HEADER_H + @view_h, @contents.width, FOOTER_H, hint
      end

      def draw_tiles
        return unless @map
        (0...@view_h).each do |vy|
          my = @oy + vy
          break if my >= @map.height
          (0...@view_w).each do |vx|
            mx = @ox + vx
            break if mx >= @map.width
            @contents.set_pixel vx, HEADER_H + vy, tile_color(mx, my)
          end
        end
      end

      def tile_color(x, y)
        return UNKNOWN_COLOR unless @chipset
        passable = @chipset.landable_tile?(@map.lower(x, y), @map.upper(x, y))
        passable ? PASSABLE_COLOR : BLOCKED_COLOR
      end

      # Every event the map unit names, at its live wandered position when one
      # has been recorded (Scene::Map#record_map_event_positions) or its
      # authored spawn point otherwise. This state has no record of which
      # events an Erase Event command removed this visit (that flag lives on
      # the running Scene::Map, not Game::State), so a freshly-erased event
      # can still show a marker here until the map is re-entered.
      def draw_events
        return unless @map
        events = @map.unit.events
        return unless events
        positions = @state.map_event_positions || {}
        events.each do |id, ev|
          pos = positions[id]
          x = pos ? pos[0] : ev.x
          y = pos ? pos[1] : ev.y
          mark(x, y, EVENT_COLOR)
        end
      end

      def draw_player
        mark(@state.x, @state.y, PLAYER_COLOR)
      end

      def mark(x, y, color)
        vx = x - @ox
        vy = y - @oy
        return if vx.negative? || vy.negative? || vx >= @view_w || vy >= @view_h
        @contents.fill_rect vx - 1, HEADER_H + vy - 1, 3, 3, color
      end
    end
  end
end

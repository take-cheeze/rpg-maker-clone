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
    # C recentres on the player; R enters Select mode, a single-tile cursor
    # (arrow keys move it, viewport auto-scrolling to follow) that reports the
    # tile under it -- coordinates, passable/blocked, and the map event there,
    # if any -- and can teleport the player onto it with C. B backs out of
    # Select mode, or closes the viewer back to the debug menu if it is
    # already in pan mode.
    #
    # The teleport goes through Game::State#pending_teleport, the same queued-
    # warp mechanism a Teleport field skill uses (see Scene::ItemMenu/
    # SkillMenu#queue_teleport) -- Scene::Map picks it up and runs the real
    # Teleport-command machinery (reloading the map, replaying its access/BGM
    # setup) on its very next #update, rather than this scene hand-mutating
    # `@state.x`/`@state.y` and leaving that machinery unrun.
    #
    # L enters Edit mode instead -- this engine's actual Map Editor -- the same
    # cursor repurposed to paint. CTRL picks up the tile under the cursor (on
    # the active layer) as the brush; SHIFT swaps which layer (lower/upper) is
    # active; C stamps the brush onto the cursor's tile via Game::Map#set_lower
    # / #set_upper (an outright rewrite of that one cell, unlike Tile
    # Substitution's map-wide "every tile with this id" rewrite); R writes the
    # edited map back to its .lmu file. Edits are live the instant they're
    # painted either way (Scene::Map reads the same @lower/@upper arrays), so R
    # is only about persisting past this session, not about the edit taking
    # effect. Brushes only ever come from the eyedropper, never typed as a raw
    # id, so a painted tile is always one that already validly exists
    # somewhere on this map. This viewer still only ever shows passable/
    # blocked colour blocks, not real tile art (see #tile_color) -- painting
    # between two tiles with the same passability will not visibly change
    # anything here even though the underlying id did change.
    class MapViewer < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT
      HEADER_H = 16
      # Two lines tall: Edit mode's hint ('Arrows:Move  C:Paint  CTRL:Pick
      # SHIFT:Layer  R:Save  B:Exit') runs wider than the 320px screen on one
      # line and needs to wrap (see Base#draw_wrapped_hint) -- reserved
      # unconditionally, for every mode, so the viewport doesn't resize when
      # switching modes.
      FOOTER_H = HEADER_H * 2
      PAN_STEP = 8
      CURSOR_MARGIN = 2

      PASSABLE_COLOR = Color.new(64, 160, 64, 255)
      BLOCKED_COLOR = Color.new(160, 48, 48, 255)
      UNKNOWN_COLOR = Color.new(96, 96, 96, 255)
      PLAYER_COLOR = Color.new(255, 255, 0, 255)
      EVENT_COLOR = Color.new(80, 200, 255, 255)
      CURSOR_COLOR = Color.new(255, 255, 255, 255)
      TEXT_COLOR = Color.new(255, 255, 255, 255)
      HINT_COLOR = Color.new(200, 200, 200, 255)

      # `start_mode:` lets a caller that already knows it wants Edit (or
      # Select) mode skip the usual pan-mode landing page -- used by
      # RPG2k#open_map_editor (the --rpg2k_map_editor flag), which exists
      # specifically to skip navigating here by hand.
      def initialize(parent, state, start_mode: :pan)
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
        @mode = :pan
        @brush_layer = :lower
        @brush = 0
        @dirty = false
        @ox = 0
        @oy = 0
        center_on_player
        # #enter_edit_mode/#enter_select_mode already refresh when @map is
        # present, but a no-op (no map at all -- not the normal case, only
        # reachable if this scene is ever built without one) still needs the
        # unconditional #refresh below to draw its "No map loaded" screen.
        case start_mode
        when :edit then enter_edit_mode
        when :select then enter_select_mode
        end
        refresh
      end

      def dispose
        @background.dispose if @background
        @window.dispose if @window
      end

      def update
        case @mode
        when :select then update_select
        when :edit then update_edit
        else update_pan
        end
      end

      private

      def update_pan
        if Input.trigger?(Input::B)
          @parent.pop
        elsif Input.trigger?(Input::C)
          center_on_player
          refresh
        elsif Input.trigger?(Input::R)
          enter_select_mode
        elsif Input.trigger?(Input::L)
          enter_edit_mode
        elsif @pannable
          refresh if pan
        end
      end

      def update_select
        if Input.trigger?(Input::B) || Input.trigger?(Input::R)
          @mode = :pan
          refresh
        elsif Input.trigger?(Input::C)
          teleport_to_cursor
        elsif move_cursor
          refresh
        end
      end

      def update_edit
        if Input.trigger?(Input::B) || Input.trigger?(Input::L)
          @mode = :pan
          refresh
        elsif Input.trigger?(Input::C)
          paint_cursor
        elsif Input.trigger?(Input::CTRL)
          pick_brush
        elsif Input.trigger?(Input::SHIFT)
          @brush_layer = @brush_layer == :lower ? :upper : :lower
          refresh
        elsif Input.trigger?(Input::R)
          save_to_disk
        elsif move_cursor
          refresh
        end
      end

      def enter_select_mode
        return unless @map
        @mode = :select
        @cx = @state.x
        @cy = @state.y
        ensure_cursor_visible
        refresh
      end

      def enter_edit_mode
        return unless @map
        @mode = :edit
        @cx = @state.x
        @cy = @state.y
        ensure_cursor_visible
        refresh
      end

      def paint_cursor
        if @brush_layer == :lower
          @map.set_lower(@cx, @cy, @brush)
        else
          @map.set_upper(@cx, @cy, @brush)
        end
        @dirty = true
        refresh
      end

      def pick_brush
        @brush = @brush_layer == :lower ? @map.lower(@cx, @cy) : @map.upper(@cx, @cy)
        refresh
      end

      def save_to_disk
        @map.sync_layers_to_unit
        @map.unit.save_to(@parent.map_path(@map.id))
        @dirty = false
        refresh
      rescue StandardError => e
        $stderr.puts "[RPG2k] map editor save failed: #{e.message}"
      end

      # One tile per press/repeat, unlike #pan's fixed pixel step -- the
      # cursor is choosing a tile to inspect or warp to, not scrolling.
      def move_cursor
        moved = false
        max_cx = @map.width - 1
        max_cy = @map.height - 1
        if (Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)) && @cx.positive?
          @cx -= 1
          moved = true
        elsif (Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)) && @cx < max_cx
          @cx += 1
          moved = true
        end
        if (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && @cy.positive?
          @cy -= 1
          moved = true
        elsif (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) && @cy < max_cy
          @cy += 1
          moved = true
        end
        ensure_cursor_visible if moved
        moved
      end

      def ensure_cursor_visible
        @ox = clamp(scroll_to_fit(@cx, @ox, @view_w), 0, max_ox)
        @oy = clamp(scroll_to_fit(@cy, @oy, @view_h), 0, max_oy)
      end

      # The smallest scroll offset change that brings `pos` back inside
      # [offset, offset + extent) -- unchanged if it's in view already.
      def scroll_to_fit(pos, offset, extent)
        return pos if pos < offset
        return pos - extent + 1 if pos >= offset + extent
        offset
      end

      # Direction 0 leaves the player's facing as it was, the same convention
      # Scene::ItemMenu/SkillMenu#queue_teleport use for their own warps.
      def teleport_to_cursor
        @state.pending_teleport = [@map.id, @cx, @cy, 0]
        @parent.pop_to_map
      end

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
        draw_cursor
        draw_footer
      end

      def draw_header
        @contents.font.color = TEXT_COLOR
        text = case @mode
               when :select then select_header_text
               when :edit then edit_header_text
               else player_header_text
               end
        @contents.draw_text 0, 0, @contents.width, HEADER_H, text
      end

      def player_header_text
        return 'No map loaded' unless @map
        "Map #{@map.id}  #{@map.width}x#{@map.height}  x:#{@state.x} y:#{@state.y}"
      end

      def select_header_text
        color = tile_color(@cx, @cy)
        word = if color.equal?(BLOCKED_COLOR) then 'blocked'
               elsif color.equal?(PASSABLE_COLOR) then 'passable'
               else 'unknown'
               end
        ev = event_at(@cx, @cy)
        ev_text = ev ? "  Event ##{ev[0]} #{ev[1]}" : ''
        "Cursor x:#{@cx} y:#{@cy}  #{word}#{ev_text}"
      end

      def edit_header_text
        dirty = @dirty ? '  *unsaved*' : ''
        "Edit x:#{@cx} y:#{@cy}  layer:#{@brush_layer}  brush:#{@brush}#{dirty}"
      end

      # The id and name of the map event standing at (x, y), or nil -- shares
      # #each_event_position's live-position-over-spawn-point rule with
      # #draw_events, so the cursor reports the same place the marker is
      # actually drawn.
      def event_at(x, y)
        found = nil
        each_event_position { |id, name, ex, ey| found = [id, name] if ex == x && ey == y }
        found
      end

      def draw_footer
        @contents.font.color = HINT_COLOR
        hint = case @mode
               when :select
                 'Arrows:Move  C:Teleport  B:Cancel'
               when :edit
                 'Arrows:Move  C:Paint  CTRL:Pick  SHIFT:Layer  R:Save  B:Exit'
               else
                 @pannable ? 'Arrows:Pan  C:Center  R:Select  L:Edit  B:Close' \
                            : 'R:Select  L:Edit  B:Close'
               end
        draw_wrapped_hint(hint, HEADER_H + @view_h, HEADER_H)
      end

      # One #fill_rect per same-coloured horizontal run rather than one
      # #set_pixel per tile -- a naive per-tile pass is a native call for every
      # tile in the viewport (up to view_w * view_h, tens of thousands on a
      # full-screen viewport), cheap enough under SDL to pass unnoticed but
      # slow enough under the --sixel/--iterm terminal backends (already
      # paying per-frame encode cost, see ADR 0001/0003) to stall the whole
      # engine for several seconds on open, and every single frame while a
      # pan key is held. Real chipset data is overwhelmingly made of same-
      # passability blocks (a room's floor, a wall run), so this is a large
      # constant-factor win in the common case and never worse than the
      # per-tile pass in the checkerboard worst case.
      def draw_tiles
        return unless @map
        (0...@view_h).each do |vy|
          my = @oy + vy
          break if my >= @map.height
          draw_tile_row(vy, my)
        end
      end

      def draw_tile_row(vy, my)
        max_vx = [@view_w, @map.width - @ox].min
        run_start = 0
        run_color = nil
        y = HEADER_H + vy
        (0...max_vx).each do |vx|
          color = tile_color(@ox + vx, my)
          next if color.equal?(run_color)
          @contents.fill_rect run_start, y, vx - run_start, 1, run_color if run_color
          run_start = vx
          run_color = color
        end
        @contents.fill_rect run_start, y, max_vx - run_start, 1, run_color if run_color
      end

      def tile_color(x, y)
        return UNKNOWN_COLOR unless @chipset
        passable = @chipset.landable_tile?(@map.lower(x, y), @map.upper(x, y))
        passable ? PASSABLE_COLOR : BLOCKED_COLOR
      end

      def draw_events
        each_event_position { |_id, _name, x, y| mark(x, y, EVENT_COLOR) }
      end

      # Yields [id, name, x, y] for every event the map unit names, at its
      # live wandered position when one has been recorded
      # (Scene::Map#record_map_event_positions) or its authored spawn point
      # otherwise. Shared by #draw_events and #event_at so both agree on
      # where an event actually is. Neither knows which events an Erase Event
      # command removed this visit (that flag lives on the running Scene::Map,
      # not Game::State), so a freshly-erased event can still show up here
      # until the map is re-entered.
      def each_event_position
        return unless @map
        events = @map.unit.events
        return unless events
        positions = @state.map_event_positions || {}
        events.each do |id, ev|
          pos = positions[id]
          x = pos ? pos[0] : ev.x
          y = pos ? pos[1] : ev.y
          yield id, ev.name, x, y
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

      # A hollow box around the cursor tile, not a filled block like #mark --
      # it needs to stay legible sitting on top of the player or an event
      # marker, which it starts right on top of (Select mode opens on the
      # player's own tile).
      def draw_cursor
        return unless @mode == :select || @mode == :edit
        vx = @cx - @ox
        vy = @cy - @oy
        return if vx.negative? || vy.negative? || vx >= @view_w || vy >= @view_h
        x = vx - CURSOR_MARGIN
        y = HEADER_H + vy - CURSOR_MARGIN
        size = CURSOR_MARGIN * 2 + 1
        @contents.fill_rect x, y, size, 1, CURSOR_COLOR
        @contents.fill_rect x, y + size - 1, size, 1, CURSOR_COLOR
        @contents.fill_rect x, y, 1, size, CURSOR_COLOR
        @contents.fill_rect x + size - 1, y, 1, size, CURSOR_COLOR
      end
    end
  end
end

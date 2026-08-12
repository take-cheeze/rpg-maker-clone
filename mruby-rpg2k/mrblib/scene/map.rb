class RPG2k
  module Scene
    # Play scene: renders the loaded map and lets the party leader walk around
    # it. Tiles are blitted from the map's real ChipSet graphic via
    # Game::ChipsetLayout (lower/upper chips, water/terrain autotile assembly and
    # tile animation); if the chipset image is missing they fall back to solid
    # colour blocks derived from the tile id. The player is drawn from its real
    # CharSet graphic. Movement is grid based with
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

      # The screen flash a step's slip damage fires: a brief red pulse, so the
      # drain is not silent on a map that shows no HP. Given as the Game::Screen
      # flash arguments (r, g, b, power, frames) on the 0..255 scale, the same
      # one the battle-animation flashes reach by scaling their 0..31 database
      # colours up by 8.
      STEP_DAMAGE_FLASH = [31 * 8, 10 * 8, 10 * 8, 20 * 8, 6].freeze

      # Where the map viewport sits against the sprites drawn outside it. Under
      # the picture layer (250), so pictures, the message window and the
      # weather / flash / fade overlays all draw over a tinted map.
      MAP_VIEWPORT_Z = 100

      # Frames waited between autonomous event steps, keyed by RPG2000 move
      # frequency (1 slowest .. 8 fastest). Placeholder pacing while events are
      # drawn as markers (no per-step pixel interpolation yet).
      EVENT_MOVE_DELAY = { 1 => 96, 2 => 64, 3 => 40, 4 => 24,
                           5 => 12, 6 => 6, 7 => 3, 8 => 1 }.freeze

      # Rendered frames between walk-animation phase advances for an animating
      # event (a moving event or a continuous/spin animation type).
      ANIM_FRAME_PERIOD = 6

      # Event-page start conditions (the page `trigger` field): how the event's
      # command list is set off.
      TRIGGER_ACTION       = 0 # player presses the action button facing it
      TRIGGER_PLAYER_TOUCH = 1 # player walks into it
      TRIGGER_EVENT_TOUCH  = 2 # it walks into the player
      TRIGGER_AUTO_START   = 3 # runs automatically once on the map
      TRIGGER_PARALLEL     = 4 # runs continuously in the background

      # Move Event (Set Move Route) target ids: the player, the three vehicles
      # and "this event" (the event running the command). Any other id is a map
      # event id. Vehicles are not modelled yet, so those targets are ignored.
      MOVE_TARGET_PLAYER  = 10001
      MOVE_TARGET_BOAT    = 10002
      MOVE_TARGET_SHIP    = 10003
      MOVE_TARGET_AIRSHIP = 10004
      MOVE_TARGET_THIS    = 10005

      def initialize parent, state
        super parent
        @state = state
        @map = state.map
        @chipset = build_chipset
        @chipset_bmp = load_chipset_graphic
        @charset = load_charset
        @windowskin = load_windowskin
        @interpreter = Game::Interpreter.new(@state)
        @started_auto = {}
        @started_common = {}
        @common = Game::CommonEvent.load(@db)
        # Deterministic RNG (Kernel#rand exists but is unseeded, and these runs
        # are diffed against the genuine runtime) and the adapter that lets move
        # routes / autonomous movement query the map.
        @rng = Game::Rng.new(0x2000)
        @world = MapWorld.new(self, @rng)
        # Erased events, and the state revision the active pages were chosen at.
        @erased_events = {}
        @page_revision = page_revision
        build_events
        @interpreter.resolver = build_resolver
        @interpreter.map_info = self
        build_parallels
        @message = nil
        @inn_window = nil
        @shop = nil
        @battle_ui = nil
        @name_ui = nil
        @wait_timer = nil
        @anim_wait = nil
        @map_animation = nil
        # One window per timer (RPG2003 has two); built lazily when first shown.
        @timer_windows = [nil, nil]
        @timer_texts = [nil, nil]
        @pre_vehicle_bgm = nil
        @choice_index = 0
        # The map event whose commands the foreground interpreter is running, so
        # a Move Event targeting "this event" can be resolved. nil for common
        # events (which have no map character).
        @active_event = nil
        # A forced move route applied to the player by a Move Event, with its own
        # character mirror and step timer; nil when the player moves by input.
        @player_route = nil
        @player_char = nil
        @player_route_timer = 0

        # Player pixel position and step state. `player_jumping` marks the slide
        # as a hop, which is lifted along an arc (see player_jump_offset).
        @moving = false
        @move_count = 0
        @player_jumping = false
        @dest_x = @state.x
        @dest_y = @state.y
        @tile_colors = {}
        @last_frame = nil
        # Frame counter driving the chipset's water/animated-tile animation.
        @anim_frame = 0

        setup_sprites
        render
      end

      attr_reader :state

      def dispose
        close_message
        close_inn_window
        close_shop
        close_battle
        [@lower_sprite, @upper_sprite, @player_sprite, @parallax_sprite,
         @picture_sprite, @fade_sprite, @flash_sprite,
         @weather_sprite].each do |s|
          s.dispose if s
        end
        (@vehicle_sprites || {}).each_value { |s| s.dispose if s }
        (@timer_windows || []).each { |w| w.dispose if w }
        @airship_shadow.dispose if @airship_shadow
        @animation_sprite.dispose if @animation_sprite
        # After the sprites it holds, so nothing is orphaned inside it.
        @map_viewport.dispose if @map_viewport
        @flash_buffer.dispose if @flash_buffer
        @flash_out_buffer.dispose if @flash_out_buffer
        @chipset_bmp.dispose if @chipset_bmp
        @parallax_img.dispose if @parallax_img
      end

      def update
        # The timers keep counting during events too. A fight is running when the
        # battle UI is up, and a timer without the "run in battle" flag pauses
        # (and hides) for its duration rather than being stopped.
        @state.tick_timer(!@battle_ui.nil?)
        @state.screen.update # screen tint progresses every frame, even in events
        @state.update_pictures # picture moves progress every frame too
        update_sprite_flashes # Flash Sprite decays during events too
        watch_bgm_loop # so the "BGM played once" branch can be answered
        @anim_frame += 1 # water / animated tiles cycle even during events
        # An event page's conditions may have just stopped (or started) holding;
        # re-select before anything reads a trigger or a graphic this frame.
        refresh_event_pages
        if event_busy?
          drive_event
        else
          start_autostart
          if event_busy?
            drive_event
          else
            step_parallels
            step_player_route
            step_events
            step_movement
            # Boarding / disembarking claims the action button when it applies;
            # otherwise it falls through to the usual event trigger.
            try_action_trigger unless try_board_vehicle
            try_open_menu
          end
        end
        animate_events
        render
      end

      private

      def setup_sprites
        # Everything the map view is made of lives in one viewport, so RPG2000's
        # Tint Screen can be applied to all of it at once (see #update_map_tone).
        # A viewport is what carries a tone in RGSS, and it reaches the sprites
        # inside it and nothing else -- which is the distinction the screen tone
        # needs: the map is tinted, while the pictures above it (which carry
        # their own tone), the message window and the weather / flash / fade
        # overlays are not.
        @map_viewport = Viewport.new(0, 0, SCREEN_W, SCREEN_H)
        # Below the picture layer, so the z values inside keep their meaning
        # relative to each other while the whole map sits under everything that
        # draws over it.
        @map_viewport.z = MAP_VIEWPORT_Z

        @lower_sprite = Sprite.new(@map_viewport)
        @lower_sprite.z = 0
        @lower_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @lower_sprite.bitmap = @lower_bmp

        @upper_sprite = Sprite.new(@map_viewport)
        @upper_sprite.z = 200
        @upper_bmp = Bitmap.new(COLS * TILE, ROWS * TILE)
        @upper_sprite.bitmap = @upper_bmp

        @player_sprite = Sprite.new(@map_viewport)
        @player_sprite.z = 100
        @player_bmp = Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
        @player_sprite.bitmap = @player_bmp

        # One sprite per vehicle (drawn just under the hero, so a boarded party
        # sits on top). Hidden unless the vehicle is placed on the current map.
        @vehicle_sprites = {}
        @vehicle_bmps = {}
        Game::Vehicle::TYPES.each do |type|
          spr = Sprite.new(@map_viewport)
          spr.z = 99
          spr.visible = false
          bmp = Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
          spr.bitmap = bmp
          @vehicle_sprites[type] = spr
          @vehicle_bmps[type] = bmp
        end
        # The airship floats above the ground; a shadow sprite on the tile below
        # it sells the altitude. A squat translucent dark blob approximates it.
        @airship_shadow = Sprite.new(@map_viewport)
        @airship_shadow.z = 98 # under the vehicles, over the ground / events
        @airship_shadow.visible = false
        shadow = Bitmap.new(TILE, TILE)
        shadow.fill_rect 3, TILE - 8, TILE - 6, 5, Color.new(0, 0, 0, 96)
        @airship_shadow.bitmap = shadow

        # A screen-sized layer the Show Battle Animation renderer composites the
        # current frame's cells into, over the map (above the hero).
        @animation_sprite = Sprite.new(@map_viewport)
        @animation_sprite.z = 150
        @animation_sprite.visible = false
        @animation_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @animation_sprite.bitmap = @animation_bmp
        # Fallback marker when the CharSet graphic is unavailable.
        unless @charset
          @player_bmp.fill_rect 4, 0, TILE, Game::CharSet::HEIGHT,
                                Color.new(240, 240, 80, 255)
        end
        # CharSet graphics for events, loaded on demand and cached by name (a
        # cached nil marks a name that failed to load, so we log it once).
        @event_charsets = {}

        setup_parallax
        setup_pictures
        setup_screen_overlay
      end

      # The full-screen colour layers Erase/Show Screen (fade) and Flash Screen
      # draw. Both sit above everything, message window included -- RPG2000 fades
      # and flashes the whole screen, not just the map.
      #
      # No native work was needed for this, despite the note in docs/TODO.md that
      # it wanted "alpha-blend / viewport support in C++": RGSS::Sprite#opacity
      # already maps onto LVGL's per-object alpha at blit time, which is exactly
      # the per-sprite opacity RGSS specifies. So a screen-sized sprite of solid
      # colour, shown at the effect's strength, is the whole mechanism.
      #
      # The bitmaps are filled once and only re-filled when the colour changes
      # (never, for the always-black fade): a per-frame fill of the screen would
      # be 76800 pixel writes to produce the same image, where changing the
      # opacity is one property set.
      def setup_screen_overlay
        @fade_sprite = Sprite.new
        @fade_sprite.z = 500
        @fade_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, Color.new(0, 0, 0, 255)
        @fade_sprite.bitmap = @fade_bmp
        @fade_sprite.opacity = 0
        # Whether the overlay currently holds a transition mask rather than the
        # solid black the opacity-only fade needs (see #draw_transition_mask).
        @fade_masked = false

        @flash_sprite = Sprite.new
        @flash_sprite.z = 450
        @flash_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @flash_sprite.bitmap = @flash_bmp
        @flash_sprite.opacity = 0
        @flash_rgb = nil


        # Weather Effects: rain / snow particles drawn on a screen-sized layer
        # (under the flash / fade overlays), animated by @anim_frame.
        @weather_sprite = Sprite.new
        @weather_sprite.z = 430
        @weather_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @weather_sprite.bitmap = @weather_bmp
        @weather_sprite.visible = false
      end

      # Push this frame's fade and flash levels onto the two overlay sprites.
      # Both are 0..255 already: Game::Screen models the fade as 0 visible ..
      # 255 black, and the flash as a colour plus a 0..255 strength that decays
      # over the command's duration.
      def update_screen_overlay
        screen = @state.screen
        draw_transition_mask screen
        update_map_tone screen.tint

        r, g, b, strength = screen.flash_color
        if strength <= 0
          @flash_sprite.opacity = 0
        else
          rgb = [r, g, b]
          if @flash_rgb != rgb
            @flash_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, Color.new(r, g, b, 255)
            @flash_rgb = rgb
          end
          @flash_sprite.opacity = strength
        end

        draw_weather
      end

      # Fully opaque and fully clear black, for painting the erase overlay.
      OPAQUE_BLACK = Color.new(0, 0, 0, 255)
      CLEAR = Color.new(0, 0, 0, 0)

      # Paint the screen-erasure overlay for this frame.
      #
      # A plain fade is just the overlay's opacity, and the bitmap stays the
      # solid black it was built as — the cheap path, which is also every frame
      # on which no transition is running. A *shaped* transition (blinds,
      # stripes, a closing window) instead paints the bitmap: opaque black
      # everywhere, then the regions of the live scene still showing through
      # punched back out to fully transparent. `fill_rect` overwrites alpha, so
      # the holes really are holes.
      def draw_transition_mask(screen)
        tr = screen.transition
        if tr.nil? || tr.uniform?
          reset_fade_bitmap if @fade_masked
          @fade_sprite.opacity = screen.fade_level
          return
        end
        @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, OPAQUE_BLACK
        tr.visible_rects.each { |x, y, w, h| @fade_bmp.fill_rect x, y, w, h, CLEAR }
        @fade_masked = true
        @fade_sprite.opacity = 255
      rescue StandardError => e
        # A drawing failure must not strand the screen mid-transition: fall back
        # to the plain fade level, which still lands on the right end state.
        $stderr.puts "[RPG2k] screen transition draw failed: #{e.message}"
        @fade_sprite.opacity = screen.fade_level
      end

      # Restore the overlay to solid black after a shaped transition, so the
      # opacity-only path draws a full-screen fade again.
      def reset_fade_bitmap
        @fade_bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, OPAQUE_BLACK
        @fade_masked = false
      end

      WEATHER_RAIN = 1
      WEATHER_SNOW = 2
      # Particles at the lightest strength; each step up adds another band.
      WEATHER_BASE_PARTICLES = 48
      RAIN_COLOR = Color.new(200, 210, 255, 200)
      SNOW_COLOR = Color.new(255, 255, 255, 220)

      # Draw the active weather onto its overlay: falling rain streaks or drifting
      # snow flecks, their count scaling with the strength (0..2). Positions are a
      # deterministic hash of the particle index advanced by @anim_frame, so the
      # field falls smoothly without needing a per-frame RNG. Cleared / hidden
      # when there is no weather.
      def draw_weather
        w = @state.weather
        if w.none? || (w.type != WEATHER_RAIN && w.type != WEATHER_SNOW)
          @weather_sprite.visible = false
          return
        end
        @weather_sprite.visible = true
        @weather_bmp.clear
        n = weather_particle_count(w)
        n.times { |i| draw_weather_particle(w.type, i) }
      end

      def weather_particle_count(w)
        WEATHER_BASE_PARTICLES * ((w.strength || 0) + 1)
      end

      # A single particle's on-screen cell, spread across the screen by a cheap
      # hash of its index and falling as @anim_frame advances (wrapping at the
      # bottom). Rain is a slanted streak; snow a small fleck that also drifts.
      def draw_weather_particle(type, i)
        x0 = (i * 97) % SCREEN_W
        y0 = (i * 59) % SCREEN_H
        if type == WEATHER_RAIN
          y = (y0 + @anim_frame * 8) % SCREEN_H
          x = (x0 - @anim_frame * 2) % SCREEN_W
          @weather_bmp.fill_rect x, y, 1, 6, RAIN_COLOR
        else
          y = (y0 + @anim_frame * 3) % SCREEN_H
          x = (x0 + weather_drift(i)) % SCREEN_W
          @weather_bmp.fill_rect x, y, 2, 2, SNOW_COLOR
        end
      end

      # A small side-to-side snow drift, from a triangle wave over @anim_frame.
      def weather_drift(i)
        phase = (@anim_frame / 8 + i) % 8
        phase < 4 ? phase : 8 - phase
      end

      # Apply a Tint Screen tone (`[r, g, b, sat]`, each 0..200 with 100 neutral)
      # to the whole map view, by setting it on the viewport every map sprite
      # lives in.
      #
      # This used to be approximated by a black overlay whose opacity tracked how
      # far the channels averaged *below* neutral, which meant brightening did
      # nothing at all, a red tint did not read as red, and saturation was
      # ignored -- three of the four things the command can ask for. A viewport
      # carries a real tone, so all four work now.
      #
      # The channel conversion is the one the pictures already use
      # (`Scene::Map.tone_channel`), including RPG2000's saturation running the
      # other way from RGSS's grey: below 100 is *less* saturated, so a value
      # under neutral becomes positive desaturation. Skipped entirely while the
      # tone is neutral, so an untinted map never pays for it.
      def update_map_tone(tint)
        return unless @map_viewport
        r, g, b, sat = tint
        return if @map_tint == tint
        @map_tint = tint.dup
        @map_viewport.tone = Tone.new(Scene::Map.tone_channel(r),
                                      Scene::Map.tone_channel(g),
                                      Scene::Map.tone_channel(b),
                                      -Scene::Map.tone_channel(sat))
        @map_viewport.update if @map_viewport.respond_to?(:update)
      rescue StandardError => e
        $stderr.puts "[RPG2k] screen tone failed, map drawn untinted: #{e.message}"
        nil
      end

      # Create the buffer that carries the Show Picture layer. Pictures composite
      # into one screen-sized sprite above the map and characters (z = 250) but
      # below the message window (z = 300); source images are cached by
      # [name, transparent-colour] as they are shown.
      def setup_pictures
        @picture_sprite = Sprite.new
        @picture_sprite.z = 250
        @picture_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @picture_sprite.bitmap = @picture_bmp
        @picture_srcs = {}
        # Toned copies of those sources, keyed by image + tone (see
        # #toned_picture_src).
        @picture_tone_cache = {}
      end

      # Load (and cache) a picture's source image (Picture/<name>). `transparent`
      # loads it with the colour-key so palette index 0 shows through. A cached
      # nil marks a missing file so a broken picture simply draws nothing.
      def picture_src(name, transparent)
        return nil if name.nil? || name.empty?
        key = [name, transparent]
        return @picture_srcs[key] if @picture_srcs.key?(key)
        @picture_srcs[key] =
          begin
            Bitmap.new "Picture/#{name}", transparent
          rescue StandardError => e
            $stderr.puts "[RPG2k] picture '#{name}' load failed, not drawn: #{e.message}"
            nil
          end
      end

      # Load the map's parallax background (Panorama/<name>) and its scroll
      # settings, and create the sprite that carries it behind the tile layers
      # (z = -1, below the lower tiles at z = 0). Skipped — leaving the map's
      # backdrop the plain void — when the map has no parallax or the image is
      # missing.
      def setup_parallax
        cfg = parallax_config
        return unless cfg
        name = cfg[:name].to_s
        return if name.empty?
        @parallax_img = Bitmap.new "Panorama/#{name}"
        @par_loop_x = cfg[:loop_x] ? true : false
        @par_loop_y = cfg[:loop_y] ? true : false
        @par_auto_x = cfg[:auto_x] ? true : false
        @par_auto_y = cfg[:auto_y] ? true : false
        @par_sx = cfg[:sx] || 0
        @par_sy = cfg[:sy] || 0
        @parallax_sprite = Sprite.new(@map_viewport)
        @parallax_sprite.z = -1
        @parallax_bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        @parallax_sprite.bitmap = @parallax_bmp
      rescue StandardError => e
        $stderr.puts "[RPG2k] parallax load failed, no backdrop drawn: #{e.message}"
        @parallax_img = nil
      end

      # The parallax settings to draw: a Change Parallax Background override
      # (Game::State#parallax) when one is active, otherwise the map's own
      # panorama fields. nil when the map declares no parallax and none was set.
      def parallax_config
        ov = @state.parallax
        return ov if ov
        u = @map.unit
        return nil unless (u.parallax_flag rescue false)
        { name: (u.parallax_name rescue '').to_s,
          loop_x: (u.parallax_loop_x rescue false),
          loop_y: (u.parallax_loop_y rescue false),
          auto_x: (u.parallax_autoloop_x rescue false),
          auto_y: (u.parallax_autoloop_y rescue false),
          sx: (u.parallax_sx rescue 0), sy: (u.parallax_sy rescue 0) }
      end

      # The CharSet bitmap for an event graphic `name`, cached (including a
      # cached nil for a missing file so the event simply draws nothing rather
      # than a placeholder). Empty names have no graphic.
      #
      # Loaded colour-keyed, like the chipset: a CharSet is an indexed PNG whose
      # palette entry 0 is the background, and without the key that background is
      # blitted opaque -- a solid rectangle over the map instead of a sprite.
      # Caught by the wine comparison, where Nepheshel's `door` event drew as a
      # solid pink block (door.png's palette entry 0 is #FF678B) on a wall the
      # genuine RPG_RT left alone.
      def event_charset(name)
        return nil if name.nil? || name.empty?
        return @event_charsets[name] if @event_charsets.key?(name)
        @event_charsets[name] =
          begin
            Bitmap.new "CharSet/#{name}", true
          rescue StandardError => e
            $stderr.puts "[RPG2k] event charset '#{name}' load failed, " \
                         "event drawn empty: #{e.message}"
            nil
          end
      end

      def build_chipset
        Game::ChipSet.new(@db, @tileset_id || @map.chipset_id)
      rescue StandardError => e
        $stderr.puts "[RPG2k] chipset load failed, tiles treated as passable: #{e.message}"
        nil
      end

      # Rebuild the chipset model and its tile graphic (after a Change Map Tileset
      # swaps the tileset id), disposing the old graphic bitmap. Passability,
      # terrain and rendering all read the refreshed chipset from here on.
      def rebuild_chipset
        @chipset = build_chipset
        old = @chipset_bmp
        @chipset_bmp = load_chipset_graphic
        old.dispose if old && !old.equal?(@chipset_bmp)
      end

      # Load the chipset tile graphic (ChipSet/<name>). Chipsets are indexed
      # PNGs whose palette index 0 is the transparent colour, so load with the
      # colour-key flag (like the windowskin). Returns nil — falling back to the
      # solid-colour tile blocks — when there is no chipset or the file is
      # missing.
      def load_chipset_graphic
        name = @chipset && @chipset.graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "ChipSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] chipset graphic load failed, using colour blocks: #{e.message}"
        nil
      end

      # Load the leader's CharSet graphic. Returns nil (falling back to a marker)
      # when there is no party or the file is missing. Colour-keyed for the same
      # reason event graphics are (see event_charset).
      def load_charset
        leader = @state.party.leader
        return nil if leader.nil?
        name = leader.charset_name
        @charset_index = leader.charset_index || 0
        return nil if name.nil? || name.empty?
        Bitmap.new "CharSet/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] party charset load failed, using marker: #{e.message}"
        nil
      end

      # Load the System/ windowskin for message windows (nil -> plain panel).
      def load_windowskin
        # A Change System Graphics override (persisted in the save) wins over the
        # database's own windowskin.
        name = @state.system_graphic
        name = @db.system.system_graphic if name.nil?
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
          next if @erased_events[id] # an Erase Event lasts the whole visit
          selected = Game::EventPage.select(ev.pages, @state.switches,
                                            @state.variables, @state.party)
          next unless selected
          page = selected[1]
          @events.push(build_event(id, ev, page))
        end
        rebuild_event_tiles
      rescue StandardError => e
        $stderr.puts "[RPG2k] event setup failed, map runs with no events: #{e.message}"
        @events = []
        @event_tiles = {}
      end

      def build_event(id, ev, page)
        dir = Game::EventGraphic.numpad_direction(page_direction(page))
        ch = Game::Character.new(ev.x, ev.y, dir)
        ch.move_speed = page_move_speed(page)
        ch.move_frequency = page_move_frequency(page)
        ch.set_graphic(page_charset_name(page), page_charset_index(page))
        move_type = page_move_type(page)
        route = move_type == Game::MoveType::CUSTOM ?
                Game::MoveRoute.from_page(page_move_route(page)) : nil
        # `page` is kept so a refresh can tell whether the conditions still pick
        # the same one (see #pages_changed?).
        { id: id, char: ch, page: page, trigger: page_trigger(page),
          commands: page_commands(page), move_type: move_type, route: route,
          move_timer: EVENT_MOVE_DELAY[ch.move_frequency] || 40,
          # Rendering state: the page's static graphic fields, a live walk
          # animation phase / counter, a mid-step "moving" flag, and the pixel
          # slide (display origin disp_x/disp_y + move_count 0..TILE) that eases
          # the sprite between tiles. move_count == TILE means "at rest".
          # `jumping` marks that slide as a hop, which is lifted along an arc
          # and is the one kind that slides across more than a single tile.
          layer: page_layer(page), translucent: page_translucent(page),
          anim_type: page_anim_type(page), base_dir: dir,
          base_pattern: page_pattern(page), anim_phase: 0, anim_count: 0,
          moving: false, disp_x: ev.x, disp_y: ev.y, move_count: TILE,
          jumping: false }
      end

      # Build the Call Event resolver for the current map: common events keyed by
      # id (they are global) plus this map's raw events for map-event page calls.
      def build_resolver
        common = {}
        @common.each { |c| common[c[:id]] = c[:commands] }
        map_events = (@map.unit.events rescue nil)
        EventResolver.new(common, map_events)
      rescue StandardError
        EventResolver.new({}, nil)
      end

      # Recompute the occupied-tile set from the events' current positions.
      def rebuild_event_tiles
        @event_tiles = {}
        @events.each { |e| @event_tiles[[e[:char].x, e[:char].y]] = e }
      end

      # Read an optional event-page field through a guard that logs (rather than
      # silently swallowing) any access error before falling back to `default`.
      # A malformed page then degrades a single field instead of taking out the
      # whole event list, and the failure still surfaces in the log.
      def page_field(name, default)
        yield
      rescue StandardError => e
        $stderr.puts "[RPG2k] event page field '#{name}' unavailable " \
                     "(#{e.message}), using #{default.inspect}"
        default
      end

      def page_trigger(page); page_field(:trigger, 0) { page.trigger }; end
      def page_commands(page); page_field(:commands, nil) { page.event_commands }; end
      # The page's stored facing (0..3: up/right/down/left), default down (2).
      # Converted to the runtime numpad convention by build_event.
      def page_direction(page); page_field(:direction, 2) { d = page.direction; (0..3).include?(d) ? d : 2 }; end
      def page_move_type(page); page_field(:move_type, 0) { page.move_type || 0 }; end
      def page_move_speed(page); page_field(:move_speed, 3) { page.move_speed || 3 }; end
      def page_move_frequency(page); page_field(:move_frequency, 3) { page.move_frequency || 3 }; end
      def page_move_route(page); page_field(:move_route, nil) { page.move_route }; end
      def page_charset_name(page); page_field(:charset_name, nil) { page.charset_name }; end
      def page_charset_index(page); page_field(:charset_index, 0) { page.charset_index || 0 }; end
      def page_layer(page); page_field(:layer, 0) { page.layer || 0 }; end
      def page_pattern(page); page_field(:pattern, 1) { p = page.pattern; (0..2).include?(p) ? p : 1 }; end
      def page_anim_type(page); page_field(:anim_type, 0) { page.animation_type || 0 }; end
      def page_translucent(page); page_field(:translucent, false) { page.translucent ? true : false }; end

      # -- event execution ----------------------------------------------------

      def event_busy?
        @message || @number_input || @interpreter.running? || @interpreter.waiting?
      end

      # Start the first not-yet-run auto-start process in the foreground: map
      # events with an auto-start trigger, then auto-start common events (whose
      # switch gate, if any, is on). Each runs at most once per visit so an
      # ungated process cannot hard-loop. Parallel processes are driven
      # separately by #step_parallels.
      def start_autostart
        ev = @events.find do |e|
          e[:trigger] == TRIGGER_AUTO_START && e[:commands] && !@started_auto[e[:id]]
        end
        if ev
          @started_auto[ev[:id]] = true
          @active_event = ev
          @interpreter.start(ev[:commands])
          @interpreter.event_id = ev[:id]
          return
        end

        ce = @common.find do |c|
          c[:trigger] == Game::CommonEvent::AUTO_START && c[:commands] &&
            common_gate_open?(c) && !@started_common[c[:id]]
        end
        return unless ce
        @started_common[ce[:id]] = true
        @active_event = nil # a common event has no "this event" map character
        @interpreter.start(ce[:commands])
      end

      # A common event's switch gate: open unless it needs a flag that is off.
      def common_gate_open?(c)
        return true unless c[:need_flag]
        @state.switches[c[:switch_id]]
      end

      # Build the background (parallel-process) interpreters: map events with a
      # parallel trigger plus parallel common events. Each gets its own
      # Game::Interpreter, looped by #step_parallels; a common event that needs a
      # flag carries its gate switch so it only runs while that switch is on.
      def build_parallels
        @parallels = []
        @events.each do |e|
          next unless e[:trigger] == TRIGGER_PARALLEL && e[:commands]
          @parallels.push new_parallel(e[:commands], nil, e)
        end
        @common.each do |c|
          next unless c[:trigger] == Game::CommonEvent::PARALLEL && c[:commands]
          @parallels.push new_parallel(c[:commands],
                                       c[:need_flag] ? c[:switch_id] : nil, nil)
        end
      rescue StandardError
        @parallels = []
      end

      # Build one background process. `event` is the owning map event (so a Move
      # Event targeting "this event" resolves) or nil for a common event.
      def new_parallel(commands, gate_switch, event)
        it = Game::Interpreter.new(@state)
        it.resolver = @interpreter.resolver
        it.map_info = self
        it.start(commands)
        it.event_id = event && event[:id]
        { interp: it, commands: commands, gate_switch: gate_switch,
          wait_timer: nil, event: event }
      end

      # Advance every background parallel process one frame. They loop their
      # command list and honour Wait; as background processes they do not drive
      # the message/choice/teleport UI (those requests are simply resumed so the
      # process keeps running). Called only while the foreground is idle, so
      # parallels pause during messages and foreground events.
      def step_parallels
        # Iterate a copy: an Erase Event in a parallel process removes it from
        # @parallels mid-loop (see erase_event).
        @parallels.dup.each { |p| step_parallel(p) }
      end

      def step_parallel(p)
        return if p[:gate_switch] && !@state.switches[p[:gate_switch]]
        it = p[:interp]
        if it.waiting?
          drive_parallel_wait(p, it)
        elsif it.running?
          it.update
        else
          it.start(p[:commands]) # loop the process
          # #start clears the "this event" id, so re-attach it on every lap or
          # the second pass would answer the process's own position queries with
          # nothing.
          it.event_id = p[:event] && p[:event][:id]
          it.update
        end
        apply_interpreter_requests(it, p[:event])
      rescue StandardError
        nil
      end

      def drive_parallel_wait(p, it)
        if it.wait_kind == :wait
          p[:wait_timer] = frames_from_tenths(it.wait_frames) if p[:wait_timer].nil?
          if p[:wait_timer] <= 0
            p[:wait_timer] = nil
            it.resume
          else
            p[:wait_timer] -= 1
          end
        elsif it.wait_kind == :key_input
          # Parallel processes commonly poll a key each frame into a variable.
          resolve_key_input(it)
        else
          it.resume # background: ignore message/choice/teleport requests
        end
      end

      # The event currently standing on tile (x, y), or nil.
      def event_at(x, y)
        @event_tiles[[x, y]]
      end

      # Turn `ev` to face the player and run its command list. `by_decision_key`
      # records that the action button (not a touch or auto-start) launched it,
      # which the "the decision key started this event" conditional branch reads.
      def start_event(ev, by_decision_key = false)
        ev[:char].face(ev[:char].direction_toward(@state.x, @state.y))
        @active_event = ev
        @interpreter.start(ev[:commands])
        @interpreter.triggered_by_decision_key = by_decision_key
        @interpreter.event_id = ev[:id]
      end

      # On the action button, run the trigger-0 event the player is facing. The
      # faced event turns toward the player before its commands run.
      # RPG_RT looks through at most three counter tiles in a row before giving
      # up (EasyRPG's `Game_Player::CheckActionEvent`).
      MAX_COUNTER_REACH = 3

      def try_action_trigger
        return if event_busy?
        return unless Input.trigger?(Input::C)
        # An action event **under the player** fires too: RPG_RT checks the tile
        # the party is standing on before the one it faces, which is how a
        # trigger-0 event on a doorway tile answers the action button.
        here = event_at(@state.x, @state.y)
        return start_event(here, true) if actionable?(here)

        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        ev = event_at(fx, fy)
        return start_event(ev, true) if actionable?(ev)

        # Nothing on the faced tile: if it is a **counter** — a shop or inn
        # counter, marked in the chipset's upper-layer passage table — look
        # across it for whoever is standing behind, up to three counters deep.
        MAX_COUNTER_REACH.times do
          break unless counter_tile?(fx, fy)
          fx, fy = target_tile(fx, fy, @state.direction)
          ev = event_at(fx, fy)
          return start_event(ev, true) if actionable?(ev)
        end
        nil
      end

      # Whether an event can answer the action button.
      def actionable?(ev)
        ev && ev[:trigger] == TRIGGER_ACTION && ev[:commands] ? true : false
      end

      # Whether a trigger is one of the two the party can set off by walking into
      # the event (see the note in #try_move).
      def touch_trigger?(trigger)
        trigger == TRIGGER_PLAYER_TOUCH || trigger == TRIGGER_EVENT_TOUCH
      end

      # Whether (x, y) carries an upper-layer counter tile.
      def counter_tile?(x, y)
        return false if @chipset.nil? || !@map.in_bounds?(x, y)
        @chipset.counter?(@map.upper(x, y))
      end

      # On the action button, board a placed vehicle the party is standing on
      # (airship) or facing (boat / ship), or — when already aboard — step off
      # onto the tile ahead. Returns true when it claimed the button, so the
      # ordinary event-action check is skipped that frame.
      def try_board_vehicle
        return false if event_busy?
        return false unless Input.trigger?(Input::C)
        if @state.boarded?
          disembark_vehicle
          true # aboard, the action button belongs to the vehicle
        else
          board_vehicle
        end
      end

      # Board a vehicle placed on the current map at the party's tile (airship) or
      # the tile it faces (boat / ship, boarded from the shore). Steps onto the
      # vehicle's tile and returns whether a vehicle was boarded.
      def board_vehicle
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        Game::Vehicle::TYPES.each do |type|
          v = @state.vehicle(type)
          next unless v.placed? && v.map_id == @state.map_id
          if v.x == @state.x && v.y == @state.y
            board_as(type)
            return true
          elsif v.x == fx && v.y == fy
            @state.x = fx
            @state.y = fy
            board_as(type)
            return true
          end
        end
        false
      end

      # Mark the party aboard `type` and switch to the vehicle's BGM.
      def board_as(type)
        @state.boarded = type
        play_vehicle_bgm(type)
      end

      # Step off the ridden vehicle onto the tile ahead when it is walkable on
      # foot, leaving the vehicle on the tile the party vacates. A no-op when the
      # way ahead is blocked (the party stays aboard).
      def disembark_vehicle
        fx, fy = target_tile(@state.x, @state.y, @state.direction)
        return unless passable?(fx, fy, @state.direction)
        follow_vehicle # the vehicle is left where the party is getting off
        @state.x = fx
        @state.y = fy
        @state.boarded = nil
        restore_pre_vehicle_bgm # the map BGM resumes
      end

      # Play the vehicle's own BGM (the database System boat / ship / airship
      # music), remembering the BGM that was playing so #restore_pre_vehicle_bgm
      # can bring it back on disembark. A vehicle with no configured BGM leaves
      # the current music playing.
      def play_vehicle_bgm(type)
        music = vehicle_bgm(type)
        name = music && music_name(music)
        return if name.nil? || name.empty?
        @pre_vehicle_bgm = @state.current_bgm
        vol = music_volume(music)
        tempo = music_tempo(music)
        RGSS::Audio.bgm_play(name, vol, tempo)
        @state.current_bgm = { name: name, volume: vol, tempo: tempo }
      rescue StandardError => e
        $stderr.puts "[RPG2k] vehicle BGM failed: #{e.message}"
      end

      # Restore the BGM that was playing before the party boarded (the map BGM).
      # A no-op when boarding did not switch the music.
      def restore_pre_vehicle_bgm
        bgm = @pre_vehicle_bgm
        @pre_vehicle_bgm = nil
        return unless bgm && bgm[:name] && !bgm[:name].empty?
        RGSS::Audio.bgm_play(bgm[:name], bgm[:volume] || 100, bgm[:tempo] || 100)
        @state.current_bgm = bgm
      rescue StandardError => e
        $stderr.puts "[RPG2k] restoring BGM failed: #{e.message}"
      end

      # The database System BGM configured for vehicle `type` (boat / ship /
      # airship), or nil when the database has none.
      def vehicle_bgm(type)
        field = "#{type}_music"
        return nil unless @db.system.respond_to?(field)
        @db.system.send(field)
      end

      # A parsed BGM chunk exposes file / volume / pitch; read them defensively so
      # a bare fixture that omits a field still works.
      def music_name(m); m.file rescue nil; end
      def music_volume(m); (m.volume rescue nil) || 100; end
      def music_tempo(m); (m.pitch rescue nil) || 100; end

      # Keep the ridden vehicle on the party's tile / facing.
      def follow_vehicle
        v = @state.vehicle(@state.boarded)
        return unless v
        v.map_id = @state.map_id
        v.x = @state.x
        v.y = @state.y
        v.direction = @state.direction
      end

      # Whether vehicle `type` may enter tile (x, y) heading `dir`: the airship
      # flies over any in-bounds tile; a boat / ship needs the tile's terrain to
      # allow it (the database terrain's boat_pass / ship_pass flag) with no event
      # in the way, falling back to on-foot passability when the map has no
      # terrain data.
      def vehicle_passable?(x, y, dir, type)
        return false unless @map.in_bounds?(x, y)
        return true if type == :airship
        return false if @event_tiles[[x, y]]
        row = terrain_row_at(x, y)
        return passable?(x, y, dir) unless row
        type == :boat ? (row.boat_pass ? true : false) : (row.ship_pass ? true : false)
      end

      # The database terrain row under tile (x, y), or nil when the chipset / map
      # carry no terrain data (e.g. the colour-block fallback or a bare fixture).
      def terrain_row_at(x, y)
        return nil if @chipset.nil? || !@db.respond_to?(:terrain) || @db.terrain.nil?
        @db.terrain[@chipset.terrain(@map.lower(x, y))]
      rescue StandardError
        nil
      end

      # Advance autonomous / custom-route event movement one frame. Skipped
      # while an event process is running so the map holds still during messages.
      def step_events
        @events.each { |e| step_event(e) }
      end

      def step_event(e)
        return if event_busy? # an event fired earlier this frame; hold the rest
        ch = e[:char]
        e[:move_timer] -= 1
        return if e[:move_timer] > 0
        forced = e[:forced_route]
        # A forced route (from a Move Event) is paced by its own frequency when
        # one was given, otherwise by the page's; it overrides page movement.
        freq = forced && e[:forced_freq] ? e[:forced_freq] : ch.move_frequency
        e[:move_timer] = EVENT_MOVE_DELAY[freq] || 40
        ox = ch.x
        oy = ch.y
        if forced
          forced.step(ch, @world) unless forced.done?
          e[:forced_route] = nil if forced.done? # revert to page movement
        elsif e[:route]
          e[:route].step(ch, @world) unless e[:route].done?
        else
          dir = Game::MoveType.next_direction(e[:move_type], ch, @world)
          move_autonomous(e, dir) if dir
        end
        # A jump that lands where it started still needs the render slide, so
        # the hop is visible; an ordinary step only when the tile changed.
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy || ch.jumped
      rescue StandardError => ex
        $stderr.puts "[RPG2k] event ##{e[:id]} movement failed: #{ex.message}"
        nil
      end

      # Advance each event's pixel slide and walk-animation phase once per frame.
      # An event "moves" for animation purposes while it is sliding between two
      # tiles (see reoccupy / event_sliding?); such events — and any
      # continuous/spin animation type — cycle their walk frames on the
      # ANIM_FRAME_PERIOD cadence, while an event resting on a tile shows its
      # page pose. Game::EventGraphic.frame reads @moving / @anim_phase to pick
      # the drawn column, and event_pixel reads the slide for the draw position.
      def animate_events
        @events.each { |e| animate_event(e) }
      end

      def animate_event(e)
        # Advance the slide first so a fixed-graphic event still glides smoothly.
        e[:move_count] += SPEED if e[:move_count] < TILE
        sliding = event_sliding?(e)
        e[:moving] = sliding
        type = e[:anim_type]
        return unless Game::EventGraphic.animated?(type)
        return unless sliding || Game::EventGraphic.continuous?(type)
        e[:anim_count] += 1
        return if e[:anim_count] < ANIM_FRAME_PERIOD
        e[:anim_count] = 0
        e[:anim_phase] = (e[:anim_phase] + 1) % Game::EventGraphic::WALK_COLUMNS.size
      end

      # Whether an event is mid-step: its display origin has not yet caught up to
      # its logical tile (the slide started by reoccupy is still in progress).
      def event_sliding?(e)
        return false unless e[:move_count] < TILE
        # A jump that lands on its own tile moves the sprite nowhere but is
        # still in progress, so it cannot be recognised by the displacement.
        e[:jumping] ||
          e[:disp_x] != e[:char].x || e[:disp_y] != e[:char].y
      end

      # Move an autonomous event one step in `dir`. Walking into the player fires
      # an event-touch (trigger 2) event instead of moving; any other obstacle
      # just turns the event to face it.
      def move_autonomous(e, dir)
        ch = e[:char]
        nx, ny = Game::Character.step_tile(ch.x, ch.y, dir)
        if nx == @state.x && ny == @state.y
          ch.face(dir)
          start_event(e) if e[:trigger] == TRIGGER_EVENT_TOUCH && e[:commands]
        elsif @world.passable?(ch, dir)
          ch.move(dir)
        else
          ch.face(dir)
        end
      end

      # Update the occupied-tile cache after event `e` moved off (ox, oy). Done
      # eagerly (rather than a single end-of-frame rebuild) so an event that has
      # already moved this frame blocks the next event from stepping onto it.
      # Also begins the pixel slide from the old tile toward the new one so the
      # sprite glides instead of teleporting (see event_pixel).
      def reoccupy(e, ox, oy)
        @event_tiles.delete([ox, oy]) if @event_tiles[[ox, oy]].equal?(e)
        @event_tiles[[e[:char].x, e[:char].y]] = e
        start_event_slide(e, ox, oy)
      end

      # Begin a render slide for event `e` that just stepped off (ox, oy): the
      # sprite eases from that tile to its new one over TILE/SPEED frames.
      #
      # A single-tile cardinal step slides, and so does a **jump**, however far
      # it goes -- RPG_RT carries the sprite across the whole hop and lifts it
      # along the way (see event_jump_offset), which is the point of a jump
      # clearing the tiles between. Anything else -- a multi-tile displacement
      # that is not a jump -- snaps, so a sprite never streaks across the map.
      def start_event_slide(e, ox, oy)
        jumped = e[:char].jumped
        if jumped || (e[:char].x - ox).abs + (e[:char].y - oy).abs == 1
          e[:disp_x] = ox
          e[:disp_y] = oy
          e[:move_count] = 0
          e[:jumping] = jumped
        else
          e[:disp_x] = e[:char].x
          e[:disp_y] = e[:char].y
          e[:move_count] = TILE
          e[:jumping] = false
        end
      end

      # How far event `e`'s sprite is lifted off the ground this frame, in
      # pixels: 0 unless a jump is in progress, otherwise RPG_RT's arc.
      #
      # A port of EasyRPG's `Game_Character::GetJumpHeight`, kept in its own
      # 256-per-tile units so the formula reads as it does there: the height
      # rises and falls linearly with the remaining step, peaking at the
      # midpoint, and is then stretched -- doubled while small, offset by 5 once
      # past 4 -- which is what makes the hop leave the ground sharply and hang
      # near the top. The peak is 21px on a 16px tile, so a jumping sprite
      # clearly leaves its row.
      #
      # The lift is applied where the sprite is blitted, not inside #event_pixel:
      # RPG_RT raises the drawn character without moving it, so its logical
      # position -- what the camera follows and what the draw order sorts on --
      # stays on the ground.
      JUMP_STEP_UNITS = 256              # EasyRPG's SCREEN_TILE_SIZE
      def event_jump_offset(e)
        return 0 unless e[:jumping] && e[:move_count] < TILE
        jump_offset_for(e[:move_count])
      end

      # The arc itself, given how far through the hop the slide is (0..TILE).
      # Shared by the event sprites and the hero, so a jumping party member and
      # a jumping NPC rise by the same amount at the same point of the hop.
      def jump_offset_for(move_count)
        remaining = (TILE - move_count) * (JUMP_STEP_UNITS / TILE)
        half = JUMP_STEP_UNITS / 2
        h = (remaining > half ? JUMP_STEP_UNITS - remaining : remaining) / 8
        h < 5 ? h * 2 : h + 5
      end

      # Current position of event `e` in map pixels, interpolated from its
      # display origin toward its logical tile while a slide is in progress.
      def event_pixel(e)
        cx = e[:char].x
        cy = e[:char].y
        if event_sliding?(e)
          t = e[:move_count]
          [e[:disp_x] * TILE + (cx - e[:disp_x]) * t,
           e[:disp_y] * TILE + (cy - e[:disp_y]) * t]
        else
          [cx * TILE, cy * TILE]
        end
      end

      # -- Erase Event --------------------------------------------------------

      # If the interpreter ran an Erase Event this step, remove the event that
      # was running it (`this_event`) from the map. A common event has no such
      # map event, so nothing happens.
      def apply_erase_request(interp, this_event)
        erase_event(this_event) if interp.take_erase_request && this_event
      rescue StandardError => e
        $stderr.puts "[RPG2k] Erase Event failed: #{e.message}"
        nil
      end

      # Remove an event from the map for the rest of the visit: drop it from the
      # runtime list, the occupied-tile cache (so it no longer draws, moves or
      # blocks) and any background process it was driving. It reappears only on
      # the next map (re)load, matching RPG2000's Erase Event.
      def erase_event(ev)
        @events.delete(ev)
        # Remembered so a page refresh cannot resurrect it: an Erase Event lasts
        # for the rest of the visit to the map, whatever its conditions do next.
        @erased_events[ev[:id]] = true
        tile = [ev[:char].x, ev[:char].y]
        @event_tiles.delete(tile) if @event_tiles[tile].equal?(ev)
        @parallels.reject! { |p| p[:event].equal?(ev) } if @parallels
      end

      # -- page refresh -------------------------------------------------------

      # An event's active page is chosen by its conditions, and those read the
      # switches, the variables, the party roster and its items. Change one and
      # the choice can change with it — the "talk to me once and I turn into my
      # page 2" idiom every RPG2000 game is built on. The pages were only ever
      # selected when the map loaded, so an event kept whichever page it started
      # the visit with until the player left and came back.
      #
      # RPG_RT re-selects them whenever those four things change (its
      # `Game_Map::SetNeedRefresh`, set by Control Switches / Variables, Change
      # Items and Change Party Member). Rather than flagging each command — which
      # silently misses any path that is not an event command, like using an item
      # from the menu — this watches the revision counters those four carry, so
      # every writer is covered by construction.
      def page_revision
        rev(@state.switches) + rev(@state.variables) + rev(@state.party)
      end

      # A collaborator's revision counter, or 0 for one that keeps none (the
      # party stand-ins some harnesses pass in). A source that cannot report a
      # change simply never asks for a refresh.
      def rev(o)
        o.respond_to?(:revision) && o.revision ? o.revision : 0
      end

      # Re-select every event's page if anything a condition reads has changed.
      # The sweep is cheap (a few comparisons per event) and does nothing at all
      # unless a page actually flipped, so a parallel process writing a variable
      # every frame costs a sweep, not a rebuild.
      def refresh_event_pages
        rev = page_revision
        return if rev == @page_revision
        @page_revision = rev
        return unless pages_changed?
        rebuild_events_preserving_positions
      rescue StandardError => e
        $stderr.puts "[RPG2k] event page refresh failed: #{e.message}"
      end

      # Whether any event's conditions now pick a different page than the one it
      # is running. Walks the *map's* events rather than the live list, so it
      # also catches an event that has no active page at all right now and has
      # just gained one — those are absent from @events entirely.
      def pages_changed?
        evs = @map.unit.events
        return false unless evs
        live = {}
        @events.each { |e| live[e[:id]] = e }
        changed = false
        evs.each do |id, src|
          next if changed || @erased_events[id]
          selected = Game::EventPage.select(src.pages, @state.switches,
                                            @state.variables, @state.party)
          page = selected && selected[1]
          e = live[id]
          changed = true unless page.equal?(e && e[:page])
        end
        changed
      end

      # Rebuild the runtime events for the newly-selected pages, carrying each
      # event's **position and facing** across — RPG_RT changes an event's page,
      # not where it stands, so an NPC that flips to page 2 stays where it was
      # rather than snapping back to its spawn tile. Erased events stay erased,
      # and the parallel processes are rebuilt because a page change can add or
      # remove one.
      def rebuild_events_preserving_positions
        placed = {}
        @events.each { |e| placed[e[:id]] = e[:char] }
        build_events
        @events.each do |e|
          old = placed[e[:id]]
          next unless old
          e[:char].x = old.x
          e[:char].y = old.y
          e[:char].direction = old.direction
        end
        rebuild_event_tiles
        build_parallels
        # The event the foreground interpreter is running may have just been
        # rebuilt; re-point it so "this event" still reaches the live character.
        @active_event = @events.find { |e| e[:id] == @active_event[:id] } if @active_event
      end

      # -- Halt All Movement --------------------------------------------------

      # If the interpreter ran a Halt All Movement this step, cancel every forced
      # move route in progress — the player's and each event's — so a route set by
      # an earlier Move Event stops where it is. Events fall back to their page's
      # autonomous movement; the player returns to input control.
      def apply_halt_request(interp)
        return unless interp.take_halt_movement_request
        @player_route = nil
        @player_char = nil
        @events.each { |e| e[:forced_route] = nil } if @events
      rescue StandardError => e
        $stderr.puts "[RPG2k] Halt All Movement failed: #{e.message}"
        nil
      end

      # -- Change Sprite Association (Change Actor Graphic) --------------------

      # If the interpreter changed an actor's sprite this step, reload the party
      # leader's on-screen graphic so the change shows immediately (a change to a
      # non-leader actor is held in the model until that actor leads the party).
      def apply_graphic_change(interp)
        refresh_player_graphic if interp.take_actor_graphic_changed
        reload_windowskin if interp.take_system_graphic_changed
      rescue StandardError => e
        $stderr.puts "[RPG2k] Change Actor Graphic failed: #{e.message}"
        nil
      end

      # Rebuild the windowskin after a Change System Graphics override. Windows
      # created from here on (messages, menus, battle) pick up the new skin;
      # windows already open keep theirs until they are next recreated.
      def reload_windowskin
        old = @windowskin
        @windowskin = load_windowskin
        old.dispose if old && !old.equal?(@windowskin)
      end

      # Reload the party leader's CharSet graphic and apply its transparency to
      # the player sprite, forcing a redraw on the next frame. The transparency
      # flag hides the sprite outright (the renderer has no partial-opacity path).
      def refresh_player_graphic
        @charset = load_charset
        @last_frame = nil
        @player_sprite.visible = !player_hidden?
        @player_bmp.clear unless @charset
      end

      # Whether the party leader's map sprite should be hidden this frame: either
      # the Set Transparent Flag command hid the player, or the leader's own
      # actor graphic carries the (rarely used) semi-transparent flag.
      def player_hidden?
        leader = @state.party.leader
        @state.player_transparent || (leader && leader.transparent) ? true : false
      end

      # -- Change Map Tileset -------------------------------------------------

      # If the interpreter ran a Change Map Tileset this step, swap the map's
      # chipset to the requested id and rebuild its tile graphic. The override
      # lasts until the next map load (see perform_teleport).
      def apply_tileset_request(interp)
        id = interp.take_tileset_request
        return if id.nil?
        @tileset_id = id
        rebuild_chipset
      rescue StandardError => e
        $stderr.puts "[RPG2k] Change Map Tileset failed: #{e.message}"
        nil
      end

      # -- Change Parallax Background -----------------------------------------

      # If the interpreter ran a Change Parallax Background this step, tear down
      # the old panorama sprite and rebuild it from the new override
      # (Game::State#parallax). The override lasts until the next map load (see
      # perform_teleport, which clears it), when the map's own panorama returns.
      def apply_parallax_request(interp)
        return unless interp.take_parallax_request
        dispose_parallax
        setup_parallax
      rescue StandardError => e
        $stderr.puts "[RPG2k] Change Parallax Background failed: #{e.message}"
        nil
      end

      # Release the current parallax sprite / buffers before a rebuild, so a
      # mid-map panorama swap does not leak the old bitmaps.
      def dispose_parallax
        @parallax_sprite.dispose if @parallax_sprite
        @parallax_bmp.dispose if @parallax_bmp
        @parallax_img.dispose if @parallax_img
        @parallax_sprite = nil
        @parallax_bmp = nil
        @parallax_img = nil
      end

      # -- "BGM played once" ---------------------------------------------------

      # Watch the music's playback position so the conditional branch that asks
      # whether the BGM has played through at least once (12010 type 9) can be
      # answered. SDL_mixer loops a track by seeking back to its start, so a
      # position that jumped backwards is a loop; the flag is cleared whenever a
      # new BGM starts (see Game::Interpreter#play_audio). A backend that cannot
      # report a position always returns 0, which never counts as a loop.
      def watch_bgm_loop
        return if @bgm_pos_unavailable
        return unless RGSS::Audio.respond_to?(:bgm_pos)
        pos = RGSS::Audio.bgm_pos.to_i
        prev = @bgm_pos || 0
        @bgm_pos = pos
        @state.bgm_looped = true if pos < prev && @state.current_bgm
      rescue StandardError => e
        # Report once and stop polling, rather than repeating the same failure
        # sixty times a second; the branch then never reports a loop.
        @bgm_pos_unavailable = true
        $stderr.puts "[RPG2k] BGM position unavailable, 'BGM played once' " \
                     "branches will not fire: #{e.message}"
      end

      # -- Tile Substitution ---------------------------------------------------

      # A Tile Substitution rewrote a tile id on the current map (11750). The map
      # itself already answers every lookup with the substituted tile
      # (Game::Map#substitute_tile), and draw_layers rebuilds both tile buffers
      # from those lookups every frame, so the swap is on screen on the next
      # render with nothing to invalidate here. Draining the flag is what keeps
      # the request from being reported again next step.
      def apply_tile_substitution(interp)
        interp.take_tiles_changed
        nil
      end

      # -- Enter/Exit Vehicle --------------------------------------------------

      # Board or leave a vehicle on the event's behalf (10840) — the same toggle
      # the action button performs, so an event can put the party on the ship it
      # just placed, or set them ashore.
      def apply_vehicle_toggle(interp)
        return unless interp.take_vehicle_toggle_request
        if @state.boarded?
          disembark_vehicle
        else
          board_vehicle
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Enter/Exit Vehicle failed: #{e.message}"
        nil
      end

      # -- Play Movie ----------------------------------------------------------

      # Report a Play Movie request (11560). No video decoder is linked in, so
      # the movie cannot be shown; the request is logged rather than dropped in
      # silence, so a game that plays a cut-scene here is visible in the trace.
      def apply_movie_request(interp)
        req = interp.take_movie_request
        return if req.nil?
        $stderr.puts "[RPG2k] Play Movie '#{req[:name]}' at (#{req[:x]}, #{req[:y]}) " \
                     "#{req[:width]}x#{req[:height]}: video playback is not supported"
      end

      # -- Flash Sprite --------------------------------------------------------

      # Start the character flashes an interpreter queued this step (11320). The
      # hero and map events both keep their flash as a decaying colour the
      # renderer tones their CharSet frame with; a target that cannot be resolved
      # (a vehicle, or an unknown event id) simply flashes nothing.
      def apply_sprite_flash_requests(interp, this_event)
        reqs = interp.take_sprite_flash_requests
        return if reqs.nil? || reqs.empty?
        started = nil
        reqs.each { |r| started = apply_sprite_flash(r, this_event) || started }
        # A Flash Sprite that carried its wait flag paused the interpreter on a
        # :sprite_flash wait; remember the flash it started so the wait releases
        # on *that* character, not on some other one still flashing.
        @flash_wait = started if interp.wait_kind == :sprite_flash
      rescue StandardError => e
        $stderr.puts "[RPG2k] Flash Sprite failed: #{e.message}"
        nil
      end

      # Start one queued flash, returning the flash it attached to a character
      # (nil when the target could not be resolved, so nothing flashes).
      def apply_sprite_flash(r, this_event)
        flash = { red: r[:red], green: r[:green], blue: r[:blue],
                  power: r[:power], frames: r[:frames], total: r[:frames] }
        return nil if flash[:frames] <= 0
        case r[:target]
        when MOVE_TARGET_PLAYER
          @player_flash = flash
          @last_frame = nil # force the hero's cached frame to be re-toned
          flash
        when 0, MOVE_TARGET_THIS
          this_event ? (this_event[:flash] = flash) : nil
        else
          ev = @events.find { |e| e[:id] == r[:target] }
          ev ? (ev[:flash] = flash) : nil
        end
      end

      # Whether the flash a waiting Flash Sprite started is still running. The
      # flash hash is decayed in place by update_sprite_flashes, so holding the
      # reference is enough to see it run out even after the character has
      # dropped it.
      def sprite_flashing?
        @flash_wait && @flash_wait[:frames] > 0 ? true : false
      end

      # Advance every running character flash one frame, dropping the ones that
      # have decayed away. Called once per frame from #update, so a flash fades
      # during messages and forced movement too, as RPG_RT's does.
      def update_sprite_flashes
        # Invalidate the hero's cached frame whenever a flash was running this
        # tick — including the tick it ends on, so the last toned frame is
        # replaced by the plain one instead of staying baked in.
        @last_frame = nil if @player_flash
        @player_flash = tick_flash(@player_flash)
        @events.each { |e| e[:flash] = tick_flash(e[:flash]) if e[:flash] }
      end

      def tick_flash(flash)
        return nil if flash.nil?
        flash[:frames] -= 1
        flash[:frames] > 0 ? flash : nil
      end

      # The RGSS tone that paints `flash` over a CharSet frame: the flash colour
      # scaled by how much of the flash is left, added to every pixel (alpha is
      # untouched, so the sprite keeps its shape).
      def flash_tone(flash)
        strength = flash[:power] * flash[:frames] / flash[:total]
        Tone.new(flash[:red] * strength / 255, flash[:green] * strength / 255,
                 flash[:blue] * strength / 255, 0)
      end

      # Scratch CharSet-sized buffers the flash pass uses: the frame is blitted
      # into the first and toned into the second (tone_blt needs a same-size
      # source and writes to a separate destination).
      def flash_buffer
        @flash_buffer ||= Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
      end

      def flash_out_buffer
        @flash_out_buffer ||= Bitmap.new(Game::CharSet::WIDTH, Game::CharSet::HEIGHT)
      end

      # -- Open Save Menu / Open Main Menu -------------------------------------

      # Open Save Menu (11910): save the game on the event's behalf and report
      # the outcome, then let the event continue. The clone has a single save
      # slot (Scene::Menu's Save entry writes it), so there is no slot picker to
      # show; a Change Save Access that forbade saving is honoured, as in RPG_RT.
      def perform_event_save
        if @state.save_access
          saved = @parent.save_game(@state)
          $stderr.puts "[RPG2k] Open Save Menu: #{saved ? 'saved' : 'save failed'}"
        else
          $stderr.puts '[RPG2k] Open Save Menu: saving is disabled'
        end
        @interpreter.resume
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Save Menu failed: #{e.message}"
        @interpreter.resume
      end

      # Open Load Menu (5001, RPG2003): hand the game back to the loader, which
      # replaces this scene with the loaded save's map. Nothing resumes here, so
      # the interpreter is stopped rather than released — the same shape as
      # Return to Title. A failed load leaves the player on this map, so the
      # event is only stopped, never silently resumed into a discarded scene.
      def perform_event_load
        @interpreter.stop
        @parent.continue_game
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Load Menu failed: #{e.message}"
        @interpreter.stop
      end

      # Exit Game (5002, RPG2003): quit, the way the title screen's Shutdown
      # entry does.
      def perform_exit_game
        @interpreter.stop
        exit
      end

      # Open Main Menu (11950): push the field menu over the map, then resume the
      # event once the player closes it again. `@event_menu` marks that this
      # scene is waiting on its own menu, so the event stays paused for exactly
      # one visit instead of re-opening it every frame.
      def perform_event_menu
        if @event_menu
          @event_menu = false
          @interpreter.resume
        else
          @event_menu = true
          @parent.push Scene::Menu.new(@parent, @state)
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] Open Main Menu failed: #{e.message}"
        @event_menu = false
        @interpreter.resume
      end

      # -- Move Event (Set Move Route) ----------------------------------------

      # Apply the Move Event requests an interpreter queued this step. `this_event`
      # is the map event running that process (or nil for a common event), so a
      # route targeting "this event" reaches the right character.
      def apply_move_requests(interp, this_event)
        reqs = interp.take_move_route_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_move_request(r, this_event) }
      rescue StandardError => e
        $stderr.puts "[RPG2k] Move Event apply failed: #{e.message}"
        nil
      end

      def apply_move_request(r, this_event)
        route = Game::MoveRoute.new(r[:commands], repeat: r[:repeat],
                                    skippable: r[:skippable])
        return if route.empty?
        case r[:target]
        when MOVE_TARGET_PLAYER
          start_player_route(route, r[:frequency])
        when 0, MOVE_TARGET_THIS
          force_event_route(this_event, route, r[:frequency]) if this_event
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          nil # vehicles are not modelled yet
        else
          ev = @events.find { |e| e[:id] == r[:target] }
          force_event_route(ev, route, r[:frequency]) if ev
        end
      end

      # -- Change / Trade Event Location --------------------------------------

      # Apply the instant-reposition requests an interpreter queued this step
      # (Change Event Location / Trade Event Locations). `this_event` is the map
      # event running the process (or nil), so a request targeting "this event"
      # reaches the right character.
      def apply_location_requests(interp, this_event)
        reqs = interp.take_location_requests
        return if reqs.nil? || reqs.empty?
        reqs.each { |r| apply_location_request(r, this_event) }
      rescue StandardError => e
        $stderr.puts "[RPG2k] Event location change failed: #{e.message}"
        nil
      end

      def apply_location_request(r, this_event)
        if r[:op] == :swap
          a = char_location(r[:a], this_event)
          b = char_location(r[:b], this_event)
          return unless a && b
          set_char_location(r[:a], this_event, b[0], b[1])
          set_char_location(r[:b], this_event, a[0], a[1])
        else
          set_char_location(r[:target], this_event, r[:x], r[:y])
        end
      end

      # The current tile of a target character (the same target ids as Move
      # Event), or nil for the player-less vehicle slots / a missing event.
      def char_location(target, this_event)
        case target
        when MOVE_TARGET_PLAYER
          [@state.x, @state.y]
        when 0, MOVE_TARGET_THIS
          this_event ? [this_event[:char].x, this_event[:char].y] : nil
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          nil # vehicles are not modelled yet
        else
          ev = @events.find { |e| e[:id] == target }
          ev ? [ev[:char].x, ev[:char].y] : nil
        end
      end

      # Instantly move a target character to a tile.
      def set_char_location(target, this_event, x, y)
        case target
        when MOVE_TARGET_PLAYER
          move_player_to(x, y)
        when 0, MOVE_TARGET_THIS
          move_event_to(this_event, x, y) if this_event
        when MOVE_TARGET_BOAT, MOVE_TARGET_SHIP, MOVE_TARGET_AIRSHIP
          nil # vehicles are not modelled yet
        else
          ev = @events.find { |e| e[:id] == target }
          move_event_to(ev, x, y) if ev
        end
      end

      # Snap the player to a tile: cancel any in-progress step and keep a forced
      # route's mirror character (if one is running) in sync so it steps on from
      # the new tile.
      def move_player_to(x, y)
        @state.x = x
        @state.y = y
        @dest_x = x
        @dest_y = y
        @moving = false
        @move_count = 0
        if @player_char
          @player_char.x = x
          @player_char.y = y
        end
      end

      # Snap an event to a tile and refresh the occupied-tile cache so collision
      # and the marker follow it.
      def move_event_to(ev, x, y)
        return unless ev
        ox = ev[:char].x
        oy = ev[:char].y
        ev[:char].x = x
        ev[:char].y = y
        reoccupy(ev, ox, oy)
      end

      # Give a map event a forced route, overriding its page movement until the
      # route finishes (a repeating route runs until replaced). It steps on the
      # next frame, paced by the requested frequency when one was given.
      def force_event_route(ev, route, freq)
        ev[:forced_route] = route
        ev[:forced_freq] = valid_move_freq(freq)
        ev[:move_timer] = 0
      end

      # Drive the player along a forced route: the player has no Game::Character,
      # so mirror one, step it against the map world and slide the party after
      # it. Input movement is suppressed while the route is active.
      def start_player_route(route, freq)
        @player_char = Game::Character.new(@state.x, @state.y, @state.direction)
        @player_char.move_frequency = valid_move_freq(freq) ||
                                      @player_char.move_frequency
        @player_route = route
        @player_route_timer = 0
      end

      # Take one step of the player's forced route, if its pacing timer is up.
      #
      # A step in progress has to land before the next one begins: the route
      # character runs ahead of the party (it is what the route steps), and the
      # party's own tile only catches up when the slide completes, so stepping
      # again mid-slide would leave the two more than a tile apart and stretch
      # one slide over the gap. That also caps a forced route at the walking
      # pace, which is what it moves at on screen.
      def step_player_route
        return unless @player_route
        return if @moving
        @player_route_timer -= 1
        return if @player_route_timer > 0
        @player_route_timer = EVENT_MOVE_DELAY[@player_char.move_frequency] || 40
        ox = @player_char.x
        oy = @player_char.y
        @player_route.step(@player_char, @world) unless @player_route.done?
        @state.direction = @player_char.direction
        if @player_char.x != ox || @player_char.y != oy || @player_char.jumped
          start_player_slide
        end
        @player_route = nil if @player_route.done?
      end

      # Begin the party's slide toward wherever the route character now stands.
      # The party stays on its own tile until the slide lands (as it does for
      # ordinary walking), so everything reading @state.x/y sees a character on a
      # tile rather than between two.
      def start_player_slide
        @dest_x = @player_char.x
        @dest_y = @player_char.y
        @moving = true
        @move_count = 0
        @player_jumping = @player_char.jumped
      end

      # Advance the party's pixel slide by one frame, landing it on the
      # destination tile when the slide completes. Returns true while a slide is
      # still in progress.
      #
      # Shared by ordinary movement and by Proceed With Movement, which drives
      # forced routes while the normal movement step is skipped -- without the
      # slide progressing there, a forced route would start a step and then wait
      # for a landing that never came.
      def advance_player_slide
        return false unless @moving
        @move_count += SPEED
        if @move_count >= TILE
          @state.x = @dest_x
          @state.y = @dest_y
          @moving = false
          @move_count = 0
          @player_jumping = false
          note_party_step
          follow_vehicle if @state.boarded? # the ridden vehicle tracks the party
        end
        # True for the landing frame as well as the ones before it: that frame
        # is spent finishing the step, not starting the next one.
        true
      end

      # How far the party's sprite is lifted off the ground this frame, in
      # pixels. The event arc, applied to the hero: a forced route is the only
      # thing that can make the player jump, and RPG_RT hops it the same way.
      def player_jump_offset
        return 0 unless @player_jumping && @moving
        jump_offset_for(@move_count)
      end

      # Advance every forced move route in progress one frame — the player's and
      # each event's — while the interpreter is paused on Proceed With Movement
      # (the normal per-frame movement is skipped because an event is running).
      # Returns true once no forced route remains, so the caller can resume the
      # interpreter. A repeating forced route never reports done, matching RPG_RT.
      def step_forced_movement
        advance_player_slide
        step_player_route
        @events.each { |e| step_forced_event(e) if e[:forced_route] }
        forced_movement_done?
      end

      # Pace and advance one event's forced route, mirroring step_event's forced
      # branch (used only while waiting on Proceed With Movement).
      def step_forced_event(e)
        ch = e[:char]
        e[:move_timer] -= 1
        return if e[:move_timer] > 0
        e[:move_timer] = EVENT_MOVE_DELAY[e[:forced_freq] || ch.move_frequency] || 40
        ox = ch.x
        oy = ch.y
        e[:forced_route].step(ch, @world) unless e[:forced_route].done?
        e[:forced_route] = nil if e[:forced_route].done?
        # A jump that lands where it started still needs the render slide, so
        # the hop is visible; an ordinary step only when the tile changed.
        reoccupy(e, ox, oy) if ch.x != ox || ch.y != oy || ch.jumped
      rescue StandardError => ex
        $stderr.puts "[RPG2k] forced movement failed: #{ex.message}"
        e[:forced_route] = nil # drop a broken route so Proceed does not hang
      end

      # Whether no forced move route is still running (player or any event).
      # Spelled as !any? rather than none?: Enumerable#none? lives in mruby's
      # optional mruby-enum-ext gem, which this build does not pull in, so it
      # exists under the CRuby host checks but not in the shipped engine.
      def forced_movement_done?
        return false if @player_route
        !@events.any? { |e| e[:forced_route] }
      end

      # A move frequency the request may override the target's pace with (1..8),
      # or nil to keep the target's own frequency.
      def valid_move_freq(f)
        (f && f >= 1 && f <= 8) ? f : nil
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

      # Collision test for a jump landing on (x, y): the same rules as a step —
      # in bounds, not onto the player or another event, passable per the chipset
      # — but applied to an arbitrary tile rather than the one ahead, and entered
      # from the jump's dominant direction. The tiles the jump passes over are
      # deliberately not tested: RPG_RT skips the "may I leave" half of its check
      # while jumping, which is what lets a jump clear a wall.
      def char_can_land?(character, x, y)
        return true if character.through
        # A hop that lands on the tile it left is always allowed: the character
        # occupies that tile itself, so every occupancy test below would refuse
        # it and RPG2000's hop-in-place could never happen. Found by drawing the
        # arc -- the in-place hop was silently impossible before there was
        # anything on screen to notice it by.
        return true if x == character.x && y == character.y
        return false unless @map.in_bounds?(x, y)
        return false if x == @state.x && y == @state.y
        return false if @event_tiles[[x, y]]
        return true if @chipset.nil?
        @chipset.passable?(@map.lower(x, y), jump_entry_direction(character, x, y))
      end
      public :char_can_land?

      # The direction a jump from the character's tile enters (x, y) by: its
      # dominant axis, vertical winning a tie, matching the facing Character#jump
      # lands on.
      def jump_entry_direction(character, x, y)
        dx = x - character.x
        dy = y - character.y
        if dy.abs >= dx.abs
          dy >= 0 ? 2 : 8
        else
          dx >= 0 ? 6 : 4
        end
      end

      # Terrain id of the lower-layer tile at (x, y), for the Store Terrain ID
      # command (0 when out of bounds or no chipset). Queried by the interpreter
      # via its map_info hook.
      def terrain_id(x, y)
        return 0 if @chipset.nil? || !@map.in_bounds?(x, y)
        @chipset.terrain(@map.lower(x, y))
      end
      public :terrain_id

      # Id of the event standing on tile (x, y), for the Store Event ID command
      # (0 when no event is there). Queried by the interpreter via map_info.
      def event_id_at(x, y)
        ev = @event_tiles[[x, y]]
        ev ? ev[:id] : 0
      end
      public :event_id_at

      # Position of the map event with the given id (its tile x/y and facing), for
      # the Control Variables "character" operand, or nil when there is no such
      # event. Queried by the interpreter via map_info.
      def event_position(id)
        ev = @events.find { |e| e[:id] == id }
        return nil unless ev
        c = ev[:char]
        { x: c.x, y: c.y, direction: c.direction }
      end
      public :event_position

      # The cancel button opens the main menu over the map, unless a Change Main
      # Menu Access command has forbidden it.
      def try_open_menu
        return if event_busy?
        return unless @state.menu_access
        return unless Input.trigger?(Input::B)
        @parent.push Scene::Menu.new(@parent, @state)
      end

      def drive_event
        if @message
          drive_message
          return
        end

        if @number_input
          drive_number_input
          return
        end

        if @interpreter.waiting?
          case @interpreter.wait_kind
          when :message then open_message(@interpreter.message_lines, false)
          when :choice then open_message(@interpreter.choice_labels, true)
          when :number then open_number_input(@interpreter.input_digits)
          when :key_input then drive_key_input
          when :inn then drive_inn
          when :shop then drive_shop
          when :battle then drive_battle
          when :wait then drive_wait
          when :teleport then perform_teleport(@interpreter.teleport)
          when :movement then @interpreter.resume if step_forced_movement
          when :screen then @interpreter.resume unless @state.screen.busy?
          when :picture then @interpreter.resume unless @state.pictures_moving?
          when :return_title then perform_return_to_title
          when :game_over then perform_game_over
          when :name_input then drive_name_input
          when :animation then drive_map_animation
          when :sprite_flash then @interpreter.resume unless sprite_flashing?
          when :save_menu then perform_event_save
          when :menu then perform_event_menu
          when :load_menu then perform_event_load
          when :exit_game then perform_exit_game
          end
        else
          @interpreter.update
          apply_interpreter_requests(@interpreter, @active_event)
        end
      end

      # Drain every non-blocking request the interpreter queued this step and
      # apply it to the map / scene. Shared by the foreground event and each
      # parallel process, so both surfaces honour the same commands.
      def apply_interpreter_requests(interp, this_event)
        apply_move_requests(interp, this_event)
        apply_location_requests(interp, this_event)
        apply_erase_request(interp, this_event)
        apply_halt_request(interp)
        apply_graphic_change(interp)
        apply_tileset_request(interp)
        apply_parallax_request(interp)
        apply_tile_substitution(interp)
        apply_sprite_flash_requests(interp, this_event)
        apply_vehicle_toggle(interp)
        apply_movie_request(interp)
      end

      # Maps the interpreter's accepted-key symbols onto RGSS input buttons.
      # Decision (OK) is the confirm button C, Cancel is B — the same mapping the
      # message and menu widgets use.
      KEY_INPUT_BUTTONS = {
        down: Input::DOWN, left: Input::LEFT, right: Input::RIGHT,
        up: Input::UP, decision: Input::C, cancel: Input::B, shift: Input::SHIFT
      }.freeze

      def drive_key_input
        resolve_key_input(@interpreter)
      end

      # Drive a Key Input Processing wait for interpreter `it` (the foreground
      # event or a parallel process): sample the accepted buttons and hand back
      # the resulting RPG2000 key code. A waiting proc uses triggered edges and
      # only resumes once a key is actually pressed; a no-wait proc reads the
      # held state and resumes immediately (storing 0 when nothing is down),
      # matching RPG_RT.
      def resolve_key_input(it)
        req = it.key_input_request
        return it.resume_key_input(0) unless req
        accepted = req[:accepted]
        active = []
        KEY_INPUT_BUTTONS.each do |sym, btn|
          next unless accepted[sym]
          hit = req[:wait] ? Input.trigger?(btn) : Input.press?(btn)
          active << sym if hit
        end
        code = it.key_input_result(active)
        if req[:wait]
          it.resume_key_input(code) if code != 0
        else
          it.resume_key_input(code)
        end
      end

      # -- Show Inn (Stay at Inn) ---------------------------------------------

      INN_LINE_H = 14

      # Drive a Show Inn wait: a free stay (price 0) resumes at once; otherwise a
      # greeting window with Accept / Cancel choices and a gold window is shown,
      # Accept selectable only when the party can afford the price. The
      # interpreter charges gold and heals the party in resume_inn.
      def drive_inn
        req = @interpreter.inn_request
        return @interpreter.resume_inn(false) unless req
        return @interpreter.resume_inn(true) unless req[:prompt]

        if @inn_window.nil?
          open_inn_window(req) # opened this frame; take input from the next one
          return
        end
        if Input.trigger?(Input::DOWN) && @inn_choice < 1
          @inn_choice += 1
          set_inn_cursor
        elsif Input.trigger?(Input::UP) && @inn_choice > 0
          @inn_choice -= 1
          set_inn_cursor
        elsif Input.trigger?(Input::C)
          if @inn_choice.zero?
            # Accept: only honoured when the party can pay; otherwise ignored.
            if req[:can_afford]
              close_inn_window
              @interpreter.resume_inn(true)
            end
          else
            close_inn_window
            @interpreter.resume_inn(false)
          end
        elsif Input.trigger?(Input::B)
          close_inn_window
          @interpreter.resume_inn(false)
        end
      end

      # RPG2000 inn term set (A or B) selected by the command's type parameter.
      # Blank database terms (e.g. a bare test project) fall back to plain
      # English so the window is never empty.
      def inn_terms(type)
        t = db.term
        a = type.zero?
        {
          greet1: nonblank(a ? t.inn_a_greeting_1 : t.inn_b_greeting_1, 'Stay the night for'),
          greet2: nonblank(a ? t.inn_a_greeting_2 : t.inn_b_greeting_2, '?'),
          greet3: nonblank(a ? t.inn_a_greeting_3 : t.inn_b_greeting_3, 'Will you stay?'),
          accept: nonblank(a ? t.inn_a_accept : t.inn_b_accept, 'Yes'),
          cancel: nonblank(a ? t.inn_a_cancel : t.inn_b_cancel, 'No')
        }
      end

      def nonblank(s, fallback)
        s = s.to_s
        s.empty? ? fallback : s
      end

      def open_inn_window(req)
        terms = inn_terms(req[:type])
        gold_term = nonblank(db.term.gold, 'G')
        lines = ["#{terms[:greet1]} #{req[:price]}#{gold_term} #{terms[:greet2]}".strip,
                 terms[:greet3], terms[:accept], terms[:cancel]]
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = lines.length * INN_LINE_H
        win = Window.new(10, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        contents = Bitmap.new(inner_w, inner_h)
        contents.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          contents.draw_text 0, i * INN_LINE_H, inner_w, INN_LINE_H, line
        end
        win.contents = contents

        gwin = build_inn_gold_window(gold_term)
        @inn_window = { window: win, gold: gwin }
        # Start on Accept when affordable, else on Cancel.
        @inn_choice = req[:can_afford] ? 0 : 1
        set_inn_cursor
      end

      # A small window showing the party's current gold, mirroring the RPG2000
      # inn's gold display.
      def build_inn_gold_window(gold_term)
        gw = 88
        gh = INN_LINE_H + Window::BORDER * 2
        win = Window.new(SCREEN_W - gw - 6, 6, gw, gh)
        win.z = 300
        win.windowskin = @windowskin
        c = Bitmap.new(gw - Window::BORDER * 2, INN_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, INN_LINE_H, "#{@state.party.gold}#{gold_term}"
        win.contents = c
        win
      end

      # The Accept / Cancel lines sit below the two greeting lines, so the cursor
      # row is offset by 2.
      def set_inn_cursor
        return unless @inn_window
        win = @inn_window[:window]
        row = 2 + @inn_choice
        win.cursor_rect = Rect.new(0, row * INN_LINE_H, win.contents.width, INN_LINE_H)
      end

      def close_inn_window
        return unless @inn_window
        @inn_window[:window].dispose
        @inn_window[:gold].dispose if @inn_window[:gold]
        @inn_window = nil
      end

      # -- Open Shop (buy / sell) ---------------------------------------------

      SHOP_LINE_H = 14

      # Drive an Open Shop wait. On the first frame the shop opens (a command
      # menu for a buy+sell shop, or straight to the buy / sell list for a
      # single-mode shop). Buying and selling happen one unit per confirm on
      # Game::Shop; leaving resumes the interpreter with whether anything was
      # traded (which picks the [Transaction] / [No Transaction] branch).
      def drive_shop
        req = @interpreter.shop_request
        return @interpreter.resume_shop(false) unless req
        if @shop.nil?
          open_shop(req) # opened this frame; take input from the next one
          return
        end
        case @shop[:screen]
        when :command  then drive_shop_command
        when :quantity then drive_shop_quantity
        else drive_shop_list
        end
      end

      def open_shop(req)
        model = Game::Shop.new(db, @state.party, req[:goods],
                               req[:allow_buy], req[:allow_sell])
        has_menu = req[:allow_buy] && req[:allow_sell]
        screen = has_menu ? :command : (req[:allow_buy] ? :buy : :sell)
        @shop = { model: model, has_menu: has_menu, screen: screen, index: 0,
                  window: nil, gold: build_shop_gold_window }
        draw_shop
      end

      def shop_gold_term; nonblank(db.term.gold, 'G'); end

      def build_shop_gold_window
        gw = 88
        win = Window.new(SCREEN_W - gw - 6, 6, gw, SHOP_LINE_H + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        win
      end

      # The [label, target] rows for the current shop screen: the command menu's
      # actions, the goods on the buy list, or the party's sellable items.
      def shop_lines
        m = @shop[:model]
        case @shop[:screen]
        when :command
          rows = []
          rows << ['Buy', :buy] if m.allow_buy?
          rows << ['Sell', :sell] if m.allow_sell?
          rows << ['Leave', :leave]
          rows
        when :quantity
          # The counter is one row: how many, and what the stack comes to.
          q = @shop[:quantity]
          unit = q[:mode] == :buy ? m.price(q[:id]) : m.sell_price(q[:id])
          verb = q[:mode] == :buy ? 'Buy' : 'Sell'
          [["#{verb} #{m.name(q[:id])} x#{q[:count]}  " \
            "#{unit * q[:count]}#{shop_gold_term}", q[:id]]]
        when :buy
          m.goods.map { |id| ["#{m.name(id)}  #{m.price(id)}#{shop_gold_term}", id] }
        else # :sell
          m.sellable_items.map do |id|
            ["#{m.name(id)} x#{@state.party.item_count(id)}  " \
             "#{m.sell_price(id)}#{shop_gold_term}", id]
          end
        end
      end

      def draw_shop
        lines = shop_lines
        @shop[:index] = Game.clamp(@shop[:index], 0, [lines.length - 1, 0].max)
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = [lines.length, 1].max * SHOP_LINE_H
        @shop[:window].dispose if @shop[:window]
        win = Window.new(10, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = 300
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |(label, _), i|
          c.draw_text 0, i * SHOP_LINE_H, inner_w, SHOP_LINE_H, label
        end
        win.contents = c
        unless lines.empty?
          win.cursor_rect =
            Rect.new(0, @shop[:index] * SHOP_LINE_H, inner_w, SHOP_LINE_H)
        end
        @shop[:window] = win
        draw_shop_gold
      end

      def draw_shop_gold
        gw = 88
        c = Bitmap.new(gw - Window::BORDER * 2, SHOP_LINE_H)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, SHOP_LINE_H,
                    "#{@state.party.gold}#{shop_gold_term}"
        @shop[:gold].contents = c
      end

      def drive_shop_command
        lines = shop_lines
        if shop_move_cursor(lines)
          # cursor moved
        elsif Input.trigger?(Input::C)
          case lines[@shop[:index]][1]
          when :buy  then shop_switch(:buy)
          when :sell then shop_switch(:sell)
          when :leave then leave_shop
          end
        elsif Input.trigger?(Input::B)
          leave_shop
        end
      end

      def drive_shop_list
        lines = shop_lines
        if shop_move_cursor(lines)
          # cursor moved
        elsif Input.trigger?(Input::C) && !lines.empty?
          open_shop_quantity(lines[@shop[:index]][1])
        elsif Input.trigger?(Input::B)
          @shop[:has_menu] ? shop_switch(:command) : leave_shop
        end
      end

      # How far LEFT / RIGHT jump the quantity cursor — RPG_RT's shop counter
      # moves in tens on the horizontal axis so a stack of 99 is a few presses
      # away rather than ninety-nine.
      SHOP_QUANTITY_STEP = 10

      # Picking an item opens the quantity counter rather than transacting one
      # unit: RPG2000 asks how many, bounded by what the party can afford, the
      # 99-item cap, or (selling) what it holds. An item with no room at all —
      # unaffordable, already capped — never opens the counter.
      def open_shop_quantity(id)
        model = @shop[:model]
        max = @shop[:screen] == :buy ? model.max_buy(id) : model.max_sell(id)
        return if max < 1
        @shop[:quantity] = { id: id, count: 1, max: max, mode: @shop[:screen] }
        @shop[:screen] = :quantity
        draw_shop
      end

      # Drive the quantity counter: UP / DOWN by one, RIGHT / LEFT by ten (both
      # clamped to 1..max), C commits the whole stack in one transaction and B
      # goes back to the list having bought nothing.
      def drive_shop_quantity
        q = @shop[:quantity]
        if shop_quantity_move(q)
          draw_shop
        elsif Input.trigger?(Input::C)
          model = @shop[:model]
          q[:mode] == :buy ? model.buy(q[:id], q[:count]) : model.sell(q[:id], q[:count])
          close_shop_quantity
        elsif Input.trigger?(Input::B)
          close_shop_quantity
        end
      end

      # Apply one frame of quantity input; returns whether the count changed.
      def shop_quantity_move(q)
        before = q[:count]
        if Input.trigger?(Input::UP)
          q[:count] += 1
        elsif Input.trigger?(Input::DOWN)
          q[:count] -= 1
        elsif Input.trigger?(Input::RIGHT)
          q[:count] += SHOP_QUANTITY_STEP
        elsif Input.trigger?(Input::LEFT)
          q[:count] -= SHOP_QUANTITY_STEP
        else
          return false
        end
        q[:count] = Game.clamp(q[:count], 1, q[:max])
        q[:count] != before
      end

      # Leave the counter for the list it was opened from, refreshing the gold
      # and (after a sale) the shrunk list.
      def close_shop_quantity
        @shop[:screen] = @shop[:quantity][:mode]
        @shop[:quantity] = nil
        draw_shop
      end

      # Move the shop cursor with Up / Down; returns true if it moved.
      def shop_move_cursor(lines)
        if Input.trigger?(Input::DOWN) && @shop[:index] < lines.length - 1
          @shop[:index] += 1
          draw_shop
          true
        elsif Input.trigger?(Input::UP) && @shop[:index] > 0
          @shop[:index] -= 1
          draw_shop
          true
        else
          false
        end
      end

      def shop_switch(screen)
        @shop[:screen] = screen
        @shop[:index] = 0
        draw_shop
      end

      def leave_shop
        transacted = @shop[:model].did_transaction
        close_shop
        @interpreter.resume_shop(transacted)
      end

      def close_shop
        return unless @shop
        @shop[:window].dispose if @shop[:window]
        @shop[:gold].dispose if @shop[:gold]
        @shop = nil
      end

      # -- Enemy Encounter (turn-based battle) --------------------------------

      # The battle runs on Combatant snapshots of the party (Game::Battle), so a
      # resolved fight leaves the real party HP untouched for now — persisting HP
      # is still to come. On victory the troop's EXP / gold are granted and the
      # [Victory] handler runs; escape routes its handler. A defeat routes the
      # [Defeat] handler when the encounter defines one, or ends the game (return
      # to title) when its defeat mode is "game over".
      #
      # Drive the turn-based battle screen the map shows during a :battle wait.
      # Each round the player commands every living party member — Attack a chosen
      # enemy, cast a Skill (on an enemy or ally), use an Item on an ally, or
      # Defend — then the round plays out action by action in agility order (one
      # action landing per BATTLE_ANIM_FRAMES, each bannered with its HP tick)
      # until a side falls. B on the first actor flees when the encounter allows
      # it. Dismissing the result resumes the event with the outcome.
      def drive_battle
        req = @interpreter.battle_request
        return @interpreter.resume_battle(:victory) unless req
        if @battle_ui.nil?
          open_battle(req) # opened this frame; take input from the next one
          return
        end
        case @battle_ui[:phase]
        when :command     then drive_battle_command
        when :target      then drive_battle_target
        when :skill       then drive_battle_skill
        when :item        then drive_battle_item
        when :ally_target then drive_battle_ally_target
        when :animate     then drive_battle_animate
        when :result      then drive_battle_result
        when :event       then drive_battle_event
        end
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle failed: #{e.message}"
        close_battle
        @interpreter.resume_battle(:victory)
      end

      def open_battle(req)
        troop = Game::Troop.new(db, req[:troop_id])
        allies = @state.party.actors.map { |a| Game::Battle.from_actor(a) }
        foes = troop.members.map { |e| Game::Battle.from_enemy(e) }
        # The database's state table drives per-turn afflictions (poison slip,
        # sleep skip) in battle.
        situations = db.respond_to?(:situation) ? db.situation : nil
        properties = db.respond_to?(:property) ? db.property : nil
        @battle_ui = { phase: :command, req: req, troop: troop,
                       battle: Game::Battle.new(allies, foes, Game::Rng.new(0x2000),
                                                situations, true, true, true,
                                                req[:first_strike] ? true : false,
                                                properties,
                                                # Lets the troop run its 行動パターン:
                                                # skills, transformations and the
                                                # switch / party-level conditions.
                                                Game::EnemyAi.new(db, @state)),
                       allies: allies, foes: foes, actor_i: 0, cmd: 0, target_i: 0,
                       skill_i: 0, item_i: 0, ally_i: 0, pending: nil,
                       skills: [], items: [],
                       status_win: nil, cmd_win: nil, target_win: nil,
                       skill_win: nil, item_win: nil, ally_win: nil,
                       action_win: nil, anim_timer: 0,
                       back_sprite: nil, enemy_sprites: nil,
                       result_win: nil, result: nil,
                       # The troop's battle-event pages: their own interpreter,
                       # the message window they draw into, and which pages have
                       # already fired this turn (RPG2000 runs a page once per
                       # turn its condition holds, so this resets each round).
                       events: Game::Interpreter.new(@state), event_win: nil,
                       pages_run: {} }
        @battle_ui[:events].battle = @battle_ui[:battle]
        # A battle page can Call Common Event (1005), so it needs the same
        # resolver the map's events run against.
        @battle_ui[:events].resolver = @interpreter.resolver
        build_battle_sprites
        refresh_battle_status
        # Turn-0 pages fire before the party is asked for its first command —
        # this is where a troop's opening dialogue lives.
        draw_battle_command unless run_battle_events
      end

      # RPG2000 is a front-view battle: the enemy troop is drawn as sprites over a
      # battle background, while the party is represented by the status window (not
      # sprites). Build the backdrop and one sprite per visible troop member,
      # centred on its database position. Hidden (invisible) members get no sprite
      # until a battle event reveals them — a mechanism still to come.
      def build_battle_sprites
        build_battle_back(encounter_backdrop)
        @battle_ui[:enemy_sprites] = @battle_ui[:troop].members.each_with_index.map do |enemy, i|
          next nil if enemy.hidden
          bmp = battler_bitmap(enemy)
          spr = Sprite.new
          spr.bitmap = bmp
          spr.x = enemy.x - bmp.width / 2
          spr.y = enemy.y - bmp.height / 2
          spr.z = 100 + i
          spr
        end
        # The battler each sprite was drawn from, so a transformation mid-fight
        # is noticed and redrawn (see #refresh_battle_sprites).
        @battle_ui[:sprite_names] = @battle_ui[:foes].map { |f| f.battler_name }
        refresh_battle_sprites
      end

      # Where a battle-event page's message panel sits — above the action banner,
      # so a page talking mid-round does not fight it for the same row.
      BATTLE_EVENT_MSG_Y = 8

      # The backdrop this encounter fights over: whatever Game::Backdrop resolves
      # for the current map, given the terrain the party is standing on. '' when
      # nothing names one, which draws the flat field.
      def encounter_backdrop
        Game::Backdrop.name_for(@state.map_id, map_properties,
                                terrain_backdrop(@state.x, @state.y))
      end

      # The map tree's map_properties table, or nil when this build has no tree
      # (the scene harnesses construct a map directly).
      def map_properties
        return nil unless respond_to?(:map_tree) && map_tree
        map_tree.respond_to?(:map_properties) ? map_tree.map_properties : nil
      rescue StandardError
        nil
      end

      # The backdrop named by the terrain of the tile at (x, y) — the database
      # terrain row's `background_name` (field 4). '' when the tile, the terrain
      # table or the field is missing.
      def terrain_backdrop(x, y)
        tid = terrain_id(x, y)
        return '' unless tid && tid > 0 && db.respond_to?(:terrain)
        row = db.terrain[tid]
        return '' unless row && row.respond_to?(:background_name)
        row.background_name.to_s
      rescue StandardError => e
        $stderr.puts "[RPG2k] terrain backdrop lookup failed: #{e.message}"
        ''
      end

      def build_battle_back(name = nil)
        bmp = battle_back_bitmap(name)
        spr = Sprite.new
        spr.bitmap = bmp
        spr.z = 5
        @battle_ui[:back_sprite] = spr
      end

      # The battle backdrop: the Backdrop/<name> image a Change Battle Background
      # command (or the encounter) named, falling back to the flat colour field
      # when there is no name or the file is missing — the same fallback the map
      # uses for a missing chipset.
      def battle_back_bitmap(name)
        return Bitmap.new("Backdrop/#{name}") if name && !name.empty?
        flat_battle_back
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle backdrop '#{name}' failed to load: #{e.message}"
        flat_battle_back
      end

      def flat_battle_back
        bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, Color.new(16, 16, 32, 255)
        bmp
      end

      # Change Battle Background (13210): swap the backdrop mid-fight, releasing
      # the sprite and bitmap the old one held.
      def rebuild_battle_back(name)
        dispose_battle_sprite(@battle_ui[:back_sprite])
        @battle_ui[:back_sprite] = nil
        build_battle_back(name)
      end

      # The battler graphic for `enemy` (Monster/<battler_name>, colour-keyed), or
      # a solid placeholder block when it has no graphic or the file is missing —
      # the same fallback strategy the map uses for a missing chipset.
      def battler_bitmap(enemy)
        name = enemy.battler_name
        return Bitmap.new("Monster/#{name}", true) if name && !name.empty?
        placeholder_battler
      rescue StandardError => e
        $stderr.puts "[RPG2k] battler load failed for #{enemy.name}: #{e.message}"
        placeholder_battler
      end

      def placeholder_battler
        bmp = Bitmap.new(32, 32)
        bmp.fill_rect 0, 0, 32, 32, Color.new(180, 60, 60, 255)
        bmp
      end

      # Show a living enemy's sprite, hide a defeated one — called after each
      # animated action so a downed enemy vanishes from the field.
      def refresh_battle_sprites
        sprites = @battle_ui[:enemy_sprites]
        return unless sprites
        # A transformation swaps a monster's graphic mid-fight, so redraw any
        # combatant no longer wearing the battler its sprite was built from
        # before deciding what is visible.
        names = (@battle_ui[:sprite_names] ||= [])
        @battle_ui[:foes].each_with_index do |foe, i|
          rebuild_battler_sprite(i, foe) if sprites[i] && names[i] != foe.battler_name
        end
        @battle_ui[:foes].each_with_index do |foe, i|
          spr = sprites[i]
          # Out of play, not merely dead: a monster that has fled (its own Escape
          # action, or a page's Force Flee) or one still flagged invisible is off
          # the field and must not be drawn — the same test #living_foes uses to
          # keep it out of the target cursor.
          spr.visible = !foe.out_of_play? if spr
        end
      end

      # Redraw troop slot `i` with `foe`'s current battler graphic, keeping its
      # place and depth, and release the sprite and bitmap the old one held.
      def rebuild_battler_sprite(i, foe)
        sprites = @battle_ui[:enemy_sprites]
        member = @battle_ui[:troop].members[i]
        return unless member
        old = sprites[i]
        bmp = battler_bitmap(foe)
        spr = Sprite.new
        spr.bitmap = bmp
        spr.x = member.x - bmp.width / 2
        spr.y = member.y - bmp.height / 2
        spr.z = 100 + i
        spr.visible = !foe.out_of_play?
        sprites[i] = spr
        dispose_battle_sprite(old)
        @battle_ui[:sprite_names][i] = foe.battler_name
      end

      def living_allies; @battle_ui[:allies].reject(&:dead?); end
      # Targetable foes: alive *and* in play, so a troop member still flagged
      # invisible never appears in the target cursor.
      def living_foes;   @battle_ui[:foes].reject(&:out_of_play?); end
      def current_actor; living_allies[@battle_ui[:actor_i]]; end

      # The real Game::Actor behind the current battler (the snapshots are built
      # from the party in order), so the Skill menu can read its known skills.
      def current_actor_row
        idx = @battle_ui[:allies].index(current_actor)
        idx ? @state.party.actors[idx] : nil
      end

      # The four per-actor commands, in menu order (the cursor row is 1 + index,
      # below the actor-name header).
      BATTLE_COMMANDS = %w[Attack Skill Item Defend].freeze

      # Per-actor command menu: Attack, Skill, Item or Defend.
      def drive_battle_command
        last = BATTLE_COMMANDS.length - 1
        if Input.trigger?(Input::DOWN) && @battle_ui[:cmd] < last
          @battle_ui[:cmd] += 1
          draw_battle_command
        elsif Input.trigger?(Input::UP) && @battle_ui[:cmd] > 0
          @battle_ui[:cmd] -= 1
          draw_battle_command
        elsif Input.trigger?(Input::C)
          select_battle_command
        elsif Input.trigger?(Input::B)
          if @battle_ui[:actor_i].zero?
            try_battle_escape if @battle_ui[:req][:allow_escape]
          else
            @battle_ui[:actor_i] -= 1 # re-command the previous member
            @battle_ui[:cmd] = 0
            draw_battle_command
          end
        end
      end

      # Escape command (cancel on the first actor's menu): roll the party's
      # agility-based escape chance. On success flee the fight; on a failed roll
      # the party forfeits the round — every member skips and only the enemies
      # act — and the next attempt is likelier (Game::Battle#attempt_escape).
      def try_battle_escape
        battle = @battle_ui[:battle]
        if battle.attempt_escape
          finish_battle(:escape)
        else
          $stderr.puts '[RPG2k battle] escape failed'
          living_allies.each { |a| battle.command_skip(a) }
          start_round_animation
        end
      end

      # Act on the highlighted command: Attack / Skill open a selection, Defend
      # is committed at once.
      def select_battle_command
        case @battle_ui[:cmd]
        when 0 # Attack
          @battle_ui[:pending] = { kind: :attack }
          @battle_ui[:target_i] = 0
          @battle_ui[:phase] = :target
          draw_battle_target
        when 1 then open_battle_skill
        when 2 then open_battle_item
        when 3 # Defend
          @battle_ui[:battle].command_defend(current_actor)
          advance_actor
        end
      end

      # Enemy target-selection menu: pick which living enemy the Attack (or an
      # enemy-scope Skill) hits.
      def drive_battle_target
        foes = living_foes
        if Input.trigger?(Input::DOWN) && @battle_ui[:target_i] < foes.length - 1
          @battle_ui[:target_i] += 1
          draw_battle_target
        elsif Input.trigger?(Input::UP) && @battle_ui[:target_i] > 0
          @battle_ui[:target_i] -= 1
          draw_battle_target
        elsif Input.trigger?(Input::C)
          target = foes[@battle_ui[:target_i]]
          close_battle_target
          if pending_kind == :skill
            apply_pending_skill(target)
          else
            @battle_ui[:battle].command_attack(current_actor, target)
            @battle_ui[:pending] = nil
            @battle_ui[:phase] = :command
            advance_actor
          end
        elsif Input.trigger?(Input::B)
          close_battle_target
          if pending_kind == :skill
            @battle_ui[:phase] = :skill
            draw_battle_skill
          else
            @battle_ui[:pending] = nil
            @battle_ui[:phase] = :command
            draw_battle_command
          end
        end
      end

      def pending_kind; @battle_ui[:pending] && @battle_ui[:pending][:kind]; end

      # -- Skill sub-menu ------------------------------------------------------

      # Open the current actor's battle-skill list (nothing to open if they know
      # no battle-usable skill).
      def open_battle_skill
        actor = current_actor_row
        list = actor ? @state.party.battle_skills(actor, current_actor) : []
        # A status that seals skills (封印 / Silence) takes them off the menu
        # rather than letting the actor pick one that would be refused.
        battle = @battle_ui[:battle]
        battler = current_actor
        if battle && battler
          list = list.reject do |sid, _cost|
            battle.skill_sealed?(battler, @state.party.db_skill(sid))
          end
        end
        @battle_ui[:skills] = list
        return if @battle_ui[:skills].empty?
        @battle_ui[:skill_i] = 0
        @battle_ui[:phase] = :skill
        draw_battle_skill
      end

      def drive_battle_skill
        skills = @battle_ui[:skills]
        if Input.trigger?(Input::DOWN) && @battle_ui[:skill_i] < skills.length - 1
          @battle_ui[:skill_i] += 1
          draw_battle_skill
        elsif Input.trigger?(Input::UP) && @battle_ui[:skill_i] > 0
          @battle_ui[:skill_i] -= 1
          draw_battle_skill
        elsif Input.trigger?(Input::C)
          confirm_battle_skill
        elsif Input.trigger?(Input::B)
          close_battle_skill
          @battle_ui[:phase] = :command
          draw_battle_command
        end
      end

      # Choose the highlighted skill: if the caster cannot afford its SP, ignore
      # the press; otherwise route to enemy / ally target selection (or cast at
      # once on a self-scope skill).
      def confirm_battle_skill
        sid, cost = @battle_ui[:skills][@battle_ui[:skill_i]]
        return if current_actor.mp < cost # can't afford: stay on the list
        sk = @state.party.db_skill(sid)
        @battle_ui[:pending] = { kind: :skill, sk: sk, sid: sid }
        close_battle_skill
        case @state.party.battle_skill_target(sk)
        when :self
          apply_pending_skill(current_actor)
        when :enemy
          @battle_ui[:target_i] = 0
          @battle_ui[:phase] = :target
          draw_battle_target
        when :all_enemy
          apply_pending_skill_all(living_foes)
        when :all_ally
          apply_pending_skill_all(living_allies)
        else # :ally
          @battle_ui[:ally_i] = 0
          @battle_ui[:phase] = :ally_target
          draw_battle_ally_target
        end
      end

      # Commit the pending skill on `target` (SP cost / effect from the model),
      # then move to the next actor.
      def apply_pending_skill(target)
        sk = @battle_ui[:pending][:sk]
        sid = @battle_ui[:pending][:sid]
        c = @state.party.battle_skill_command(sk, current_actor, target)
        @battle_ui[:battle].command_skill(current_actor, target,
                                          name: sk.name, skill_id: sid,
                                          absorb: c[:absorb] ? true : false,
                                          cost: c[:cost],
                                          hp: c[:hp], mp: c[:mp],
                                          inflict: c[:inflict], chance: c[:chance],
                                          variance: c[:variance] || 0,
                                          attributes: c[:attributes])
        @battle_ui[:pending] = nil
        @battle_ui[:phase] = :command
        advance_actor
      end

      # Commit the pending all-target skill on every `targets` combatant (all
      # living enemies for an attack skill, all living allies for a heal): build
      # one per-target effect from the model (attack damage varies with each
      # target's defence) and queue them as a single volley. The shared SP cost /
      # infliction ride along once.
      def apply_pending_skill_all(targets)
        sk = @battle_ui[:pending][:sk]
        sid = @battle_ui[:pending][:sid]
        meta = @state.party.battle_skill_command(sk, current_actor, targets.first)
        effects = targets.map do |t|
          c = @state.party.battle_skill_command(sk, current_actor, t)
          { target: t, hp: c[:hp], mp: c[:mp] }
        end
        @battle_ui[:battle].command_skill_all(current_actor, effects,
                                              name: sk.name, skill_id: sid,
                                              absorb: meta[:absorb] ? true : false,
                                              cost: meta[:cost],
                                              inflict: meta[:inflict], chance: meta[:chance],
                                              variance: meta[:variance] || 0,
                                              attributes: meta[:attributes])
        @battle_ui[:pending] = nil
        @battle_ui[:phase] = :command
        advance_actor
      end

      # -- Item sub-menu -------------------------------------------------------

      # Open the party's battle-usable items (nothing to open if the bag holds
      # none).
      def open_battle_item
        @battle_ui[:items] = @state.party.battle_items
        return if @battle_ui[:items].empty?
        @battle_ui[:item_i] = 0
        @battle_ui[:phase] = :item
        draw_battle_item
      end

      def drive_battle_item
        items = @battle_ui[:items]
        if Input.trigger?(Input::DOWN) && @battle_ui[:item_i] < items.length - 1
          @battle_ui[:item_i] += 1
          draw_battle_item
        elsif Input.trigger?(Input::UP) && @battle_ui[:item_i] > 0
          @battle_ui[:item_i] -= 1
          draw_battle_item
        elsif Input.trigger?(Input::C)
          item_id, _count = @battle_ui[:items][@battle_ui[:item_i]]
          it = @state.party.db_item(item_id)
          @battle_ui[:pending] = { kind: :item, item_id: item_id, it: it }
          close_battle_item
          if @state.party.item_all_allies?(it)
            apply_pending_item_all(living_allies)
          else
            @battle_ui[:ally_i] = 0
            @battle_ui[:phase] = :ally_target
            draw_battle_ally_target
          end
        elsif Input.trigger?(Input::B)
          close_battle_item
          @battle_ui[:phase] = :command
          draw_battle_command
        end
      end

      # -- Ally target (heal skill / medicine) --------------------------------

      def drive_battle_ally_target
        allies = living_allies
        if Input.trigger?(Input::DOWN) && @battle_ui[:ally_i] < allies.length - 1
          @battle_ui[:ally_i] += 1
          draw_battle_ally_target
        elsif Input.trigger?(Input::UP) && @battle_ui[:ally_i] > 0
          @battle_ui[:ally_i] -= 1
          draw_battle_ally_target
        elsif Input.trigger?(Input::C)
          target = allies[@battle_ui[:ally_i]]
          close_battle_ally_target
          if pending_kind == :skill
            apply_pending_skill(target)
          else
            apply_pending_item(target)
          end
        elsif Input.trigger?(Input::B)
          close_battle_ally_target
          if pending_kind == :skill
            @battle_ui[:phase] = :skill
            draw_battle_skill
          else
            @battle_ui[:phase] = :item
            draw_battle_item
          end
        end
      end

      # Commit the pending item on `target` (recovery from the model; the bag is
      # consumed later, when the action lands), then move to the next actor.
      def apply_pending_item(target)
        pending = @battle_ui[:pending]
        c = @state.party.battle_item_command(pending[:it], target)
        @battle_ui[:battle].command_item(current_actor, target,
                                         item_id: pending[:item_id],
                                         name: pending[:it].name,
                                         hp: c[:hp], mp: c[:mp], cured: c[:cured])
        @battle_ui[:pending] = nil
        @battle_ui[:phase] = :command
        advance_actor
      end

      # Commit an all-party item on every living ally: one per-member recovery
      # from the model, queued as a single volley that consumes one item.
      def apply_pending_item_all(targets)
        pending = @battle_ui[:pending]
        effects = targets.map do |t|
          c = @state.party.battle_item_command(pending[:it], t)
          { target: t, hp: c[:hp], mp: c[:mp] }
        end
        cured = @state.party.battle_item_command(pending[:it], targets.first)[:cured]
        @battle_ui[:battle].command_item_all(current_actor, effects,
                                             item_id: pending[:item_id],
                                             name: pending[:it].name, cured: cured)
        @battle_ui[:pending] = nil
        @battle_ui[:phase] = :command
        advance_actor
      end

      # Move to the next living party member, or start playing out the round once
      # every member has a command.
      def advance_actor
        @battle_ui[:actor_i] += 1
        @battle_ui[:cmd] = 0
        if @battle_ui[:actor_i] >= living_allies.length
          start_round_animation
        else
          draw_battle_command
        end
      end

      # Frames each attack of the round lingers on screen before the next lands —
      # a beat long enough to read the hit and see the HP tick, at ~1/3s / 60fps.
      BATTLE_ANIM_FRAMES = 20

      # Begin animating the commanded round: dismiss the command menu and prime
      # the battle's per-action queue. From here #drive_battle_animate lands one
      # attack per BATTLE_ANIM_FRAMES until the round's queue empties.
      def start_round_animation
        if @battle_ui[:cmd_win]
          @battle_ui[:cmd_win].dispose
          @battle_ui[:cmd_win] = nil
        end
        @battle_ui[:battle].begin_round
        @battle_ui[:phase] = :animate
        @battle_ui[:anim_timer] = 0 # land the first attack next frame
      end

      # One attack per BATTLE_ANIM_FRAMES: land the next action (mutating a single
      # battler's HP), tick the HP display, and banner the hit. When the round's
      # queue empties, settle it and either show the result or re-open commands —
      # so the round plays out action by action rather than all at once.
      def drive_battle_animate
        # A skill or item that names a battle animation plays it over the target
        # before the round moves on, so the round is paced by the animation
        # rather than by the fixed banner timer.
        if battle_animation_playing?
          step_map_animation
          return
        end
        if @battle_ui[:anim_timer] > 0
          @battle_ui[:anim_timer] -= 1
          return
        end
        entry = @battle_ui[:battle].step_action
        if entry
          # An Item action consumes one from the real bag when it lands (so
          # backing out during the command phase never spends it).
          @state.party.lose_item(entry[:item_id], 1) if entry[:item_id]
          log_round([entry])
          refresh_battle_status
          refresh_battle_sprites
          show_battle_action(entry)
          # When an animation plays, it is the wait; otherwise the banner timer
          # is, exactly as before.
          @battle_ui[:anim_timer] =
            start_battle_animation(entry) ? 0 : BATTLE_ANIM_FRAMES
        else
          finish_round_animation
        end
      end

      def battle_animation_playing?
        !@map_animation.nil? && @map_animation[:battle]
      end

      # Play the animation this action names, over its target. RPG2000 keeps the
      # animation on the **skill** and on the **item**, not on the action -- 557
      # skill rows and 170 item rows across the test beds name one, and none of
      # them played. Returns true when one started.
      #
      # A plain attack's animation is the equipped weapon's, which the log entry
      # does not carry, so it is left for a change that plumbs the weapon
      # through rather than guessed at here.
      def start_battle_animation(entry)
        id = battle_animation_id(entry)
        return false unless id && id > 0
        tx, ty = battle_animation_pixel(entry)
        anim = build_animation(id, tx, ty, true)
        return false unless anim
        @map_animation = anim
        fire_animation_flashes(anim) # frame 0 flashes, as the map path does
        true
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle animation failed: #{e.message}"
        false
      end

      def battle_animation_id(entry)
        row =
          if entry[:skill_id] && db.respond_to?(:skill) && db.skill
            db.skill[entry[:skill_id]]
          elsif entry[:item_id] && db.respond_to?(:item) && db.item
            db.item[entry[:item_id]]
          end
        row && row.respond_to?(:animation_id) ? row.animation_id : nil
      end

      # Where it plays: over the targeted enemy's sprite. RPG2000 draws no sprite
      # for a party member -- its battle is first-person -- so an action aimed at
      # one plays over the middle of the screen instead of nowhere.
      def battle_animation_pixel(entry)
        i = entry[:target_index]
        sprites = @battle_ui[:enemy_sprites]
        spr = i && sprites ? sprites[i] : nil
        bmp = spr && spr.bitmap
        return [SCREEN_W / 2, SCREEN_H / 2] unless bmp
        [spr.x + bmp.width / 2, spr.y + bmp.height / 2]
      end

      # Close out an animated round: clear the commands, drop the action banner,
      # and branch to the result window or the next command phase.
      def finish_round_animation
        battle = @battle_ui[:battle]
        battle.end_round
        close_battle_action
        if battle.finished?
          enter_battle_result(battle.result)
        else
          @battle_ui[:actor_i] = 0
          @battle_ui[:cmd] = 0
          @battle_ui[:phase] = :command
          # A new turn re-arms every page: RPG2000 fires a battle page once per
          # turn in which its condition holds, not once per battle.
          @battle_ui[:pages_run] = {}
          draw_battle_command unless run_battle_events
        end
      end

      # -- battle-event pages --------------------------------------------------

      # Start the next troop battle-event page whose condition holds and that has
      # not yet fired this turn, switching to the :event phase. Returns whether a
      # page was started, so the caller knows whether to draw the command window
      # or hand the frame to the event. A troop that scripts nothing, or whose
      # pages have all fired, simply returns false.
      def run_battle_events
        ui = @battle_ui
        return false unless ui && ui[:troop].pages
        matched = Game::BattlePage.select_all(ui[:troop].pages, @state.switches,
                                              @state.variables, ui[:battle])
        entry = matched.find { |(id, _)| !ui[:pages_run][id] }
        return false unless entry
        ui[:pages_run][entry[0]] = true
        cmds = entry[1].event
        return run_battle_events if cmds.nil? || cmds.empty? # empty page: try the next
        ui[:events].battle = ui[:battle]
        ui[:events].start(cmds)
        ui[:phase] = :event
        true
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle event page failed: #{e.message}"
        false
      end

      # Advance the running battle-event page one frame. Battle pages use the
      # ordinary command set (messages, switches, variables, audio) on top of the
      # battle-only commands, so the interpreter is driven the same way the map
      # drives an event — only the UI it may reach for is narrower.
      def drive_battle_event
        it = @battle_ui[:events]
        apply_battle_event_requests(it)
        return if finish_terminated_battle
        if it.waiting?
          drive_battle_event_wait(it)
        elsif it.running?
          it.update
        else
          leave_battle_event_phase
        end
      end

      def drive_battle_event_wait(it)
        case it.wait_kind
        when :message, :choice then drive_battle_event_message(it)
        when :wait
          @battle_ui[:event_timer] ||= frames_from_tenths(it.wait_frames)
          if @battle_ui[:event_timer] <= 0
            @battle_ui[:event_timer] = nil
            it.resume
          else
            @battle_ui[:event_timer] -= 1
          end
        else
          # A battle page cannot open the map's teleport / shop / menu UI; those
          # requests are released so the page runs on rather than wedging here.
          it.resume
        end
      end

      # Show the page's message lines in a battle text panel and dismiss it on a
      # button press. A [Show Choices] in a battle page is displayed the same way
      # and takes the first option, which is what the runtime can answer without
      # a battle choice widget.
      def drive_battle_event_message(it)
        unless @battle_ui[:event_win]
          lines = it.wait_kind == :choice ? it.choice_labels : it.message_lines
          @battle_ui[:event_win] =
            battle_text_window(lines || [], BATTLE_EVENT_MSG_Y, 340)
          return # shown this frame; take the button from the next one
        end
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        choice = it.wait_kind == :choice
        close_battle_event_window
        choice ? it.choose(0) : it.resume
      end

      def close_battle_event_window
        return unless @battle_ui && @battle_ui[:event_win]
        @battle_ui[:event_win].dispose
        @battle_ui[:event_win] = nil
      end

      # Apply the requests a battle page queued: revealed troop members get the
      # sprite they never had, and a Change Battle Background rebuilds the
      # backdrop.
      #
      # The status panel is rebuilt unconditionally afterwards. A battle page's
      # Change Monster HP / MP / Condition commands write straight to the live
      # combatants rather than queueing a request, so nothing here would have
      # told the panel it is stale — a page that poisoned the boss changed the
      # fight but not the screen until the next action happened to redraw it.
      def apply_battle_event_requests(it)
        it.take_revealed_monsters.each { |i| reveal_battle_monster(i) }
        fled = it.take_fled_monsters
        fled.each { |i| remove_fled_monster(i) }
        play_escape_se unless fled.empty?
        name = it.take_battle_background
        rebuild_battle_back(name) unless name.nil?
        refresh_battle_status
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle event request failed: #{e.message}"
        nil
      end

      # Show Hidden Monster: clear the member's hidden flag and build the sprite
      # build_battle_sprites skipped, so it appears mid-fight.
      def reveal_battle_monster(index)
        member = @battle_ui[:troop].members[index]
        return unless member && member.hidden
        member.hidden = false
        # Bring the combatant into the fight as well, not just the sprite: until
        # now it took no turn and could not be targeted (Combatant#out_of_play?).
        foe = @battle_ui[:battle].enemy(index)
        foe.hidden = false if foe
        bmp = battler_bitmap(member)
        spr = Sprite.new
        spr.bitmap = bmp
        spr.x = member.x - bmp.width / 2
        spr.y = member.y - bmp.height / 2
        spr.z = 100 + index
        dispose_battle_sprite(@battle_ui[:enemy_sprites][index])
        @battle_ui[:enemy_sprites][index] = spr
      end

      # Force Flee: the troop member ran, so drop its sprite. Game::Battle has
      # already hidden the combatant (which takes it out of play without counting
      # as a kill), and the troop member's own flag is set so a later rebuild does
      # not draw it again.
      def remove_fled_monster(index)
        member = @battle_ui[:troop].members[index]
        member.hidden = true if member
        dispose_battle_sprite(@battle_ui[:enemy_sprites][index])
        @battle_ui[:enemy_sprites][index] = nil
      end

      # The escape sound RPG_RT plays when a Force Flee sends enemies running.
      def play_escape_se
        play_system_se(SFX_ESCAPE)
      end

      # Terminate Battle: leave the fight with no victory / defeat processing.
      # Returns whether the battle was ended, so the caller stops driving it.
      def finish_terminated_battle
        return false unless @battle_ui[:battle].terminated?
        close_battle_event_window
        finish_battle(:abort)
        true
      end

      # The running page finished: fire the next matching page, or hand the turn
      # back — to the result window when the page decided the fight, otherwise to
      # the party's command phase.
      def leave_battle_event_phase
        close_battle_event_window
        return if run_battle_events
        battle = @battle_ui[:battle]
        if battle.finished?
          enter_battle_result(battle.result)
        else
          @battle_ui[:phase] = :command
          draw_battle_command
        end
      end

      def enter_battle_result(result)
        @battle_ui[:result] = result
        lines = battle_result_lines(result, @battle_ui[:troop])
        [@battle_ui[:status_win], @battle_ui[:cmd_win]].each { |w| w.dispose if w }
        @battle_ui[:status_win] = nil
        @battle_ui[:cmd_win] = nil
        open_battle_result(lines)
        @battle_ui[:phase] = :result
      end

      def drive_battle_result
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        finish_battle(@battle_ui[:result])
      end

      # Close the battle and hand the outcome back to the event. A defeat in an
      # encounter whose defeat mode is "game over" (rather than a [Defeat]
      # handler) ends the game instead of resuming the event; every other outcome
      # — victory, escape, or a defeat with a custom handler — resumes it.
      def finish_battle(result)
        # Persist the party's post-battle HP (and any knock-outs) before leaving
        # the fight, so damage taken sticks and a downed member stays down.
        @battle_ui[:battle].apply_to_party
        # A defeat in "game over" mode (no custom [Defeat] handler) with the whole
        # party knocked out ends the game; every other outcome resumes the event.
        game_over = result == :defeat && @battle_ui[:req][:defeat_game_over] &&
                    @state.party.all_dead?
        close_battle
        if game_over
          perform_game_over
        else
          @interpreter.resume_battle(result)
        end
      end

      # Game over: the party was wiped in an encounter that ends the game on
      # defeat (also the target of the Game Over event command). Stop the event
      # and return to the title screen — the faithful end state. (RPG2000 shows a
      # Game Over graphic first; that screen is native renderer work still to come.)
      # Game Over (12420), and a battle defeat the encounter marked "game over":
      # show the Game Over screen, which returns to the title once dismissed.
      # Nothing resumes, so the event is stopped rather than released.
      def perform_game_over
        $stderr.puts '[RPG2k] game over'
        @interpreter.stop
        @parent.show_game_over
      rescue StandardError => e
        $stderr.puts "[RPG2k] Game over failed: #{e.message}"
        @interpreter.stop
      end

      def log_round(entries)
        entries.each do |e|
          battle_action_lines(e).each { |l| $stderr.puts "[RPG2k battle] #{l}" }
        end
      end

      # What an action says, in the game's own words. RPG2000 keeps the sentences
      # in the 用語 table as *predicates* — 「の攻撃！」, 「のダメージを与えた！」 —
      # and RPG_RT prints the battler's name in front of each. Both test beds
      # fill 126 of the 127 fields in, so a log that invents its own English is
      # ignoring text the author wrote.
      #
      # RPG_RT says it in more than one line: what the battler did, then what it
      # did to the target. This returns them in that order, and falls back to the
      # composed English for any field the database leaves blank — an
      # English-release table with half the battle terms empty still reads.
      def battle_action_body(e)
        # An item announces itself with the `use_item` term, still unread, and
        # "does nothing" is worded by the state that caused it rather than by a
        # term — both keep the composed wording. A skill has its own two
        # sentences and takes the branch below.
        return [battle_action_line(e)] if e[:nothing]
        return battle_skill_body(e) if e[:skill_id]
        return battle_item_body(e) if e[:item_id]
        return [battle_action_line(e)] if e[:recover] || e[:skill]
        t = db.respond_to?(:term) ? db.term : nil
        want_start = battle_start_field(e)
        want_result = battle_result_wanted?(e)
        start = want_start && battle_start_line(t, e, want_start)
        result = want_result && battle_result_line(t, e)
        # All or nothing per entry: a half-translated line ("スライムの攻撃！"
        # with no damage sentence under it) reads worse than the composed
        # English, so a blank term drops the whole entry back to the fallback.
        return [battle_action_line(e)] if (want_start && !start) ||
                                          (want_result && !result)
        lines = []
        lines << start if start
        lines << result if result
        lines.empty? ? [battle_action_line(e)] : lines
      end

      # A skill's own two sentences, then what it did. `using_message1` follows
      # the caster's name and `using_message2` stands alone as a second line, so
      # a spell reads 「リトは炎を放った！」 / 「あたりが真っ赤に染まる！」 before
      # 「スライムに 42 のダメージを与えた！」.
      #
      # A skill that achieved nothing takes its own failure sentence instead of a
      # damage line — the skill row's `failure_message` picks which of the three
      # 用語 failure lines (or the dodge line) says so.
      #
      # A skill row that sets no sentence at all keeps the composed wording, for
      # the same reason a blank term does: the bare damage line would lose the
      # only thing naming what was cast.
      def battle_skill_body(e)
        bt = Game::States::BattleText
        row = db.respond_to?(:skill) && db.skill ? db.skill[e[:skill_id]] : nil
        caster = (e[:recover] ? e[:actor] : e[:attacker]).to_s
        lines = bt.skill_start(row, caster)
        return [battle_action_line(e)] if lines.empty?
        t = db.respond_to?(:term) ? db.term : nil
        rest = battle_skill_result(t, row, e)
        return [battle_action_line(e)] unless rest
        lines + rest
      rescue StandardError => ex
        $stderr.puts "[RPG2k] skill message lookup failed: #{ex.message}"
        [battle_action_line(e)]
      end

      # What the skill did: the damage / dodge line for an attack, nothing extra
      # for a recovery that worked, and the failure sentence for one that did
      # not. nil when a needed sentence is missing, so the caller falls back
      # whole rather than printing half of one.
      def battle_skill_result(t, row, e)
        bt = Game::States::BattleText
        return [] if e[:target].nil?
        if skill_achieved_nothing?(e)
          line = bt.skill_failure(t, row, e[:target].to_s)
          return line ? [line] : nil
        end
        return battle_recovery_lines(t, e) if e[:recover]
        line = battle_result_line(t, e)
        return nil unless line
        [line] + battle_absorb_lines(t, e)
      end

      # What a 吸収 skill took from its target, after the damage line. [] when
      # the skill drained nothing or the database has no wording -- unlike the
      # damage line this one is additive, so a missing term drops the extra
      # sentence rather than the whole entry.
      def battle_absorb_lines(t, e)
        amount = e[:absorbed_hp] || 0
        return [] unless amount > 0
        line = Game::States::BattleText.absorbed(
          t, e[:target].to_s, amount, :hp, e[:target_ally] ? true : false
        )
        line ? [line] : []
      end

      # An item borrows the `use_item` term rather than carrying a sentence of
      # its own -- 「リトはポーションを使った！」 is the only line RPG2000 builds
      # from two names -- and then says what it restored.
      def battle_item_body(e)
        bt = Game::States::BattleText
        t = db.respond_to?(:term) ? db.term : nil
        start = bt.item_start(t, e[:actor].to_s, e[:source].to_s)
        return [battle_action_line(e)] unless start
        rest =
          if skill_achieved_nothing?(e)
            # An item that did nothing has no `failure_message` to choose with,
            # so RPG2000 has no sentence for it: the composed line still says
            # more than the bare "used it" would.
            nil
          else
            battle_recovery_lines(t, e)
          end
        return [battle_action_line(e)] unless rest
        [start] + rest
      rescue StandardError => ex
        $stderr.puts "[RPG2k] item message lookup failed: #{ex.message}"
        [battle_action_line(e)]
      end

      # What a heal restored: one line per pool it filled, in the game's own
      # words (「リトのＨＰが 30 回復した！」). [] when it restored nothing but
      # cured something -- the state sentences carry that -- and nil when the
      # database has no wording, so the caller falls back whole.
      def battle_recovery_lines(t, e)
        bt = Game::States::BattleText
        name = e[:target].to_s
        lines = []
        [[:hp, e[:recover_hp]], [:mp, e[:recover_mp]]].each do |pool, amount|
          next unless amount && amount > 0
          line = bt.recovered(t, name, amount, pool)
          return nil unless line
          lines << line
        end
        lines
      end

      # A skill with nothing to show for itself: a heal that restored no HP or SP
      # and cured nothing, or an attack that was dodged.
      def skill_achieved_nothing?(e)
        return true if e[:missed]
        return false unless e[:recover]
        (e[:recover_hp] || 0) <= 0 && (e[:recover_mp] || 0) <= 0 &&
          (e[:cured] || []).empty? && (e[:inflicted] || []).empty?
      end

      # Which term words this entry's "so-and-so did a thing" line, or nil when
      # RPG2000 has none for it — a skill or an item names itself instead (its
      # own `using_message` is a separate field, still unread), and "does
      # nothing" is a state's own sentence rather than a term.
      def battle_start_field(e)
        return nil if e[:recover] || e[:skill] || e[:nothing]
        return :enemy_transform if e[:transform]
        return :defending if e[:defend]
        return :observing if e[:observe]
        return :focus if e[:charge]
        return :enemy_escape if e[:fled]
        return :autodestruction if e[:autodestruct]
        :attacking
      end

      def battle_start_line(t, e, field)
        Game::States::BattleText.action(t, e[:attacker].to_s, field)
      end

      # Does this entry report on a target at all? A Defend, a flee or an
      # autodestruct that found nobody has no one to report on.
      def battle_result_wanted?(e)
        return false if e[:recover] || e[:target].nil?
        e[:missed] || !e[:damage].nil? ? true : false
      end

      # What it did to that target: a miss, a blow that got through for nothing,
      # or the damage.
      def battle_result_line(t, e)
        bt = Game::States::BattleText
        name = e[:target].to_s
        ally = e[:target_ally] ? true : false
        return bt.dodge(t, name) if e[:missed]
        return bt.damage(t, name, e[:damage], ally) if e[:damage] > 0
        bt.undamaged(t, name, ally)
      end

      # A one-line description of a battle log entry, for the on-screen banner and
      # the console trace. A recovery (heal skill / medicine) reads as a restore;
      # a skill attack names the skill; a plain attack is "A hits B for N".
      #
      # This is the fallback now: it words an entry whose terms the database left
      # blank. `battle_action_body` prefers the game's own sentences.
      def battle_action_line(e)
        if e[:recover]
          parts = []
          parts << "#{e[:recover_hp]} HP" if e[:recover_hp] && e[:recover_hp] > 0
          parts << "#{e[:recover_mp]} MP" if e[:recover_mp] && e[:recover_mp] > 0
          body = parts.empty? ? 'no effect' : "+#{parts.join(' / ')}"
          "#{e[:actor]}'s #{e[:source]}: #{e[:target]} #{body}"
        elsif e[:missed]
          "#{e[:attacker]} misses #{e[:target]}"
        elsif e[:transform]
          "#{e[:attacker]} transforms!"
        elsif e[:defend]
          "#{e[:attacker]} defends"
        elsif e[:observe]
          "#{e[:attacker]} watches closely"
        elsif e[:charge]
          "#{e[:attacker]} gathers strength"
        elsif e[:fled]
          "#{e[:attacker]} flees!"
        elsif e[:nothing]
          "#{e[:attacker]} does nothing"
        else
          hits = if e[:autodestruct] then ' blows itself up on'
                 elsif e[:skill] then "'s #{e[:skill]} hits"
                 else ' hits'
                 end
          line = "#{e[:attacker]}#{hits} #{e[:target]} for #{e[:damage]}"
          line += ' (critical!)' if e[:critical]
          line += ' (charged)' if e[:charged]
          line
        end
      end

      # Everything the action announces: what it did, then the conditions it
      # changed. `log_round` traces all of it and `show_battle_action` banners
      # all of it, so the console and the screen never disagree.
      def battle_action_lines(entry)
        battle_action_body(entry) + battle_state_lines(entry)
      end

      # The result window's text: the outcome, and on a win the EXP / gold gained
      # (granted here). RPG2000 shows this after the fight before returning to the
      # map.
      def battle_result_lines(result, troop)
        return ['The party was defeated...'] unless result == :victory
        exp = troop.total_exp
        gold = troop.total_gold
        @state.party.actors.each { |a| a.gain_exp(exp) }
        @state.party.gain_gold(gold)
        lines = ['Victory!']
        lines << "Gained #{exp} EXP." if exp > 0
        lines << "Found #{gold} gold." if gold > 0
        # Each defeated enemy may drop its treasure item (rolled on the battle's
        # own RNG); grant it to the bag and name it in the result window.
        troop.drops(@battle_ui[:battle].rng).each do |iid|
          @state.party.gain_item(iid, 1)
          it = @state.party.db_item(iid)
          lines << "Found #{it ? it.name : "item #{iid}"}."
        end
        lines
      end

      BATTLE_LINE_H = 14

      # Column origins within the status panel's contents, in the order RPG_RT's
      # battle status window uses them: who, what condition they are in, then the
      # gauges. The condition column is why this window is laid out in columns at
      # all — a state is drawn in its *own* palette colour, which a single
      # `draw_text` of a whole line cannot do.
      STATUS_NAME_X  = 0
      STATUS_STATE_X = 84
      STATUS_HP_X    = 156
      STATUS_MP_X    = 220

      # Rebuild the status panel near the top: the enemy troop, then each party
      # member with their HP and SP. Every battler also shows the one condition
      # RPG_RT shows — the significant state, or the database's "normal" term
      # when there is none — so a status inflicted by a skill or by a battle
      # page's Change Monster Condition is visible rather than only simulated.
      def refresh_battle_status
        @battle_ui[:status_win].dispose if @battle_ui[:status_win]
        rows = @battle_ui[:foes].map { |e| battle_status_row(e, false) }
        rows += @battle_ui[:allies].map { |a| battle_status_row(a, true) }
        @battle_ui[:status_win] = battle_status_window(rows, 6, 300)
      end

      # One battler's row as [text, x, colour index] segments. Enemies have no
      # gauges on an RPG2000 battle screen, so they stop after their condition.
      def battle_status_row(b, ally)
        state = battle_state_segment(b)
        row = [[b.name, STATUS_NAME_X, 0], state]
        return row unless ally
        hp = b.hp < 0 ? 0 : b.hp
        row + [["HP #{hp}/#{b.max_hp}", STATUS_HP_X, 0],
               ["MP #{b.mp}/#{b.max_mp}", STATUS_MP_X, 0]]
      end

      # The condition column, as a status-panel segment: the same reading the
      # field windows draw (Scene::Base#state_display), placed in its column.
      def battle_state_segment(b)
        text, color = state_display(b.states)
        [text, STATUS_STATE_X, color]
      end

      # The current actor's command menu — their name as a header, then Attack /
      # Skill / Item / Defend with a cursor.
      def draw_battle_command
        actor = current_actor
        return unless actor
        @battle_ui[:cmd_win].dispose if @battle_ui[:cmd_win]
        labels = [actor.name] + BATTLE_COMMANDS
        w = 96
        inner_h = labels.length * BATTLE_LINE_H
        win = Window.new(10, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         w, inner_h + Window::BORDER * 2)
        win.z = 320
        win.windowskin = @windowskin
        c = Bitmap.new(w - Window::BORDER * 2, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |label, i|
          c.draw_text 0, i * BATTLE_LINE_H, c.width, BATTLE_LINE_H, label
        end
        win.contents = c
        # The cursor sits over the commands (rows 1..N, below the name header).
        win.cursor_rect =
          Rect.new(0, (1 + @battle_ui[:cmd]) * BATTLE_LINE_H, c.width, BATTLE_LINE_H)
        @battle_ui[:cmd_win] = win
      end

      # The target-selection menu — the living enemies, with a cursor.
      def draw_battle_target
        foes = living_foes
        @battle_ui[:target_win].dispose if @battle_ui[:target_win]
        w = 120
        inner_h = [foes.length, 1].max * BATTLE_LINE_H
        win = Window.new(SCREEN_W - w - 10, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         w, inner_h + Window::BORDER * 2)
        win.z = 330
        win.windowskin = @windowskin
        c = Bitmap.new(w - Window::BORDER * 2, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        foes.each_with_index do |e, i|
          c.draw_text 0, i * BATTLE_LINE_H, c.width, BATTLE_LINE_H, e.name
        end
        win.contents = c
        unless foes.empty?
          win.cursor_rect =
            Rect.new(0, @battle_ui[:target_i] * BATTLE_LINE_H, c.width, BATTLE_LINE_H)
        end
        @battle_ui[:target_win] = win
      end

      def close_battle_target
        return unless @battle_ui[:target_win]
        @battle_ui[:target_win].dispose
        @battle_ui[:target_win] = nil
      end

      # A bottom-anchored list window of `labels` with the cursor on `sel`, at
      # left edge `x` and width `w` — the shared shape of the Skill / Item and
      # ally-target menus.
      def battle_list_window(x, w, labels, sel, z)
        inner_h = [labels.length, 1].max * BATTLE_LINE_H
        win = Window.new(x, SCREEN_H - inner_h - Window::BORDER * 2 - 6,
                         w, inner_h + Window::BORDER * 2)
        win.z = z
        win.windowskin = @windowskin
        c = Bitmap.new(w - Window::BORDER * 2, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |label, i|
          c.draw_text 0, i * BATTLE_LINE_H, c.width, BATTLE_LINE_H, label
        end
        win.contents = c
        unless labels.empty?
          win.cursor_rect = Rect.new(0, sel * BATTLE_LINE_H, c.width, BATTLE_LINE_H)
        end
        win
      end

      # The current actor's battle skills as "Name  cost", with a cursor.
      def draw_battle_skill
        @battle_ui[:skill_win].dispose if @battle_ui[:skill_win]
        labels = @battle_ui[:skills].map do |sid, cost|
          sk = @state.party.db_skill(sid)
          "#{sk ? sk.name : "Skill #{sid}"}  #{cost}"
        end
        @battle_ui[:skill_win] = battle_list_window(10, 130, labels, @battle_ui[:skill_i], 325)
      end

      def close_battle_skill
        return unless @battle_ui[:skill_win]
        @battle_ui[:skill_win].dispose
        @battle_ui[:skill_win] = nil
      end

      # The party's battle items as "Name  xN", with a cursor.
      def draw_battle_item
        @battle_ui[:item_win].dispose if @battle_ui[:item_win]
        labels = @battle_ui[:items].map do |id, count|
          it = @state.party.db_item(id)
          "#{it ? it.name : "Item #{id}"}  x#{count}"
        end
        @battle_ui[:item_win] = battle_list_window(10, 130, labels, @battle_ui[:item_i], 325)
      end

      def close_battle_item
        return unless @battle_ui[:item_win]
        @battle_ui[:item_win].dispose
        @battle_ui[:item_win] = nil
      end

      # The living party members as heal targets ("Name HP h/mh"), with a cursor.
      def draw_battle_ally_target
        @battle_ui[:ally_win].dispose if @battle_ui[:ally_win]
        labels = living_allies.map do |a|
          "#{a.name}  #{a.hp < 0 ? 0 : a.hp}/#{a.max_hp}"
        end
        @battle_ui[:ally_win] =
          battle_list_window(SCREEN_W - 130 - 10, 130, labels, @battle_ui[:ally_i], 335)
      end

      def close_battle_ally_target
        return unless @battle_ui[:ally_win]
        @battle_ui[:ally_win].dispose
        @battle_ui[:ally_win] = nil
      end

      # Banner the attack that just landed ("Hero hits Slime for 12", "…
      # defeated!") low on the screen while the round animates, so each action
      # reads on screen as well as its HP tick. Replaced by the next action's
      # banner and dropped when the round settles.
      def show_battle_action(entry)
        @battle_ui[:action_win].dispose if @battle_ui[:action_win]
        lines = battle_action_lines(entry)
        y = SCREEN_H - lines.length * BATTLE_LINE_H - Window::BORDER * 2 - 6
        @battle_ui[:action_win] = battle_text_window(lines, y, 340)
      end

      # The conditions the action just landed or lifted, one sentence each under
      # the action's own line — RPG_RT announces every one of them, and until now
      # a skill that poisoned its target said only how much damage it did.
      #
      # The sentences come from the state row itself (`message_actor` /
      # `message_enemy` for one landing, `message_recovery` for one lifting),
      # which is where the game's own wording lives. An English-release database
      # leaves them blank, so a plain composition stands in.
      def battle_state_lines(entry)
        table = db.respond_to?(:situation) ? db.situation : nil
        name = entry[:target].to_s
        ally = entry[:target_ally] ? true : false
        lines = []
        (entry[:inflicted] || []).each do |id|
          lines << (Game::States.inflict_message(id, table, name, ally) ||
                    "#{name} is #{state_label(id, table)}")
        end
        # A state the target already carried when the skill tried to inflict it
        # again. RPG_RT announces it rather than going quiet, in the state's own
        # words ("はすでに毒に冒されている！"), and reports it as a *success*.
        (entry[:already] || []).each do |id|
          lines << (Game::States.already_message(id, table, name) ||
                    "#{name} is already #{state_label(id, table)}")
        end
        # `cured` is a medicine or a cure skill lifting a state; `woke` is a blow
        # shaking one off (a state's `release_by_attack`). Both are the state
        # lifting, which has one wording whichever side it happened to.
        ((entry[:cured] || []) + (entry[:woke] || [])).each do |id|
          lines << (Game::States.recovery_message(id, table, name) ||
                    "#{name} recovers from #{state_label(id, table)}")
        end
        # Being downed is state 1 landing, and RPG_RT announces it with that
        # state's own sentence — which is worded from the *speaker's* side, so a
        # Japanese game says "ゼロは倒れた！" of a party member and "スライムを
        # 倒した！" of an enemy. The simulation reports it as a flag on the hit
        # rather than through `inflicted`, so it is read from there.
        if entry[:defeated]
          lines << (Game::States.inflict_message(Game::States::DEATH_ID, table,
                                                 name, ally) ||
                    "#{name} is defeated!")
        end
        lines
      end

      def state_label(id, table)
        Game::States.name(id, table) || "state #{id}"
      end

      def close_battle_action
        return unless @battle_ui[:action_win]
        @battle_ui[:action_win].dispose
        @battle_ui[:action_win] = nil
      end

      def open_battle_result(lines)
        @battle_ui[:result_win] =
          battle_text_window(lines, SCREEN_H - lines.length * BATTLE_LINE_H -
                                    Window::BORDER * 2 - 6, 320)
      end

      # A full-width text panel of `lines` at vertical position `y` and depth `z`.
      def battle_text_window(lines, y, z)
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = [lines.length, 1].max * BATTLE_LINE_H
        win = Window.new(10, y, SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = z
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          c.draw_text 0, i * BATTLE_LINE_H, inner_w, BATTLE_LINE_H, line
        end
        win.contents = c
        win
      end

      # The same panel, but each row is a list of [text, x, colour index]
      # segments rather than one string, so a row can mix colours. Drawn through
      # `draw_system_text`, which fills the glyphs from the System graphic's own
      # palette swatch (and falls back to flat white text when the project ships
      # no windowskin) — the way RPG_RT colours a state name.
      def battle_status_window(rows, y, z)
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = [rows.length, 1].max * BATTLE_LINE_H
        win = Window.new(10, y, SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = z
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        rows.each_with_index do |segments, i|
          segments.each do |text, x, color|
            draw_system_text c, x, i * BATTLE_LINE_H, inner_w - x,
                             BATTLE_LINE_H, text.to_s, @windowskin, color
          end
        end
        win.contents = c
        win
      end

      def close_battle
        return unless @battle_ui
        [@battle_ui[:status_win], @battle_ui[:cmd_win],
         @battle_ui[:target_win], @battle_ui[:skill_win],
         @battle_ui[:item_win], @battle_ui[:ally_win],
         @battle_ui[:action_win], @battle_ui[:result_win],
         @battle_ui[:event_win]].each { |w| w.dispose if w }
        dispose_battle_sprite(@battle_ui[:back_sprite])
        (@battle_ui[:enemy_sprites] || []).each { |s| dispose_battle_sprite(s) }
        @battle_ui = nil
      end

      # Dispose a battle sprite and its bitmap (sprites do not own their bitmap,
      # so the graphic is freed explicitly).
      def dispose_battle_sprite(spr)
        return unless spr
        spr.bitmap.dispose if spr.bitmap
        spr.dispose
      end

      # -- Enter Hero Name (name-entry widget) --------------------------------

      # The selectable cells: the character set, then two control cells — BS
      # (backspace) and OK (confirm). RPG2000's own screen also offers hiragana /
      # katakana / symbol pages; this build enters the Latin letters, digits and a
      # few punctuation marks (the kana pages are a later refinement).
      NAME_CHARS = (('A'..'Z').to_a + ('a'..'z').to_a + ('0'..'9').to_a +
                    [' ', '-', "'", '.']).freeze
      NAME_CELLS = (NAME_CHARS + %w[BS OK]).freeze
      NAME_COLS = 13          # cells per row
      NAME_MAX = 12           # longest name the widget accepts
      NAME_CELL_W = 14
      NAME_CELL_H = 14

      # Drive the name-entry screen shown during a :name_input wait. It opens a
      # character grid (seeded with the actor's current name when the command asked
      # for it); arrows move the cursor, C types the highlighted character or acts
      # on BS / OK, and B backspaces. Confirming on OK commits the name to the
      # actor and resumes the event.
      def drive_name_input
        req = @interpreter.name_input_request
        return @interpreter.resume_name_input('') unless req
        if @name_ui.nil?
          @name_ui = { name: req[:seed] || '', sel: 0, win: nil }
          draw_name_input
          return
        end
        handle_name_input
      end

      def handle_name_input
        ui = @name_ui
        if Input.trigger?(Input::RIGHT) && ui[:sel] < NAME_CELLS.length - 1
          ui[:sel] += 1; draw_name_input
        elsif Input.trigger?(Input::LEFT) && ui[:sel] > 0
          ui[:sel] -= 1; draw_name_input
        elsif Input.trigger?(Input::DOWN) && ui[:sel] + NAME_COLS < NAME_CELLS.length
          ui[:sel] += NAME_COLS; draw_name_input
        elsif Input.trigger?(Input::UP) && ui[:sel] - NAME_COLS >= 0
          ui[:sel] -= NAME_COLS; draw_name_input
        elsif Input.trigger?(Input::C)
          name_input_confirm
        elsif Input.trigger?(Input::B)
          name_input_backspace
        end
      end

      # Act on the highlighted cell: OK commits, BS backspaces, any other cell
      # types its character (up to NAME_MAX).
      def name_input_confirm
        cell = NAME_CELLS[@name_ui[:sel]]
        case cell
        when 'OK' then commit_name_input
        when 'BS' then name_input_backspace
        else
          @name_ui[:name] += cell if @name_ui[:name].length < NAME_MAX
          draw_name_input
        end
      end

      def name_input_backspace
        @name_ui[:name] = @name_ui[:name].chop
        draw_name_input
      end

      def commit_name_input
        name = @name_ui[:name]
        close_name_input
        @interpreter.resume_name_input(name)
      end

      def draw_name_input
        ui = @name_ui
        ui[:win].dispose if ui[:win]
        rows = (NAME_CELLS.length + NAME_COLS - 1) / NAME_COLS
        inner_w = NAME_COLS * NAME_CELL_W
        inner_h = (rows + 1) * NAME_CELL_H # +1 row for the name-so-far
        win = Window.new((SCREEN_W - inner_w - Window::BORDER * 2) / 2, 30,
                         inner_w + Window::BORDER * 2, inner_h + Window::BORDER * 2)
        win.z = 400
        win.windowskin = @windowskin
        c = Bitmap.new(inner_w, inner_h)
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, inner_w, NAME_CELL_H, "Name: #{ui[:name]}"
        NAME_CELLS.each_with_index do |cell, i|
          cx = (i % NAME_COLS) * NAME_CELL_W
          cy = NAME_CELL_H + (i / NAME_COLS) * NAME_CELL_H
          label = cell == 'BS' ? '<' : cell
          c.draw_text cx, cy, NAME_CELL_W, NAME_CELL_H, label
        end
        win.contents = c
        sel = ui[:sel]
        win.cursor_rect = Rect.new((sel % NAME_COLS) * NAME_CELL_W,
                                   NAME_CELL_H + (sel / NAME_COLS) * NAME_CELL_H,
                                   NAME_CELL_W, NAME_CELL_H)
        ui[:win] = win
      end

      def close_name_input
        return unless @name_ui
        @name_ui[:win].dispose if @name_ui[:win]
        @name_ui = nil
      end

      # Display frames each animation frame is held; the fallback length (frames)
      # when the database has no data for the requested animation; and the flash
      # duration a timing fires.
      ANIM_CELL_FRAMES = 3
      ANIM_FALLBACK_FRAMES = 10
      ANIM_FLASH_FRAMES = 8
      # RPG2000 battle-animation cells: a 96x96 grid, 5 cells across the sheet.
      ANIM_CELL = 96
      ANIM_SHEET_COLS = 5

      # Drive a Show Battle Animation (11210) wait: play the animation over its
      # target, then resume the event. When the animation's data / sheet is
      # available it advances frame by frame (composited by #draw_map_animation),
      # firing the screen flashes its timings request; otherwise it degrades to a
      # plain timed wait, so a cutscene paces the same as RPG_RT either way.
      def drive_map_animation
        init_map_animation if @map_animation.nil? && @anim_wait.nil?
        @map_animation ? step_map_animation : step_animation_wait
      end

      # Begin the animation: build the frame-by-frame player from the request, or
      # arm the timed-wait fallback when there is no drawable animation.
      def init_map_animation
        @map_animation = start_map_animation
        if @map_animation
          fire_animation_flashes(@map_animation) # frame 0 flashes
        else
          @anim_wait = ANIM_FALLBACK_FRAMES * ANIM_CELL_FRAMES
        end
      end

      # Advance the drawable animation one frame per ANIM_CELL_FRAMES, firing that
      # frame's flashes; finish (hide, resume) once the last frame has played.
      def step_map_animation
        ma = @map_animation
        if ma[:timer] > 0
          ma[:timer] -= 1
          return
        end
        ma[:frame_i] += 1
        if ma[:frame_i] >= ma[:frames].length
          @animation_sprite.visible = false
          ma[:sheet].dispose if ma[:sheet].respond_to?(:dispose)
          @map_animation = nil
          # A battle animation is driven by the round rather than by an event
          # command, so there is no paused interpreter waiting on it.
          @interpreter.resume unless ma[:battle]
          return
        end
        fire_animation_flashes(ma)
        ma[:timer] = ANIM_CELL_FRAMES
      end

      def step_animation_wait
        if @anim_wait <= 0
          @anim_wait = nil
          @interpreter.resume
        else
          @anim_wait -= 1
        end
      end

      # Build the animation player, or nil when the animation is unknown or its
      # Battle/<name> sheet is missing (then the timed-wait fallback runs).
      def start_map_animation
        req = @interpreter.battle_animation
        return nil unless req
        tx, ty = animation_target_pixel(req[:target])
        build_animation(req[:animation], tx, ty)
      end

      # The animation player itself, shared by the map's Show Battle Animation
      # command and by a battle round. `battle` says the pixel is already a
      # screen position rather than a map one, and that nothing is waiting on the
      # animation to finish. nil when the animation is unknown or its
      # Battle/<name> sheet is missing.
      def build_animation(id, tx, ty, battle = false)
        anim = animation_row(id)
        return nil unless anim
        frames = table_entries(anim.frames)
        return nil if frames.empty?
        sheet = animation_sheet(anim.animation_name)
        return nil unless sheet
        { frames: frames, timings: table_entries(anim.timings), sheet: sheet,
          position: (anim.position || 1), tx: tx, ty: ty, frame_i: 0,
          timer: ANIM_CELL_FRAMES, battle: battle }
      end

      def animation_row(id)
        return nil if id.nil? || !@db.respond_to?(:battle_anime) || @db.battle_anime.nil?
        @db.battle_anime[id]
      rescue StandardError
        nil
      end

      def animation_sheet(name)
        return nil if name.nil? || name.empty?
        Bitmap.new "Battle/#{name}"
      rescue StandardError => e
        $stderr.puts "[RPG2k] battle animation '#{name}' load failed: #{e.message}"
        nil
      end

      # The target character's map-pixel position: the player, the running event
      # ("this event" / 0), or a map event by id, defaulting to the player.
      def animation_target_pixel(target)
        case target
        when MOVE_TARGET_PLAYER then player_pixel
        when 0, MOVE_TARGET_THIS
          @active_event ? event_pixel(@active_event) : player_pixel
        else
          ev = @events.find { |e| e[:id] == target }
          ev ? event_pixel(ev) : player_pixel
        end
      end

      # Fire the screen flashes the current frame's timings request (flash_scope
      # 2 = whole screen); RPG2000 stores the colour / power as 0..31 (scaled up
      # to the 0..255 the shared Game::Screen flash uses).
      def fire_animation_flashes(ma)
        ma[:timings].each do |t|
          next unless (t.frame || 0) == ma[:frame_i]
          next unless (t.flash_scope || 0) == 2
          @state.screen.flash((t.flash_red || 0) * 8, (t.flash_green || 0) * 8,
                              (t.flash_blue || 0) * 8, (t.flash_power || 0) * 8,
                              ANIM_FLASH_FRAMES)
        end
      end

      # Collect an Array2D (or a plain Hash test double) into a dense array of its
      # entries, in id order — both answer #each with (id, entry).
      def table_entries(table)
        out = []
        table.each { |_id, entry| out << entry } if table
        out
      end

      # Composite the animation's current frame over its target. Runs in the
      # render pass (the camera is known here): each visible cell of the frame is
      # blitted from the sheet's 96x96 grid to the target's screen position plus
      # the cell's offset. Zoom / tone / per-cell transparency are approximated as
      # a plain blit for now.
      def draw_map_animation(cam_x, cam_y)
        return unless @animation_sprite
        ma = @map_animation
        unless ma
          @animation_sprite.visible = false
          return
        end
        @animation_sprite.visible = true
        @animation_sprite.x = 0
        @animation_sprite.y = 0
        @animation_bmp.clear
        frame = ma[:frames][ma[:frame_i]]
        return unless frame
        # A map animation is placed in map pixels and follows the camera; a
        # battle one is already where it belongs on screen.
        cx = ma[:battle] ? ma[:tx] : ma[:tx] - cam_x + TILE / 2
        cy = ma[:battle] ? ma[:ty] : ma[:ty] - cam_y + TILE / 2
        table_entries(frame.cells).each do |cell|
          next if cell.respond_to?(:visible) && cell.visible == false
          blit_animation_cell(ma[:sheet], cell, cx, cy)
        end
      end

      def blit_animation_cell(sheet, cell, cx, cy)
        cid = cell.cell_id || 0
        sx = (cid % ANIM_SHEET_COLS) * ANIM_CELL
        sy = (cid / ANIM_SHEET_COLS) * ANIM_CELL
        dx = cx + (cell.x || 0) - ANIM_CELL / 2
        dy = cy + (cell.y || 0) - ANIM_CELL / 2
        @animation_bmp.blt dx, dy, sheet, Rect.new(sx, sy, ANIM_CELL, ANIM_CELL)
      rescue StandardError
        nil
      end

      def drive_wait
        @wait_timer = frames_from_tenths(@interpreter.wait_frames) if @wait_timer.nil?
        if @wait_timer <= 0
          @wait_timer = nil
          @interpreter.resume
        else
          @wait_timer -= 1
        end
      end

      # Convert an RPG2000 wait duration (tenths of a second) to a frame count at
      # the current frame rate (defaulting to 60 fps).
      def frames_from_tenths(tenths)
        fr = Graphics.frame_rate
        fr = 60 if fr.nil? || fr <= 0
        tenths * fr / 10
      end

      def perform_teleport(t)
        map_id, x, y, dir = t
        @map = @parent.load_map(map_id)
        @state.map = @map
        @state.map_id = map_id
        @state.x = x
        @state.y = y
        @state.direction = dir if dir && dir > 0
        # RPG2000 clears every shown picture when the map changes (RPG2003 is
        # the edition that added a per-picture "keep across map change" flag).
        # Without this, Nepheshel's opening leaves its full-screen credit
        # pictures on top of the first room and the map is never visible —
        # exactly what the wine comparison showed (ADR 0021).
        @state.erase_all_pictures
        # A Change Parallax Background override does not survive a teleport
        # either; the destination map's own panorama applies. Rebuild the
        # backdrop from the new map so it isn't drawn with the old one.
        @state.clear_parallax
        dispose_parallax
        setup_parallax
        # ... nor does a Pan Screen offset / camera lock: the camera re-centres
        # on the hero on the new map. Nepheshel's opening pans a long way before
        # teleporting into the first room, and keeping that offset drew the room
        # from (304, 352) -- entirely outside a 320x240 map, i.e. a blank screen.
        @state.screen.pan_clear
        @locked_cam = nil
        @tileset_id = nil # a Change Map Tileset override does not survive a teleport
        @chipset = build_chipset
        # The new map may use a different chipset graphic, so reload it too;
        # otherwise the destination is drawn with the previous map's tiles.
        old_bmp = @chipset_bmp
        @chipset_bmp = load_chipset_graphic
        old_bmp.dispose if old_bmp && !old_bmp.equal?(@chipset_bmp)
        @started_auto = {}
        @started_common = {}
        @active_event = nil
        @player_route = nil # a forced player route does not survive a teleport
        # Both are per-visit: an Erase Event does not follow the party to the
        # next map, and the destination's pages are chosen fresh.
        @erased_events = {}
        @page_revision = page_revision
        build_events
        @interpreter.resolver = build_resolver
        @interpreter.map_info = self
        build_parallels
        # Any step in flight is dropped: the party arrives standing on the
        # destination tile rather than sliding toward one on the map it left.
        # A forced route can have a step in flight here -- it advances between
        # events, and an auto-start page can teleport on the very next frame.
        @moving = false
        @move_count = 0
        @last_frame = nil
        # Resume, not stop: RPG_RT keeps running the rest of the event's own
        # command list after a Teleport lands, and the standard "fade to black,
        # teleport, fade back in" transition depends on it -- an Erase Screen
        # before the Teleport is paired with a Show Screen right after it, in
        # the SAME event, meant to run once the destination map is up. Stopping
        # here threw that trailing Show Screen away, so the erase overlay was
        # never lifted and the game stayed black from the first such teleport
        # on (this pattern opens Nepheshel's very first scene transition).
        @interpreter.resume
      rescue StandardError => e
        $stderr.puts "[RPG2k] Teleport failed: #{e.message}"
        @interpreter.stop
      end

      # Return to Title Screen: stop the running event and hand control back to
      # the app, which tears the play scenes down and shows a fresh title. There
      # is nothing to resume afterwards — this scene is being disposed.
      def perform_return_to_title
        @interpreter.stop
        @parent.return_to_title
      rescue StandardError => e
        $stderr.puts "[RPG2k] Return to Title failed: #{e.message}"
        @interpreter.stop
      end

      # -- message / choice window --------------------------------------------

      # RPG2000's message window is a fixed 320x80 panel pinned to the left edge
      # — it does not shrink to the message, and it does not inset from the
      # screen. Measured off a genuine RPG_RT frame under wine (ADR 0021): the
      # bottom-positioned window occupies exactly (0, 160)-(319, 239).
      MSG_WIN_W = 320
      MSG_WIN_H = 80
      # One text row. Four rows fit in the 64px interior.
      MSG_LINE_H = 16
      # Characters revealed per frame for the message typewriter effect.
      MSG_REVEAL_SPEED = 2
      # RPG2000 FaceSet geometry: a 4x4 grid of 48x48 face cells, drawn beside
      # the message text with a small gap.
      FACE_SIZE = 48
      FACE_MARGIN = 4

      # Look up an actor name by id for the \n[] message control code.
      #
      # The **live** actor is what RPG_RT names here, not the database row: a
      # hero the player named through Enter Hero Name (Nepheshel does exactly
      # that, then refers to them as \N[1] in 34 messages) or renamed by a Change
      # Actor Name has to be called what they are called now. Index **0** is the
      # party leader — the hero — which is how a boss addresses the player
      # character without knowing which actor id they are (`\n[0]よ…`).
      #
      # The roster is read without creating: naming an actor the game has never
      # met falls through to the database row instead of enrolling them in the
      # roster the save writes out.
      def actor_name(id)
        a = id.to_i.zero? ? party_leader : roster_actor(id)
        return a.name.to_s if a
        row = @db.player[id]
        row ? row.name.to_s : ''
      rescue StandardError => e
        $stderr.puts "[RPG2k] actor name ##{id} lookup failed: #{e.message}"
        ''
      end

      # The live actor `id`, if the game has one. nil for a scene fixture whose
      # party is a stub without a roster.
      def roster_actor(id)
        party = @state.party
        return nil unless party.respond_to?(:roster)
        party.roster.existing(id)
      end

      def party_leader
        party = @state.party
        party.respond_to?(:leader) ? party.leader : nil
      end

      def open_message(lines, choice)
        return if @message
        names = ->(id) { actor_name(id) }
        raw = (lines || [])
        raw = [''] if raw.empty?
        # Parse each line into colour runs; the plain text (segments joined)
        # drives the reveal counter so it counts visible characters only.
        scans = raw.map do |l|
          Game::Message.scan(l.to_s, @state.variables, names)
        end
        seg_lines = scans.map { |s| s[:segments] }
        plain = seg_lines.map { |segs| segs.map { |s| s[:text] }.join }
        # Lift each line's pacing codes into global reveal coordinates (offset by
        # the visible length of the lines before it) so one reveal counter drives
        # the whole window.
        pauses = []
        instants = []
        auto_close = false
        show_gold = false
        offset = 0
        scans.each_with_index do |s, li|
          s[:pauses].each { |p| pauses << { at: offset + p[:at], kind: p[:kind] } }
          (s[:instants] || []).each { |a, b| instants << [offset + a, offset + b] }
          auto_close ||= s[:auto_close]
          show_gold ||= s[:show_gold]
          offset += plain[li].length
        end

        # Message Options / Change Face Graphic settings in effect for this
        # window (position, transparency and an optional FaceSet graphic).
        cfg = @state.message_config
        face = load_face(cfg)
        face_left = face && !cfg.face_right
        face_right = face && cfg.face_right
        text_x = face_left ? FACE_SIZE + FACE_MARGIN : 0

        inner_w = MSG_WIN_W - Window::BORDER * 2
        text_w = inner_w - text_x - (face_right ? FACE_SIZE + FACE_MARGIN : 0)
        inner_h = MSG_WIN_H - Window::BORDER * 2
        win_h = MSG_WIN_H
        win = Window.new(0, message_window_y(win_h, cfg), MSG_WIN_W, win_h)
        win.z = 300
        win.windowskin = @windowskin
        win.transparent = cfg.transparent

        contents = Bitmap.new(inner_w, inner_h)

        # Plain messages type out gradually; choice lists appear at once.
        reveal = Game::TextReveal.new(plain, 0, pauses, auto_close, instants)
        reveal.reveal_all if choice
        # `\$` shows the party's gold in a small window alongside the message.
        gold_window = show_gold ? build_inn_gold_window(nonblank(db.term.gold, 'G')) : nil
        @message = { window: win, choice: choice, count: plain.length,
                     reveal: reveal, contents: contents, inner_w: inner_w,
                     seg_lines: seg_lines, face: face,
                     face_index: cfg.face_index,
                     face_x: face_right ? inner_w - FACE_SIZE : 0,
                     text_x: text_x, text_w: text_w, gold_window: gold_window }
        draw_message_contents
        win.contents = contents
        @choice_index = 0
        set_choice_cursor if choice
      end

      # Vertical position of a `win_h`-tall message window for the configured
      # display position (top / middle / bottom). When the message is not pinned
      # (`position_fixed` off, RPG2000's default), the window relocates so it does
      # not cover the hero: if the hero is standing in the lower half of the
      # screen the window jumps to the top, and vice-versa (so talking to
      # something at the bottom edge of a map shows the text up top). The exact
      # zone boundary is approximate pending a wine diff; the direction matches
      # RPG_RT.
      def message_window_y(win_h, cfg)
        pos = cfg.position
        pos = auto_message_position(win_h) unless cfg.position_fixed
        case pos
        when Game::MessageConfig::POS_TOP    then 0
        when Game::MessageConfig::POS_MIDDLE then (SCREEN_H - win_h) / 2
        else SCREEN_H - win_h
        end
      end

      # Pick the message position that keeps clear of the hero: top when the hero
      # is in the lower half of the screen, bottom otherwise.
      def auto_message_position(_win_h)
        if hero_screen_y >= SCREEN_H / 2
          Game::MessageConfig::POS_TOP
        else
          Game::MessageConfig::POS_BOTTOM
        end
      end

      # The hero tile's centre in screen pixels, from the edge-clamped follow
      # camera (ignoring transient pan / shake offsets).
      def hero_screen_y
        _px, py = player_pixel
        cam_y = Game.camera_offset(py + TILE / 2, SCREEN_H, @map.height * TILE)
        (py + TILE / 2) - cam_y
      end

      # Load the FaceSet graphic named by the message config, or nil when no face
      # is selected or the file is missing (the message then shows text only).
      # Colour-keyed like the other character art: a FaceSet's palette entry 0 is
      # its background, and drawing it opaque boxes the portrait in.
      def load_face(cfg)
        return nil unless cfg.face?
        Bitmap.new "FaceSet/#{cfg.face_name}", true
      rescue StandardError => e
        $stderr.puts "[RPG2k] face graphic '#{cfg.face_name}' load failed: #{e.message}"
        nil
      end

      # (Re)draw the message body showing the currently revealed characters,
      # each colour run in its own colour, laid out left to right per line. The
      # face graphic (when present) is drawn first, and text is inset past it.
      def draw_message_contents
        return unless @message
        c = @message[:contents]
        c.clear
        draw_message_face
        vis = Game::Message.visible_segments(@message[:seg_lines],
                                             @message[:reveal].revealed)
        right = @message[:text_x] + @message[:text_w]
        vis.each_with_index do |segs, i|
          x = @message[:text_x]
          y = i * MSG_LINE_H
          segs.each do |seg|
            draw_message_run(c, x, y, right - x, seg)
            x += c.text_size(seg[:text]).width
          end
        end
      end

      # Draw one coloured message run. When the System windowskin is present and
      # the colour index is one of its 20 text swatches, blend the glyphs with
      # that swatch (`Bitmap#blend_text`), so the text takes the windowskin's own
      # colour and shading the way RPG2000 draws it. Otherwise fall back to a
      # flat font colour (the approximation, or an out-of-range `\c[n]`).
      def draw_message_run(c, x, y, w, seg)
        idx = seg[:color]
        if @windowskin && Game::MessagePalette.valid?(idx)
          draw_system_text c, x, y, w, MSG_LINE_H, seg[:text], @windowskin, idx
        else
          c.font.color = message_color(idx)
          c.draw_text x, y, w, MSG_LINE_H, seg[:text]
        end
      end

      # Blit the selected face cell (a 48x48 tile of the 4x4 FaceSet grid) into
      # the message contents at its configured side.
      def draw_message_face
        face = @message[:face]
        return unless face
        idx = @message[:face_index]
        src = Rect.new((idx % 4) * FACE_SIZE, (idx / 4) * FACE_SIZE,
                       FACE_SIZE, FACE_SIZE)
        @message[:contents].blt @message[:face_x], 0, face, src
      end

      # RPG2000 message text palette (`\c[n]`). A small built-in approximation
      # until the real 20-colour row is read from the System windowskin; unknown
      # indices fall back to the default (white).
      MSG_COLORS = {
        0 => [255, 255, 255], 1 => [128, 176, 255], 2 => [255, 128, 128],
        3 => [128, 255, 128], 4 => [255, 255, 128], 5 => [128, 240, 240],
        6 => [255, 160, 255], 7 => [200, 200, 200], 8 => [255, 192, 128],
        9 => [160, 160, 255]
      }.freeze

      # The flat fallback colour for a `\c[n]` run — used only when there is no
      # System windowskin to blend the glyphs with (see draw_message_run), or for
      # an out-of-range colour index. Always opaque.
      def message_color(idx)
        rgb = MSG_COLORS[idx] || MSG_COLORS[0]
        Color.new(rgb[0], rgb[1], rgb[2], 255)
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
            play_system_se(SFX_CURSOR)
          elsif Input.trigger?(Input::UP) && @choice_index > 0
            @choice_index -= 1
            set_choice_cursor
            play_system_se(SFX_CURSOR)
          elsif Input.trigger?(Input::C)
            play_system_se(SFX_DECISION)
            index = @choice_index
            close_message
            @interpreter.choose(index)
          elsif Input.trigger?(Input::B) && @interpreter.choice_cancellable?
            # The Show Choices block says what cancelling means (pick a given
            # choice, or run its [Cancel] branch); a block that forbids it
            # swallows the key, as RPG_RT does.
            play_system_se(SFX_CANCEL)
            close_message
            @interpreter.cancel_choice
          end
        else
          drive_text_message
        end
      end

      # RPG2000 system-sound slots (Change System SFX / 10670 stores overrides by
      # these indices; the same order backs the database defaults).
      SFX_CURSOR = 0
      SFX_DECISION = 1
      SFX_CANCEL = 2
      SFX_BUZZER = 3
      # The slots keep the database's own order (System fields 41..52), so slot 4
      # is Battle Start and slot 5 Escape — the sound RPG_RT plays when someone
      # runs from a fight (Force Flee, 1006).
      SFX_BATTLE = 4
      SFX_ESCAPE = 5
      DB_SE_FIELD = { SFX_CURSOR => :cursor_se, SFX_DECISION => :decision_se,
                      SFX_CANCEL => :cancel_se, SFX_BUZZER => :buzzer_se,
                      SFX_BATTLE => :battle_se, SFX_ESCAPE => :escape_se }.freeze

      # Play a system sound effect by slot, preferring a Change System SFX
      # override held on the game state and falling back to the database's own
      # sound. A no-op when neither names a file (or no audio backend is present).
      def play_system_se(slot)
        se = system_se(slot)
        return unless se
        Audio.se_play se[:name], se[:volume] || 100, se[:tempo] || 100
      rescue StandardError => e
        $stderr.puts "[RPG2k] system SE '#{slot}' playback failed: #{e.message}"
      end

      # The audio for a system slot as { name:, volume:, tempo: } — the state
      # override (set by Change System SFX) first, then the database default for
      # that slot, or nil when neither names a file.
      def system_se(slot)
        ov = @state.system_sfx[slot]
        return ov if ov && ov[:name] && !ov[:name].empty?
        db_system_se(slot)
      end

      def db_system_se(slot)
        field = DB_SE_FIELD[slot]
        return nil unless field && db.system.respond_to?(field)
        se = db.system.send(field)
        name = se && se.respond_to?(:file) ? se.file : nil
        return nil if name.nil? || name.empty?
        { name: name, volume: (se.respond_to?(:volume) ? se.volume : 100),
          tempo: (se.respond_to?(:pitch) ? se.pitch : 100) }
      end

      # A plain (non-choice) message: type the text out, and let a button press
      # first complete the reveal, then (once fully shown) dismiss and resume.
      # Frames a `\.` (quarter-second) and `\|` (full-second) pause hold.
      MSG_PAUSE_QUARTER = 15
      MSG_PAUSE_FULL = 60

      def drive_text_message
        reveal = @message[:reveal]
        pressed = Input.trigger?(Input::C) || Input.trigger?(Input::B)
        unless reveal.done?
          pause = reveal.pending_pause
          if pause
            drive_message_pause(reveal, pause, pressed)
          elsif pressed
            reveal.reveal_all
          else
            reveal.advance(MSG_REVEAL_SPEED)
          end
          draw_message_contents
          return
        end
        # `\^` closes the finished window on its own; otherwise wait for a button.
        if reveal.auto_close? || pressed
          close_message
          @interpreter.resume
        end
      end

      # Hold the reveal at a pacing code: `\!` waits for a button, `\.` / `\|`
      # count down a fixed number of frames (a button skips the wait).
      def drive_message_pause(reveal, pause, pressed)
        if pause[:kind] == :key
          reveal.release_pause if pressed
          return
        end
        @message[:pause_frames] ||=
          pause[:kind] == :full ? MSG_PAUSE_FULL : MSG_PAUSE_QUARTER
        @message[:pause_frames] -= 1
        if pressed || @message[:pause_frames] <= 0
          @message[:pause_frames] = nil
          reveal.release_pause
        end
      end

      def close_message
        return unless @message
        @message[:window].dispose
        @message[:gold_window].dispose if @message[:gold_window]
        @message = nil
      end

      # -- number input (Input Number command) --------------------------------

      # Pixels per digit cell in the Input Number widget.
      NUM_CELL = 16

      # Open a digit-entry window for the Input Number command. A compact panel
      # near the bottom of the screen shows `digits` cells with an editable
      # cursor; the interpreter is resumed with the entered value on confirm.
      def open_number_input(digits)
        return if @number_input
        model = Game::NumberInput.new(digits || 1)
        inner_w = model.digits * NUM_CELL
        inner_h = MSG_LINE_H
        win_w = inner_w + Window::BORDER * 2
        win_h = inner_h + Window::BORDER * 2
        win = Window.new((SCREEN_W - win_w) / 2, SCREEN_H - win_h - 6, win_w, win_h)
        win.z = 320
        win.windowskin = @windowskin
        contents = Bitmap.new(inner_w, inner_h)
        @number_input = { window: win, contents: contents, model: model }
        draw_number_input
        win.contents = contents
      end

      def draw_number_input
        ni = @number_input
        return unless ni
        model = ni[:model]
        c = ni[:contents]
        c.clear
        (0...model.digits).each do |i|
          x = i * NUM_CELL
          if i == model.cursor
            c.fill_rect x, 1, NUM_CELL, MSG_LINE_H - 2, Color.new(40, 72, 200, 160)
          end
          c.font.color = Color.new(255, 255, 255, 255)
          c.draw_text x, 0, NUM_CELL, MSG_LINE_H, model.digit(i).to_s, 1
        end
      end

      def drive_number_input
        ni = @number_input
        model = ni[:model]
        if Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          model.inc
          draw_number_input
        elsif Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          model.dec
          draw_number_input
        elsif Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)
          model.left
          draw_number_input
        elsif Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)
          model.right
          draw_number_input
        elsif Input.trigger?(Input::C)
          value = model.value
          close_number_input
          @interpreter.resume_number(value)
        end
      end

      def close_number_input
        return unless @number_input
        @number_input[:window].dispose
        @number_input = nil
      end

      def step_movement
        return if advance_player_slide

        return if event_busy? # don't start a new move while an event runs
        return if @player_route # a forced route controls the player
        dir = Input.dir4
        return if dir == 0

        @state.direction = dir
        nx, ny = target_tile(@state.x, @state.y, dir)

        if @state.boarded?
          # Aboard a vehicle: use the vehicle's passability and glide over touch
          # events (you cannot trigger them from the water / air).
          return unless vehicle_passable?(nx, ny, dir, @state.boarded)
        else
          # Walking into a touch event runs it instead of moving. **Both** touch
          # triggers answer here: RPG_RT tests them as one set on every
          # player-side path (EasyRPG's `{Trigger_touched, Trigger_collision}` in
          # `Game_Player::Update` / `UpdateMovement`), so the asymmetry is not
          # the one the trigger names suggest — an "event touch" (2) event fires
          # whether it walked into the party or the party walked into it, while
          # a "player touch" (1) fires only on the party's own move (the event
          # side checks trigger 2 alone, see #move_autonomous).
          touched = event_at(nx, ny)
          if touched && touch_trigger?(touched[:trigger]) && touched[:commands]
            start_event(touched)
            return
          end
          return unless passable?(nx, ny, dir)
        end

        @dest_x = nx
        @dest_y = ny
        @moving = true
        @move_count = 0
      end

      # One tile walked. Advance the party's step counter and let RPG2000's field
      # slip damage act on it: a status condition carrying a map-step interval
      # (mtf-meido-action's Poison, 1 HP every 4 steps, is the only one in either
      # test bed) drains its afflicted members every time the count reaches a
      # multiple of that interval.
      #
      # The drain cannot kill -- Party#apply_map_step_damage floors it at 1 HP --
      # so unlike the event commands that damage the party this needs no game-over
      # check. It flashes the screen red instead, because otherwise the HP would
      # simply fall with nothing on screen saying why: the map has no HP display.
      def note_party_step
        steps = @state.walk_step
        hit = @state.party.apply_map_step_damage(state_table, steps)
        # RPG2000's 地形ダメージ on top of it: the terrain the tile just stepped
        # onto belongs to may take HP off everyone not wearing gear that blocks
        # it. Read after the status slip and flashed together, since both are the
        # same "your HP just fell and the map has nowhere to say so" moment.
        hit = hit + terrain_step_damage
        return if hit.empty?
        @state.screen.flash(*STEP_DAMAGE_FLASH)
      end

      # Apply the damage of the terrain under the party, returning the actors it
      # hit ([] when the tile is harmless or the database has no terrain table).
      def terrain_step_damage
        row = terrain_row_at(@state.x, @state.y)
        return [] unless row && row.respond_to?(:damage)
        @state.party.apply_terrain_damage(row.damage)
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

      # The view's top-left corner in map pixels — where the camera is looking
      # this frame. Extracted from #render so the Control Variables "screen
      # coordinate" operand can ask for it too; it is a pure function of the
      # hero position, the pan lock/offset and the shake, apart from `@locked_cam`
      # being captured the first frame the camera locks (which is idempotent, so
      # an extra caller cannot move the view).
      def camera_position
        px, py = player_pixel
        screen = @state.screen
        hero_cx = Game.camera_offset(px + TILE / 2, SCREEN_W, @map.width * TILE)
        hero_cy = Game.camera_offset(py + TILE / 2, SCREEN_H, @map.height * TILE)
        # Pan Screen: while the camera is locked it holds where locking began
        # (captured once) instead of following the hero; the pan offset then
        # scrolls that view. Unlocked, it tracks the hero as usual.
        if screen.pan_locked?
          @locked_cam ||= [hero_cx, hero_cy]
          base_x, base_y = @locked_cam
        else
          @locked_cam = nil
          base_x = hero_cx
          base_y = hero_cy
        end
        ox, oy = screen.pan_offset
        # Screen shake slides the whole view horizontally (the player moves with
        # the map, so the entire screen shakes); the map edge may show a sliver
        # of void during the shake/pan, which is fine.
        [base_x + ox - screen.shake_offset, base_y + oy]
      end

      # Where a character sits on screen, for the Control Variables "character"
      # operand's screen-coordinate selectors. `ref` is the operand's reference:
      # 10001 the hero, a positive id a map event. nil when it names something
      # this scene cannot place.
      #
      # RPG_RT measures X from the tile's centre and Y from its *bottom* — the
      # asymmetry is real (EasyRPG's GetScreenX subtracts half a tile after
      # adding a whole one, GetScreenY only adds the whole one), so it is
      # reproduced rather than tidied up.
      def character_screen_position(ref)
        pixel =
          if ref == 10001
            player_pixel
          else
            e = @events.find { |ev| ev[:id] == ref }
            e && event_pixel(e)
          end
        return nil unless pixel
        cam_x, cam_y = camera_position
        { x: pixel[0] - cam_x + TILE / 2, y: pixel[1] - cam_y + TILE }
      end
      public :camera_position, :character_screen_position

      def render
        px, py = player_pixel
        cam_x, cam_y = camera_position

        draw_parallax cam_x, cam_y
        draw_layers cam_x, cam_y

        @player_sprite.x = px - cam_x - (Game::CharSet::WIDTH - TILE) / 2
        @player_sprite.y = py - cam_y - (Game::CharSet::HEIGHT - TILE) -
                           player_jump_offset
        # Reflect the Set Transparent Flag command (and any leader graphic flag)
        # every frame so the hero hides/shows as events toggle it.
        @player_sprite.visible = !player_hidden?
        draw_player_frame
        draw_vehicles cam_x, cam_y, px, py
        draw_map_animation cam_x, cam_y

        draw_pictures cam_x, cam_y
        update_screen_overlay
        draw_timer
      end

      # RPG2000 timer: a small window in the top centre showing the remaining
      # time as M:SS while the timer is visible. Visibility (the Start command's
      # "show timer" flag) is independent of whether it is still counting, so a
      # stopped timer stays on screen frozen; it hides only when never shown.
      # The window and its contents are built once, and the text is redrawn only
      # when the displayed second changes (not every frame).
      TIMER_INNER_W = 40
      TIMER_INNER_H = 16

      # Both timers are drawn the same way; RPG_RT puts the first at the screen's
      # left edge and the second at its right, so the two are laid out that way
      # here too (drawing them as digit sprites off the System graphic, the way
      # RPG_RT actually does, is a rendering-parity job of its own).
      def draw_timer
        battle = !@battle_ui.nil?
        @timer_windows ||= [nil, nil]
        @timer_texts ||= [nil, nil]
        2.times { |id| draw_one_timer(id, battle) }
      end

      def draw_one_timer(id, battle)
        timer = @state.timer(id)
        unless timer.drawn?(battle)
          w = @timer_windows[id]
          w.visible = false if w
          return
        end
        @timer_windows[id] ||= build_timer_window(id)
        win = @timer_windows[id]
        win.visible = true
        text = timer.display_text
        return if text == @timer_texts[id]

        @timer_texts[id] = text
        c = win.contents
        c.clear
        c.font.color = Color.new(255, 255, 255, 255)
        c.draw_text 0, 0, c.width, c.height, text, 1 # centre-aligned
      end

      def build_timer_window(id)
        ow = TIMER_INNER_W + Window::BORDER * 2
        oh = TIMER_INNER_H + Window::BORDER * 2
        # Timer 1 sits left of centre and timer 2 right of it, mirroring the
        # edges RPG_RT parks them at while keeping this build's centred window.
        x = id == 0 ? (SCREEN_W - ow) / 2 : SCREEN_W - ow - 4
        win = Window.new(x, 4, ow, oh)
        win.z = 250 # above the map, below the message / menu windows (z 300+)
        win.windowskin = @windowskin
        win.contents = Bitmap.new(TIMER_INNER_W, TIMER_INNER_H)
        win
      end

      # Position and draw each vehicle placed on the current map. A parked vehicle
      # sits on its own tile; the ridden one follows the party's pixel position
      # (so it slides smoothly), drawn just under the hero. A vehicle on another
      # map, or one with no CharSet graphic, is hidden.
      # Pixels the airship floats above its shadow on the ground.
      AIRSHIP_ALTITUDE = 8

      def draw_vehicles(cam_x, cam_y, px, py)
        return unless @vehicle_sprites
        @airship_shadow.visible = false
        Game::Vehicle::TYPES.each do |type|
          spr = @vehicle_sprites[type]
          v = @state.vehicle(type)
          charset = (v.placed? && v.map_id == @state.map_id) ? vehicle_charset(v) : nil
          unless charset
            spr.visible = false
            next
          end
          ridden = @state.boarded == type
          vpx = ridden ? px : v.x * TILE
          vpy = ridden ? py : v.y * TILE
          sx = vpx - cam_x - (Game::CharSet::WIDTH - TILE) / 2
          sy = vpy - cam_y - (Game::CharSet::HEIGHT - TILE)
          if type == :airship
            # The shadow marks the ground tile; the airship floats above it.
            @airship_shadow.x = vpx - cam_x
            @airship_shadow.y = vpy - cam_y
            @airship_shadow.visible = true
            sy -= AIRSHIP_ALTITUDE
          end
          spr.x = sx
          spr.y = sy
          spr.visible = true
          draw_vehicle_frame(type, v, charset)
        end
      end

      # Blit the vehicle's CharSet cell into its sprite buffer (standing pattern).
      def draw_vehicle_frame(type, v, charset)
        rx, ry, rw, rh = Game::CharSet.frame_rect(v.charset_index, v.direction, 1)
        bmp = @vehicle_bmps[type]
        bmp.clear
        bmp.blt 0, 0, charset, Rect.new(rx, ry, rw, rh)
      end

      # The CharSet graphic for a vehicle: its own (set by Change Vehicle Graphic /
      # the initial placement) or the database default (System boat/ship/airship
      # name), loaded through the shared event-charset cache. nil when it has none.
      def vehicle_charset(v)
        name = v.charset_name
        if (name.nil? || name.empty?)
          field = "#{v.type}_name"
          name = @db.system.send(field) if @db.system.respond_to?(field)
        end
        event_charset(name)
      end

      # Composite the Show Picture layer into its buffer, drawing lowest-id first
      # so higher-numbered pictures sit on top. Each picture is scaled by its zoom
      # about its centre and blitted at its opacity; a picture pinned to the map
      # scrolls with the camera, otherwise it holds its screen position. (Tone is
      # carried on the picture but not yet applied — that needs native tone
      # support, like the screen tint.)
      def draw_pictures(cam_x, cam_y)
        @picture_bmp.clear
        pics = @state.pictures
        return if pics.empty?
        pics.keys.sort.each { |id| draw_picture pics[id], cam_x, cam_y }
      end

      # A picture's RPG2000 tone channel (0..200, 100 neutral) as an RGSS Tone
      # component (-255..255), the same conversion the screen tint uses.
      #
      # The division truncates **toward zero**, not toward negative infinity as
      # Ruby's `/` would: the reference does this in C++ integer arithmetic, so a
      # channel of 30 is -178 rather than the -179 flooring gives. One unit of
      # 255 is invisible, but a rounding rule is worth getting on purpose.
      def self.tone_channel(v)
        n = ((v || 100) - 100) * 255
        n < 0 ? -(-n / 100) : n / 100
      end

      # Whether a picture asks for any tint at all.
      def toned?(pic)
        pic.red != 100 || pic.green != 100 || pic.blue != 100 ||
          pic.saturation != 100
      end

      # The picture's source with its tone baked in, cached per (image, tone) so
      # the software tone pass runs when the tint changes rather than every
      # frame. `Bitmap#tone_blt` writes to a *separate* destination on purpose —
      # toning in place would re-tone the same pixels each frame and walk the
      # image to black — so the scratch is a same-size bitmap per cache entry.
      #
      # This rides the path pictures already draw through: the result is blitted
      # into the shared picture bitmap, which is mutated in place. It is not the
      # per-frame `Sprite#bitmap=` swap that the map-layer tint attempt found
      # does not reach the display (see the screen-effects note in docs/TODO.md).
      def toned_picture_src(pic, src)
        key = [pic.name, pic.use_transparent_color,
               pic.red, pic.green, pic.blue, pic.saturation]
        cached = @picture_tone_cache[key]
        return cached if cached
        scratch = Bitmap.new(src.width, src.height)
        tone = Tone.new(Scene::Map.tone_channel(pic.red),
                        Scene::Map.tone_channel(pic.green),
                        Scene::Map.tone_channel(pic.blue),
                        # RPG2000's saturation runs the other way from RGSS's
                        # grey: below 100 is *less* saturated, so a value under
                        # neutral becomes positive desaturation.
                        Scene::Map.tone_channel(pic.saturation) * -1)
        scratch.tone_blt src, tone
        # Bounded so a picture cycling through tones cannot grow it without end;
        # the oldest entry goes first.
        @picture_tone_cache.delete(@picture_tone_cache.keys.first) if
          @picture_tone_cache.size >= PICTURE_TONE_CACHE_MAX
        @picture_tone_cache[key] = scratch
      rescue StandardError => e
        $stderr.puts "[RPG2k] picture ##{pic.id} tone failed, drawn untinted: #{e.message}"
        nil
      end

      # How many toned picture variants to keep before evicting the oldest.
      PICTURE_TONE_CACHE_MAX = 16

      def draw_picture(pic, cam_x, cam_y)
        src = picture_src(pic.name, pic.use_transparent_color)
        return unless src
        src = (toned_picture_src(pic, src) || src) if toned?(pic)
        zw = src.width * pic.zoom / 100
        zh = src.height * pic.zoom / 100
        return if zw <= 0 || zh <= 0
        # RPG2000 positions a picture by its centre.
        dx = pic.x - zw / 2
        dy = pic.y - zh / 2
        if pic.fixed_to_map
          dx -= cam_x
          dy -= cam_y
        end
        @picture_bmp.stretch_blt Rect.new(dx, dy, zw, zh), src,
                                 Rect.new(0, 0, src.width, src.height),
                                 pic.opacity
      rescue StandardError => e
        $stderr.puts "[RPG2k] picture ##{pic.id} draw failed: #{e.message}"
      end

      # Composite the parallax background into its screen-sized buffer, tiling
      # the image along any looping axis so it fills the view. The per-axis
      # start offset (and, for a looping axis, the scroll/autoscroll) comes from
      # Game::Parallax; @anim_frame drives the autoscroll. A non-looping axis
      # draws a single copy at its anchored offset.
      def draw_parallax cam_x, cam_y
        return unless @parallax_img
        iw = @parallax_img.width
        ih = @parallax_img.height
        ox = Game::Parallax.axis_offset(@par_loop_x, @par_auto_x, @par_sx,
                                        @anim_frame, cam_x, SCREEN_W,
                                        @map.width * TILE, iw)
        oy = Game::Parallax.axis_offset(@par_loop_y, @par_auto_y, @par_sy,
                                        @anim_frame, cam_y, SCREEN_H,
                                        @map.height * TILE, ih)
        @parallax_bmp.clear
        src = Rect.new(0, 0, iw, ih)
        parallax_tiles(oy, ih, SCREEN_H, @par_loop_y).each do |dy|
          parallax_tiles(ox, iw, SCREEN_W, @par_loop_x).each do |dx|
            @parallax_bmp.blt dx, dy, @parallax_img, src
          end
        end
      end

      # Draw positions along one axis so the image (size `size`, starting at
      # `off` <= 0) covers `screen`: repeated every `size` when the axis loops,
      # a single copy at `off` otherwise.
      def parallax_tiles(off, size, screen, loop)
        return [off] unless loop && size > 0
        d = off
        d -= size while d > 0        # begin at or left of the origin
        d += size while d + size <= 0 # but not entirely off-screen
        out = []
        while d < screen
          out << d
          d += size
        end
        out
      end

      def draw_layers cam_x, cam_y
        @lower_bmp.clear
        @upper_bmp.clear
        first_tx = cam_x / TILE
        first_ty = cam_y / TILE
        ox = cam_x % TILE
        oy = cam_y % TILE

        # Animation columns/frames for this render, shared by every tile so the
        # whole map animates in lock-step. Only needed on the real-chipset path.
        if @chipset_bmp
          abf = Game::ChipsetLayout.anim_ab(@anim_frame, @chipset.animation_type,
                                            @chipset.animation_speed)
          cf = Game::ChipsetLayout.anim_c(@anim_frame)
        end

        (0...ROWS).each do |ry|
          (0...COLS).each do |rx|
            tx = first_tx + rx
            ty = first_ty + ry
            dx = rx * TILE - ox
            dy = ry * TILE - oy

            lower = @map.lower(tx, ty)
            upper = @map.upper(tx, ty)

            if @chipset_bmp
              draw_tile @lower_bmp, lower, dx, dy, abf, cf
              # 0 means "no upper tile" (the upper layer's own ids start at
              # BLOCK_F); on the lower layer the same value is water set 0, so
              # only this call may skip it. See Game::ChipsetLayout.block.
              draw_tile @upper_bmp, upper, dx, dy, abf, cf if upper && upper != 0
            else
              # Fallback: solid colour blocks keyed by tile id (no chipset image).
              @lower_bmp.fill_rect dx, dy, TILE, TILE, tile_color(lower)
              @upper_bmp.fill_rect dx, dy, TILE, TILE, tile_color(upper) if upper && upper != 0
            end
          end
        end

        draw_events cam_x, cam_y
      end

      # Draw every event's graphic into the tile buffers, layered so it composits
      # correctly with the player sprite (z=100, between the lower buffer at z=0
      # and the upper buffer at z=200):
      #   * below-hero events (page layer 0) go in the lower buffer, under the
      #     player;
      #   * above-hero events (layer 2) go in the upper buffer, over the player;
      #   * same-layer events (layer 1) go under the player when they stand
      #     behind him (smaller y) and over him when in front (larger-or-equal
      #     y), the y-sort RPG2000 applies within the character layer.
      # A translucent page is blitted at half opacity. Events with no graphic
      # (empty CharSet name and no tile substitution) draw nothing.
      def draw_events(cam_x, cam_y)
        @events.each { |e| draw_event e, cam_x, cam_y }
      end

      def draw_event(e, cam_x, cam_y)
        bmp = event_target_buffer(e)
        return unless bmp
        opacity = e[:translucent] ? 128 : 255
        ch = e[:char]
        name = ch.graphic_name
        if name && !name.empty?
          draw_event_charset(e, bmp, cam_x, cam_y, opacity)
        elsif ch.graphic_index && ch.graphic_index > 0
          draw_event_tile(e, bmp, cam_x, cam_y, opacity)
        end
      rescue StandardError => ex
        $stderr.puts "[RPG2k] event ##{e[:id]} draw failed: #{ex.message}"
      end

      # Which tile buffer an event composits into, per its page layer and (for
      # the same-as-hero layer) its y relative to the player.
      def event_target_buffer(e)
        case e[:layer]
        when 2 then @upper_bmp                                   # above hero
        when 1 then e[:char].y >= @state.y ? @upper_bmp : @lower_bmp
        else @lower_bmp                                          # below hero
        end
      end

      # Blit an event's CharSet frame (24x32), feet-on-tile like the player.
      def draw_event_charset(e, bmp, cam_x, cam_y, opacity)
        charset = event_charset(e[:char].graphic_name)
        return unless charset
        dir, col = Game::EventGraphic.frame(e[:anim_type], e[:base_dir],
                                            e[:base_pattern],
                                            e[:char].direction, e[:anim_phase],
                                            e[:moving])
        sx, sy, sw, sh = Game::CharSet.frame_rect(e[:char].graphic_index, dir, col)
        epx, epy = event_pixel(e)
        dx = epx - cam_x - (Game::CharSet::WIDTH - TILE) / 2
        dy = epy - cam_y - (Game::CharSet::HEIGHT - TILE) - event_jump_offset(e)
        src = Rect.new(sx, sy, sw, sh)
        bush = event_bush_depth(e)
        toned = e[:flash] && flashed_charset(charset, src, e[:flash])
        if toned
          blt_bushed bmp, dx, dy, toned,
                     Rect.new(0, 0, Game::CharSet::WIDTH, Game::CharSet::HEIGHT),
                     opacity, bush
        else
          blt_bushed bmp, dx, dy, charset, src, opacity, bush
        end
      end

      # A Flash-Sprite-tinted copy of one CharSet frame, or nil when the tone
      # pass is unavailable. The frame is lifted into a scratch buffer (tone_blt
      # works on same-size bitmaps) and toned with the flash's current colour,
      # which brightens the sprite toward that colour without touching its alpha
      # — so the flash keeps the character's outline instead of painting a
      # rectangle over it.
      def flashed_charset(charset, src, flash)
        buf = flash_buffer
        buf.clear
        buf.blt 0, 0, charset, src
        out = flash_out_buffer
        out.tone_blt buf, flash_tone(flash)
        out
      rescue StandardError => e
        $stderr.puts "[RPG2k] sprite flash tone failed: #{e.message}"
        nil
      end

      # Blit an event whose graphic is a chipset tile (16x16), aligned to its
      # tile. Needs the chipset image; with none loaded (colour-block fallback)
      # the tile event is skipped.
      def draw_event_tile(e, bmp, cam_x, cam_y, opacity)
        return unless @chipset_bmp
        sx, sy, sw, sh = Game::ChipsetLayout.event_tile_rect(e[:char].graphic_index)
        epx, epy = event_pixel(e)
        dx = epx - cam_x
        dy = epy - cam_y - event_jump_offset(e)
        # A tile-graphic event wades like any other: RPG_RT sinks the sprite, not
        # a particular kind of graphic. The depth is scaled off this frame's own
        # height, which is one tile rather than the 32px charset frame.
        blt_bushed bmp, dx, dy, @chipset_bmp, Rect.new(sx, sy, sw, sh), opacity,
                   event_bush_depth(e, sh)
      end

      # Blit one map tile from the chipset image into `bmp` at (dx, dy). A plain
      # chip is a single 16x16 copy; an autotile is assembled from four 8x8
      # quarters. Empty/out-of-range ids draw nothing (id 0 is transparent).
      def draw_tile bmp, id, dx, dy, abf, cf
        Game::ChipsetLayout.quads(id, abf, cf).each do |qdx, qdy, sx, sy, w, h|
          bmp.blt dx + qdx, dy + qdy, @chipset_bmp, Rect.new(sx, sy, w, h)
        end
      end

      def draw_player_frame
        return unless @charset
        pat = @moving ? Game::CharSet::WALK_PATTERNS[(@move_count / 4) % 4] : 1
        bush = player_bush_depth
        # The sunken depth is part of the frame key, so walking into and out of
        # tall grass redraws the sprite even though the pose has not changed.
        frame = [@state.direction, pat, bush]
        return if frame == @last_frame
        @last_frame = frame

        rx, ry, rw, rh = Game::CharSet.frame_rect(@charset_index, @state.direction, pat)
        src = Rect.new(rx, ry, rw, rh)
        # A Flash Sprite aimed at the hero tones the frame as it is laid down
        # (update_sprite_flashes invalidates @last_frame each frame it runs, so
        # the fading colour is re-applied rather than baked in once).
        toned = @player_flash && flashed_charset(@charset, src, @player_flash)
        @player_bmp.clear
        if toned
          blt_bushed @player_bmp, 0, 0, toned,
                     Rect.new(0, 0, Game::CharSet::WIDTH, Game::CharSet::HEIGHT),
                     255, bush
        else
          blt_bushed @player_bmp, 0, 0, @charset, src, 255, bush
        end
      end

      # Lay down a character frame with its bottom `bush` pixel rows *sunk* into
      # the tile: those rows draw at half opacity, which is how RPG2000 shows a
      # character wading through tall grass or shallow water (下半身消去). A
      # `bush` of 0 is the ordinary one-blit case, and a depth that swallows the
      # whole frame (terrain bush_depth 3, 全身半透明) is one blit at the sunken
      # opacity rather than a split.
      def blt_bushed(bmp, dx, dy, src_bmp, src, opacity, bush)
        sunk = Game::CharSet.bush_opacity(opacity)
        if bush <= 0
          bmp.blt dx, dy, src_bmp, src, opacity
        elsif bush >= src.height
          bmp.blt dx, dy, src_bmp, src, sunk
        else
          top = src.height - bush
          bmp.blt dx, dy, src_bmp, Rect.new(src.x, src.y, src.width, top), opacity
          bmp.blt dx, dy + top, src_bmp,
                  Rect.new(src.x, src.y + top, src.width, bush), sunk
        end
      end

      # How many pixel rows of the hero's sprite the tile under the party sinks.
      # A jumping hero is *over* the tile rather than in it, and a boarded party
      # draws its vehicle instead of the hero, so neither sinks.
      def player_bush_depth
        return 0 if @player_jumping || @state.boarded?
        bush_pixels_at(@state.x, @state.y)
      end

      # The same for a map event, gated on the hero's own layer: an event drawn
      # below or above the party is scenery or a treetop rather than something
      # standing in the grass, which is the layer test RPG_RT makes too.
      # `height` is the frame the depth is scaled against — the 32px charset
      # frame for an ordinary event, one tile for a tile-graphic one.
      def event_bush_depth(e, height = Game::CharSet::HEIGHT)
        return 0 unless e[:layer] == 1
        return 0 if e[:jumping]
        ch = e[:char]
        Game::CharSet.bush_pixels(bush_depth_at(ch.x, ch.y), height)
      end

      def bush_pixels_at(x, y)
        Game::CharSet.bush_pixels(bush_depth_at(x, y))
      end

      # The terrain `bush_depth` under a tile (0 where the map, the chipset or
      # the database has no terrain to ask).
      def bush_depth_at(x, y)
        row = terrain_row_at(x, y)
        return 0 unless row && row.respond_to?(:bush_depth)
        row.bush_depth || 0
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

  end
end

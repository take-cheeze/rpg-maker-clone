class RPG2k
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
      # so Window falls back to a plain panel). Colour-keyed, matching the map
      # and title scenes' own loads of the same file: the skin's palette entry 0
      # is transparent, and every menu built on this would otherwise draw the
      # cursor and frame corners on opaque blocks.
      def make_windowskin
        name = @db.system.system_graphic
        return nil if name.nil? || name.empty?
        Bitmap.new "System/#{name}", true
      rescue StandardError => e
        $stderr.puts "[RGSS] windowskin load failed, using plain panel: #{e.message}"
        nil
      end

      # Full-screen backdrop for the field menu scenes (Menu and its Item/
      # Skill/Equip/Status sub-screens), which have no map of their own behind
      # them. RPG_RT fills the whole screen with the windowskin's own
      # background chip -- the same 32x32 tile every RPG2k::Window stretches
      # over its own interior, see Window#draw_background -- stretched over
      # the full 320x240 instead, so gaps between windows read as the same
      # material rather than showing whatever scene happens to sit underneath.
      # Given a nil skin (load failed) this is a plain black sprite, matching
      # Window's own fallback panel look. z sits above the map's own tiles,
      # characters, pictures and animations (Scene::Map tops out at 250 for
      # its picture layer) so none of them show through, but below its
      # screen-wide weather/flash/fade effects (430/450/500) and the menu's
      # own windows (400) -- Scene::Map is never popped while a menu sits on
      # top of it, so all of that keeps rendering regardless of scene.
      def build_field_background(skin)
        sprite = Sprite.new
        sprite.z = 300
        bmp = Bitmap.new(RPG2k::WIDTH, RPG2k::HEIGHT)
        if skin
          bmp.stretch_blt Rect.new(0, 0, RPG2k::WIDTH, RPG2k::HEIGHT), skin,
                          Rect.new(0, 0, 32, 32)
        else
          bmp.fill_rect 0, 0, RPG2k::WIDTH, RPG2k::HEIGHT, Color.new(0, 0, 0, 255)
        end
        sprite.bitmap = bmp
        sprite
      end

      # Draw `text` the way RPG_RT draws every piece of window text: a shadow
      # glyph one pixel down and right filled from the System image's shadow
      # block, then the glyph itself filled from colour `idx`'s 16x16 swatch, so
      # the text carries the windowskin's own gradient. Falls back to the flat
      # font colour when there is no windowskin (or the colour index is out of
      # range), which is all `draw_text` can do.
      def draw_system_text(bmp, x, y, w, h, text, skin, idx = 0, align = 0)
        unless skin && Game::MessagePalette.valid?(idx)
          bmp.draw_text x, y, w, h, text, align
          return
        end
        cell = Game::MessagePalette::CELL
        off = Game::MessagePalette::SHADOW_OFFSET
        shx, shy = Game::MessagePalette.shadow_origin
        bmp.blend_text x + off, y + off, w, h, text, skin, shx, shy, cell, cell,
                       align
        sx, sy = Game::MessagePalette.cell_origin(idx)
        bmp.blend_text x, y, w, h, text, skin, sx, sy, cell, cell, align
      end

      # The condition a battler carrying `states` shows, as [text, palette colour
      # index]: the significant state's name in its own colour, or the database's
      # "normal" term when there is none. A state the database does not name
      # falls back to its id, so an unnamed one still reads as *something* rather
      # than silently as normal.
      #
      # The single place the state table's display side is read, so the battle
      # status panel (which lays its own columns out and needs the pieces) and
      # the field windows (which draw straight) cannot drift apart.
      # The database's status-condition table (the `situation` array), or nil for
      # a scene built on a fixture database that has none.
      def state_table
        db.respond_to?(:situation) ? db.situation : nil
      end

      def state_display(states)
        table = state_table
        id = Game::States.significant(states, table)
        return [normal_status_term, 0] unless id
        [Game::States.name(id, table) || "state #{id}",
         Game::States.color(id, table)]
      end

      # Draw an actor's condition, as RPG_RT does in every field window that
      # shows one — the menu party list, the item / skill target list and the
      # status screen (EasyRPG's Window_Base#DrawActorState).
      def draw_actor_state(bmp, actor, x, y, w, h, skin, align = 0)
        text, color = state_display(actor.states)
        draw_system_text bmp, x, y, w, h, text, skin, color, align
      end

      # The database's word for "no condition" (RPG_RT shows it rather than
      # leaving the column blank), or a plain English stand-in for a database
      # that leaves the term unset.
      def normal_status_term
        term(:normal_status, 'Normal')
      end

      # `db.term.<name>`, or `fallback` when the field is blank or the scene is
      # built on a fixture database that carries no term table at all. Shared by
      # every scene that draws vocabulary the database lets a project rename
      # (menu commands, stat abbreviations, equipment slots, ...), so a bare or
      # partially-filled database still reads as English rather than blank.
      def term(name, fallback)
        t = db.respond_to?(:term) ? db.term : nil
        s = t && t.respond_to?(name) ? t.send(name) : nil
        nonblank(s, fallback)
      end

      # `s`, or `fallback` when `s` is nil/empty once stringified.
      def nonblank(s, fallback)
        s = s.to_s
        s.empty? ? fallback : s
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

      # Whether a jump may land on (x, y) — only the destination is tested, the
      # tiles crossed on the way are not (see Game::MoveRoute#do_jump).
      def can_land?(character, x, y)
        @scene.char_can_land?(character, x, y)
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
      rescue StandardError => e
        $stderr.puts "[RPG2k] event SE '#{name}' playback failed: #{e.message}"
        nil
      end

      def random(n)
        @rng.random(n)
      end
    end

    # The same `world` protocol as MapWorld, for a Move Event / Set Move Route
    # driving a vehicle (boat/ship/airship) rather than the hero or a map
    # event. Passability routes through Scene::Map#vehicle_passable? (terrain
    # boat_pass/ship_pass/airship_pass plus the vehicle-specific Through-Mode
    # event-blocking rule) instead of the hero's on-foot #char_passable? —
    # the only difference from MapWorld.
    class VehicleWorld
      def initialize(scene, rng, type)
        @scene = scene
        @rng = rng
        @type = type
      end

      def passable?(character, dir)
        @scene.vehicle_char_passable?(character, dir, @type)
      end

      def can_land?(character, x, y)
        @scene.vehicle_char_can_land?(character, x, y, @type)
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
      rescue StandardError => e
        $stderr.puts "[RPG2k] event SE '#{name}' playback failed: #{e.message}"
        nil
      end

      def random(n)
        @rng.random(n)
      end
    end

    # Resolves the command list a Call Event refers to. Common events are looked
    # up by id; a map event's page is fetched from the loaded map unit (best
    # effort — the page index follows the LCF page numbering).
    class EventResolver
      def initialize(common_by_id, map_events)
        @common = common_by_id || {}
        @map_events = map_events || {}
      end

      def common_event_commands(id)
        @common[id]
      end

      def map_event_commands(id, page_index)
        ev = @map_events[id]
        return nil unless ev
        pages = ev.pages
        return nil unless pages
        page = pages[page_index]
        page && page.event_commands
      rescue StandardError
        nil
      end
    end

  end
end

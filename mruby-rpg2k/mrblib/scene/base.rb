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

      # Slice `text` down to however many leading characters fit within `w`
      # pixels of `c`'s own font metrics, dropping the rest outright -- RPG_RT
      # truncates an overlong run rather than wrapping it. Walks one character
      # (not byte) at a time so a multi-byte codepoint is never split mid-way.
      #
      # Neither `Bitmap#draw_text` nor `#blend_text` (mruby-rgss/src/lib.cxx)
      # clip to the `w`/`h` they are given -- those only ever feed centre/right
      # alignment math -- so nothing stops an overflowing run from drawing
      # straight past its own column's boundary and onto whatever sits beyond
      # it. Originally written for the message window's face-graphic margin
      # (Scene::Map#draw_message_run, where an overflowing line used to draw
      # straight over the portrait instead of stopping at the text column's own
      # edge); shared here because the battle status panel's fixed name/state/
      # HP/MP columns (Scene::Battle#battle_status_window) hit the exact same
      # gap -- an oversized name or a 3-digit HP/MP pair drawing unclipped
      # straight into its neighbour's column, rather than the neighbour's own
      # text simply overlapping it.
      def clip_text_to_width(c, text, w)
        return '' if w <= 0
        return text if c.text_size(text).width <= w
        out = ''
        text.each_char do |ch|
          candidate = out + ch
          break if c.text_size(candidate).width > w
          out = candidate
        end
        out
      end

      # Greedily packs `text`'s whitespace-separated words into as many lines
      # as it takes to each fit within `w` px (measured via #text_size, the
      # current font) -- unlike #clip_text_to_width above, which drops
      # whatever doesn't fit, this keeps every word by wrapping onto the next
      # line instead. Written for the debug editors' key-binding hint lines
      # (Scene::MapViewer, Scene::ChipsetEditor): a single #draw_text call
      # neither wraps nor clips its own text (see #clip_text_to_width's own
      # comment), so a hint longer than one line's width used to run straight
      # off the bitmap's right edge and simply vanish there instead of
      # appearing at all. A single over-wide word (wider than `w` on its own)
      # still overflows its line -- this only ever breaks *between* words.
      def wrap_text_to_width(c, text, w)
        lines = []
        line = ''
        text.split(' ').each do |word|
          candidate = line.empty? ? word : "#{line} #{word}"
          if !line.empty? && c.text_size(candidate).width > w
            lines << line
            line = word
          else
            line = candidate
          end
        end
        lines << line unless line.empty?
        lines
      end

      # Draws `text` word-wrapped to `@contents`' own width (see
      # #wrap_text_to_width), one #draw_text call per line, each `line_h` px
      # apart starting at `y`.
      def draw_wrapped_hint(text, y, line_h)
        wrap_text_to_width(@contents, text, @contents.width).each_with_index do |line, i|
          @contents.draw_text 0, y + i * line_h, @contents.width, line_h, line
        end
      end

      # The screen size the native host actually configured (src/main.cxx sets
      # RPG2K_SCREEN_WIDTH/HEIGHT from the finalized --width/--height once the
      # XP/VX auto-detect override, if any, is resolved), never smaller than
      # RPG2000/2003's own fixed 320x240. Real gameplay scenes (Scene::Map and
      # everything built on top of it) must stay at that fixed resolution to
      # reproduce RPG_RT's own rendering -- they use RPG2k::WIDTH/HEIGHT
      # directly and always will -- but a debug-only authoring tool like
      # Scene::MapViewer has no such fidelity to protect, so there's no reason
      # for it to sit in a small corner of a window the user explicitly asked
      # to be bigger. Guarded the same way RPG2k#map_editor? is (see its own
      # comment): the CRuby-only host harnesses that load this file never
      # define RPG2K_SCREEN_WIDTH/HEIGHT, so an undefined reference here just
      # falls back to the fixed resolution, leaving every existing check's
      # behaviour unchanged.
      def screen_width
        [RPG2K_SCREEN_WIDTH, RPG2k::WIDTH].max
      rescue NameError
        RPG2k::WIDTH
      end

      def screen_height
        [RPG2K_SCREEN_HEIGHT, RPG2k::HEIGHT].max
      rescue NameError
        RPG2k::HEIGHT
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

      # RPG2000 system-sound slots (Change System SFX / 10670 stores overrides by
      # these indices; the same order backs the database defaults). Shared by
      # every scene that can play a system SE: Scene::Map (message choices,
      # Change System SFX, the battle-related slots) and the field menu screens
      # (Menu and its Item/Skill/Equip/Status/SaveLoad sub-screens).
      SFX_CURSOR = 0
      SFX_DECISION = 1
      SFX_CANCEL = 2
      SFX_BUZZER = 3
      # The slots keep the database's own order (System fields 41..52), so slot 4
      # is Battle Start and slot 5 Escape — the sound RPG_RT plays when someone
      # runs from a fight (Force Flee, 1006).
      SFX_BATTLE = 4
      SFX_ESCAPE = 5
      # The rest of that same run of fields (47..52): the per-hit sounds a fight
      # itself plays. Slot numbers keep counting up through the database's own
      # field order (field - 41) even for the one left unplayed below, since a
      # Change System SFX command's slot argument is that same raw index and has
      # to land on the right entry whichever slot it names -- skipping a number
      # here would silently mis-target every slot after it.
      SFX_ENEMY_ATTACK = 6
      SFX_ENEMY_DAMAGE = 7
      SFX_ACTOR_DAMAGE = 8
      SFX_DODGE = 9
      SFX_ENEMY_DEATH = 10
      SFX_ITEM = 11
      DB_SE_FIELD = { SFX_CURSOR => :cursor_se, SFX_DECISION => :decision_se,
                      SFX_CANCEL => :cancel_se, SFX_BUZZER => :buzzer_se,
                      SFX_BATTLE => :battle_se, SFX_ESCAPE => :escape_se,
                      SFX_ENEMY_ATTACK => :enemy_attack_se,
                      SFX_ENEMY_DAMAGE => :enemy_damaged_se,
                      SFX_ACTOR_DAMAGE => :actor_damaged_se,
                      SFX_DODGE => :dodge_se, SFX_ENEMY_DEATH => :enemy_death_se,
                      SFX_ITEM => :item_se }.freeze
      # `enemy_attack_se` (slot 6) is played from
      # Scene::Map#play_battle_action_se, gated on Battle#deal_attack's
      # `attacker_ally: false` (an enemy's own plain Attack, never a
      # skill/item hit -- EasyRPG's Game_BattleAlgorithm::Normal::GetStartSe
      # returns SFX_EnemyAttacks only for an enemy source, and only the
      # Normal algorithm ever returns it). Confirmed against EasyRPG Player's
      # source (scene_battle_rpg2k.cpp): ProcessBattleActionUsage plays
      # GetStartSe() before ProcessBattleActionAnimation and
      # ProcessBattleActionExecute -- the very start of the action, before
      # any sprite swing or hit/miss/damage resolution -- and, for a
      # repeated (dual-attack) action, ProcessBattleActionFinished re-enters
      # at Execute rather than Usage, so it plays once per action, not once
      # per swing (mirrored here by nilling `attacker_ally` on the dual
      # attack's second entry, see #enemy_basic_action).
      #
      # This build's round has no separate wind-up beat to hang that lead-in
      # on -- a plain attack still resolves hit/miss/damage in the one step
      # that builds the log entry -- so the SE plays at the top of
      # #play_battle_action_se for that entry, ahead of the dodge/damage/
      # death cues the same call already fires for it. That collapses
      # RPG_RT's swing-then-impact gap to nothing, but keeps the one thing
      # that gap is *for*: the attack cue is heard before, never alongside
      # or after, the resolution it precedes.

      # Play a system sound effect by slot, preferring a Change System SFX
      # override held on the game state and falling back to the database's own
      # sound. A no-op when neither names a file (or no audio backend is present),
      # or when this scene has no `@state` at all (a bare fixture instance built
      # without one, e.g. some host test harnesses).
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
        ov = @state && @state.respond_to?(:system_sfx) ? @state.system_sfx[slot] : nil
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

    # The battle scene class for a fight in `db`'s edition: the RPG2003 scene
    # (RPG2k3::Scene::Battle, mruby-rpg2k/mrblib/scene/battle_rpg2k3.rb) when
    # the database was authored in 2003, else the plain RPG2000 turn-based
    # scene. The 2003 scene subclasses the 2000 one and only overrides #update
    # to advance the active-time gauge when battle_type == 2, so routing every
    # 2003 fight through it is safe even for the traditional (0) and
    # alternative (1) presentations, which inherit the unchanged turn-based
    # machine. Referenced at call time (not load time), so the RPG2k3 constant
    # resolves however the files happen to be loaded.
    def self.battle_scene_class(db)
      if db.respond_to?(:rpg2003?) && db.rpg2003?
        RPG2k3::Scene::Battle
      else
        Battle
      end
    end
  end
end

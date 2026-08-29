class RPG2k
  module Scene
    # RPG2000's turn-based fight.
    #
    # RPG_RT runs an encounter as a scene of its own: `Scene_Battle` takes the
    # screen over from `Scene_Map` for as long as the fight lasts, which is why
    # its backdrop is all there is behind the troop and why no part of the map
    # is drawn beside it (as in a reference implementation, not independently
    # confirmed against genuine RPG_RT under wine). This port
    # used to run the same screen *inline on the map* instead, as a mode gated
    # on a `@battle_ui` hash living on Scene::Map -- some three thousand lines
    # of phase machine, windows, sprites, round animation and battle-event
    # pages sitting in the middle of the map scene, reachable only through that
    # one hash, and impossible to open from anywhere but a map.
    #
    # The fight is this scene now. Everything the fight itself is made of lives
    # here: the phase machine (#update), the command / skill / item / target
    # windows, the troop and party sprites, the per-action round animation, the
    # troop's own battle-event pages and the result screen.
    #
    # Scene::Map still owns the frame around it -- it keeps driving the screen
    # effects, pictures, timers and animations a fight can still show, and it
    # owns the interpreters whose Battle Processing command opened this fight
    # in the first place -- so it constructs this scene, hands it every frame
    # for as long as the fight is open (see Scene::Map#drive_battle) and tears
    # it down again (Scene::Map#close_battle). What stays the map's, and is
    # reached back into through `@map`, is listed under the "Services
    # Scene::Battle calls back into" heading at the end of scene/map.rb: the
    # graphic caches shared across encounters, the BGM stack that has to bring
    # the field track back afterwards, the battle-animation player a round's
    # skill / item animations share with the map's own Show Battle Animation
    # command, the Game Over teardown and the F9 debug menu.
    class Battle < Base
      SCREEN_W = RPG2k::WIDTH
      SCREEN_H = RPG2k::HEIGHT

      # `req` is the Battle Processing request that opened this fight
      # (`{ troop_id:, first_strike:, defeat_game_over:, ... }`), `owner` the
      # interpreter that raised it -- the map's foreground event by default, or
      # a Parallel Process's own interpreter for a fight it opened itself. The
      # owner is the one this scene hands its outcome back to (#finish), and
      # the one Scene::Map checks a frame against before handing it over, so
      # two interpreters racing for the single battle slot cannot drive each
      # other's fight.
      #
      # Nothing is built here: #start opens the fight (SE, BGM, troop, sprites,
      # the encounter banner) once the map has this scene in hand, since
      # opening one can immediately finish it again -- an empty or all-KO'd
      # party settles to a defeat on the spot -- and that has to be able to
      # reach back through the map.
      def initialize(map, req, owner)
        super map.parent
        @map = map
        @state = map.state
        @rng = map.rng
        @req = req
        @owner = owner
        # Graphic caches belong to the map visit, not to one encounter, so a
        # monster / backdrop / battler sheet decoded in one fight is still
        # warm for the next one on the same map (see Scene::Map's own
        # #cached_bitmap comment).
        @monster_cache = map.monster_cache
        @backdrop_cache = map.backdrop_cache
        @battlecharset_cache = map.battlecharset_cache
        @system2_cache = map.system2_cache
      end

      # `ui` is the fight's whole live state: phase, the Game::Battle model,
      # the combatant snapshots, cursors, windows and sprites. Read by
      # Scene::Map for the handful of things a running fight changes about the
      # map's own frame (a timer without the "run in battle" flag pauses, the
      # message window skips its open animation, the map layers are hidden).
      attr_reader :ui, :owner, :map

      # The map's windowskin rather than a copy taken at construction: a
      # Change System Graphic (10680) run from a battle event page reloads it
      # mid-fight (Scene::Map#reload_windowskin), and every window opened from
      # here on has to pick the new one up.
      def windowskin
        @map.windowskin
      end

      # Memoize a named graphic load, exactly like Scene::Map's own
      # #cached_bitmap (see there) -- duplicated rather than reached through
      # `@map.` since it touches nothing Map-specific, only the cache hash
      # (one of @monster_cache, @backdrop_cache, @battlecharset_cache,
      # @system2_cache, all shared with Scene::Map -- see #initialize) and
      # the key its own caller already resolved.
      def cached_bitmap(cache, key)
        return cache[key] if cache.key?(key)
        cache[key] = yield
      end

      # Advance the fight one frame: the flash/position/shake ticks every
      # in-play troop sprite needs regardless of phase, then dispatch on the
      # current phase to whichever `drive_battle_*` handler drives it (a
      # command menu, a target cursor, the skill/item sub-menus, the round
      # animation, the result screen, a running battle-event page, ...).
      #
      # Called from Scene::Map#drive_battle every frame this fight is the one
      # its calling interpreter owns (see there) -- never re-entered for a
      # *different* interpreter's own Battle Processing command while this
      # fight has the single battle slot, the same block-and-retry shape
      # Scene::Map already gives :message/:choice/:number.
      def update
        update_enemy_flashes
        update_enemy_positions
        update_enemy_shakes
        case @ui[:phase]
        when :encounter_message then drive_battle_encounter_message
        when :battle_options then drive_battle_options
        when :command     then drive_battle_command
        when :target      then drive_battle_target
        when :skill       then drive_battle_skill
        when :item        then drive_battle_item
        when :ally_target then drive_battle_ally_target
        when :animate     then drive_battle_animate
        when :result      then drive_battle_result
        when :event       then drive_battle_event
        end
        # F9 opens the debug menu mid-fight too -- the ordinary field-map call
        # site only ever runs once #event_busy? is fully clear, which a battle
        # never is, so this is the one place that reaches the check while a
        # fight is open.
        @map.try_open_debug_menu
      end

      def start
        # A reference implementation's battle-scene constructor
        # plays the database's Battle Start system SE (`SFX_BeginBattle`) as its
        # very first act, unconditionally and before even the battle BGM swap --
        # ported from that reference implementation, not independently confirmed
        # against genuine RPG_RT under wine.
        # `#play_system_se`/`SFX_BATTLE` already exist (Scene::Base's shared
        # system-SE table, `DB_SE_FIELD`), but nothing here ever called them for
        # this slot: Escape/dodge/damage/death/item all already fire at their
        # own moments (SFX_ESCAPE/SFX_DODGE/SFX_ENEMY_DAMAGE/SFX_ACTOR_DAMAGE/
        # SFX_ENEMY_DEATH/SFX_ITEM), only the battle-open moment itself was
        # silent.
        # Fires for every encounter this scene ever opens through -- a foreground
        # Enemy Encounter command, one issued from a Parallel Process, and a
        # random/wandering-monster encounter -- since #start is their one
        # shared entry point.
        play_system_se(SFX_BATTLE)
        @map.play_battle_bgm
        troop = Game::Troop.new(db, @req[:troop_id], @rng)
        allies = @state.party.actors.map { |a| Game::Battle.from_actor(a) }
        foes = troop.members.map { |e| Game::Battle.from_enemy(e) }
        # The database's state table drives per-turn afflictions (poison slip,
        # sleep skip) in battle.
        situations = db.respond_to?(:situation) ? db.situation : nil
        properties = db.respond_to?(:property) ? db.property : nil
        @ui = { phase: :command, troop: troop,
                       # Whether the Battle/Auto Battle/Escape options window
                       # has already shown its once-per-battle automatic
                       # appearance (see #enter_command_phase) -- distinct
                       # from `opt`, the cursor row inside it whenever it is
                       # open (set fresh by #start_options each time).
                       options_shown: false, opt: 0,
                       # `allies.dup`, not `allies` itself: `@ui[:allies]`
                       # below stays the exact same array Game::Battle is
                       # handed here would otherwise *be* -- Ruby arrays are
                       # mutable objects, so without the dup, deleting a
                       # departed member from the render-facing
                       # `@ui[:allies]` (#remove_battle_actor_sprite)
                       # would delete it from Game::Battle's own bookkeeping
                       # array too, breaking the rejoin-reuses-the-same-
                       # Combatant guarantee #sync_allies_from_party depends
                       # on (ADR 0050). The two arrays start with the same
                       # Combatant *objects* (so a lookup through either one
                       # sees the same battle-only state) but are free to
                       # diverge in which objects they each hold.
                       battle: Game::Battle.new(allies.dup, foes, @rng,
                                                situations, true, true, true,
                                                @req[:first_strike] ? true : false,
                                                properties,
                                                # Lets the troop run its 行動パターン:
                                                # skills, transformations and the
                                                # switch / party-level conditions.
                                                Game::EnemyAi.new(db, @state),
                                                # A negative attribute rank rate
                                                # (see #apply_attr_multiplier)
                                                # is handled differently per
                                                # edition.
                                                 rpg2003: db.respond_to?(:rpg2003?) && db.rpg2003?,
                                                 # RPG2003 battle timing
                                                 # presentation (Battle Setup
                                                 # chunk 0x1D field 7): 0
                                                 # traditional / 1 alternative /
                                                 # 2 gauge. Drives whether the
                                                 # active-time gauge engine
                                                 # (#advance_gauges) ever runs;
                                                 # RPG2000 has no battlecommands
                                                 # table, so this reads 0 and the
                                                 # turn-based machine is used.
                                                 battle_type: db.respond_to?(:battlecommands) && db.battlecommands ? (db.battlecommands.battle_type || 0) : 0,
                                                 # Mid-battle roster sync
                                                # (Game::Battle#sync_allies_from_party):
                                                # a Change Party Member command
                                                # run from a battle event page
                                                # mutates this same live
                                                # Game::Party, and the battle
                                                # re-derives its own @allies
                                                # from it every round/action
                                                # rather than staying pinned to
                                                # the `allies` snapshot taken
                                                # just above. The screen itself
                                                # (`@ui[:allies]`, the
                                                # status window, actor sprites)
                                                # follows the same change the
                                                # instant it happens instead --
                                                # see #on_battle_party_changed,
                                                # reached from
                                                # Interpreter#do_change_party
                                                # via `@ui[:events].
                                                # battle_screen` below.
                                                party: @state.party),
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
                       pages_run: {},
                       # Whether the just-drained #step_action entry finished
                       # its battler's whole action (see #drive_battle_animate),
                       # and which phase a running battle-event page resumes to
                       # once it finishes (see #run_battle_events).
                       battler_boundary: false, event_return_phase: :command,
                       # Frames elapsed since this battle opened -- cosmetic
                       # only (drives a levitating enemy's bob, #flying_offset),
                       # never read for any combat/save-affecting purpose, so
                       # it needs no seeding beyond starting at 0 every fight.
                       frame: 0 }
        @ui[:events].battle = @ui[:battle]
        # Lets a Change Party Member command run from a battle event page
        # (Interpreter#do_change_party) reach back into this screen the
        # moment it fires -- see #on_battle_party_changed. `@ui[:events]`
        # is the one interpreter ever running commands while a battle is open
        # (the foreground/parallel interpreters are held off by `event_busy?`/
        # `parallels_paused?` for as long as `@ui` exists), so this is
        # never set on any other interpreter.
        @ui[:events].battle_screen = self
        # A battle page can Call Common Event (1005), so it needs the same
        # resolver the encounter's own owning interpreter runs against --
        # the foreground by default, or a Parallel Process's own interpreter
        # for a fight it opened itself (see `owner` above).
        @ui[:events].resolver = @owner.resolver
        build_battle_sprites
        build_actor_sprites
        refresh_battle_status
        # --rpg2k_battle boot-drive marker (Scene::Map#headless_battle): fired
        # once, here, when the headless fight's whole UI -- backdrop, troop
        # sprites, actor sprites, the status panel -- is actually up, so
        # scripts/rpg2k_boot_check.bash can assert the battle path was really
        # reached rather than merely armed. A real encounter never sets
        # `headless`, so this line never appears for ordinary play.
        $stderr.puts "[RPG2k-BATTLE] troop=#{@req[:troop_id]}" if @req[:headless]
        # A reference implementation's battle scene narrates the encounter
        # before the party is ever asked for a command -- ported from that
        # reference implementation, not independently confirmed against
        # genuine RPG_RT under wine: one
        # `terms.encounter` line per visible (non-`hidden`) troop member
        # -- the active, "not dead or hidden" battlers --
        # each built by concatenating the enemy's own name in front of the
        # term (stock, non-Maniac-Patch phrasing: `subject + message`, no
        # placeholder), then,
        # if this encounter is a first-strike ambush
        # (`req[:first_strike]`, already threaded through to `Game::Battle`
        # above for the actual mechanic), a final fixed `terms.
        # special_combat` line with no name substitution -- pushed
        # *in addition to*, not instead of, the per-enemy lines, exactly as
        # real RPG_RT orders them. Nothing shows when the troop is entirely
        # hidden and the fight is not a first strike, matching the check
        # that gates the whole substate there.
        lines = battle_encounter_lines(troop, @req)
        if lines.empty?
          return if run_battle_events
          settle_already_finished_battle || enter_command_phase
        else
          show_battle_banner(lines)
          @ui[:phase] = :encounter_message
          @ui[:anim_timer] = BATTLE_ENCOUNTER_MSG_FRAMES
        end
      end

      # The encounter narration lines built above -- see #start's own
      # comment for the real-RPG_RT sourcing. Returns [] when there is
      # nothing to say (every troop member hidden, no first strike).
      def battle_encounter_lines(troop, req)
        lines = troop.members.reject(&:hidden).map do |enemy|
          "#{enemy.name}#{term(:encounter, ' appeared!')}"
        end
        lines << term(:special_combat, 'You get the first strike!') if req[:first_strike]
        lines
      end

      # How long the encounter banner lingers before the command phase opens.
      # A reference implementation paces this per-line with wordwrap and
      # per-page wait timers -- 4 frames before the first line,
      # 8 between lines that are not the page's last, and
      # a 30-skippable/70-full-frame wait (repeated again for the first-strike
      # line, when there is one) on whichever line ends a page -- and
      # holds the full wait of each of those unless the player
      # actively skips ahead. Ported from that reference implementation, not
      # independently confirmed against genuine RPG_RT under wine. This
      # screen has no per-page message window (see #battle_result_lines'
      # own comment on the same simplification), so the whole banner -- every
      # line at once -- holds for one flat beat instead. That beat used to
      # match only that reference's minimum 4-frame gate, not its real
      # per-line reading pause, which read as barely a flicker; 70 frames
      # (~1.2s) matches that reference's default no-skip hold on a single
      # encounter line instead -- long enough to actually
      # read the banner before the command menu takes over the same screen
      # rect, closer to (if still short of, for a troop with several enemies
      # or a first strike, both of which stack more such holds that
      # this one flat beat cannot represent) that reference's own pace.
      BATTLE_ENCOUNTER_MSG_FRAMES = 70

      # Drive the encounter-message phase: hold the banner for
      # `BATTLE_ENCOUNTER_MSG_FRAMES`, then drop it and fall into the same
      # turn-0-battle-event / command-phase flow #start used to reach
      # directly.
      def drive_battle_encounter_message
        if @ui[:anim_timer] > 0
          @ui[:anim_timer] -= 1
          return
        end
        close_battle_action
        @ui[:phase] = :command
        return if run_battle_events
        settle_already_finished_battle || enter_command_phase
      end

      # An encounter can start already decided — an empty party (every member
      # removed via Change Party Member) or one left all-KO'd from a prior
      # fight, with no revive in between, both read as no living ally at all.
      # `#draw_battle_command`'s `current_actor` (`living_allies[actor_i]`) is
      # nil either way, so it already declines to open a command window
      # (`return unless actor`) rather than crash — but nothing then moved the
      # battle on, since a round only ever starts once the player picks a
      # command for *some* actor. The command phase sat frozen forever, never
      # reaching the `battle.finished?` check `#finish_round_animation`/
      # `#leave_battle_event_phase` run after every other round, instead of
      # yado.tk's documented "battling with an empty party is instant defeat"
      # (worded the same way for an all-KO'd one). `Game::Battle#end_round`
      # is what actually computes `#result` (`alive?(@allies) ? :victory :
      # :defeat`); calling it here settles the same way an ordinary round
      # ending would, with nothing to clear (`@allies.each` no-ops on an empty
      # or already-KO'd roster). Returns whether it fired, so `#start`
      # only falls back to the normal command window when there is actually
      # someone to command.
      def settle_already_finished_battle
        battle = @ui[:battle]
        return false unless battle.finished?
        battle.end_round
        enter_battle_result(battle.result)
        true
      end

      # A troop member's sprite depth for its add-order index `i` (0-based).
      # RPG2000 numbers troop members by add-order and renders the
      # **lower**-numbered member closer to the camera (yado.tk); the native
      # renderer draws the *highest*-z sprite on top (see `gfx_update`'s own
      # "leaving the greatest z on top"), so index 0 needs the highest z here
      # -- the reverse of the add-order index itself.
      def battler_z(i)
        100 + (@ui[:troop].members.size - 1 - i)
      end

      # Vertical pixel bob for a levitating (`Game::Enemy#levitate`) troop
      # member, or 0 for everyone else. yado.tk only ever says the "airborne"
      # flag "changes its Y position on screen" with no magnitude or edition
      # given; a reference implementation's own flying-offset logic supplies
      # both missing facts and, more importantly, the edition gate the
      # yado.tk source never mentioned at all -- "2k does not support flying,
      # albeit mentioned in the help file" (a comment in that source).
      # Ported from that reference implementation, not
      # independently confirmed against genuine RPG_RT under wine. So a
      # genuine RPG2000 database's own `levitate` flag has no on-screen
      # effect whatsoever, by this account; only an RPG2003 one draws the
      # +/-4px, 256-frame-period sine bob
      # (`round(sin(2*PI*frame/256) * 4)`). Each member bobs on its own
      # randomized phase, not in lockstep -- `#flying_phase`'s own citation
      # confirms that reference implementation's `frame` is a *per-battler*
      # counter, independently
      # seeded 0..63 per battler at battle start, so `member.flying_phase`
      # (rolled once by `Game::Troop#initialize`) is added to this scene's
      # own shared per-frame tick, which still advances every member in
      # lockstep the way that reference implementation's battler update does.
      FLYING_AMPLITUDE = 4
      FLYING_PERIOD = 256
      def flying_offset(member)
        return 0 unless member.levitate && @state.party.rpg2003?
        frame = (@ui[:frame] || 0) + (member.flying_phase || 0)
        (Math.sin(2 * Math::PI * frame / FLYING_PERIOD.to_f) * FLYING_AMPLITUDE).round
      end

      # A troop member's on-screen y, centred on its database position and
      # nudged by #flying_offset -- shared by every site that (re)builds an
      # enemy sprite so the three stay in lockstep with the per-frame update
      # (#update_enemy_positions) that keeps a levitating one bobbing after.
      def battler_y(member, bmp)
        member.y - bmp.height / 2 + flying_offset(member)
      end

      # A troop member's sprite opacity: 160/255 (~63%) for one flagged
      # "Appear Transparent" (`Game::Enemy#transparent`, database field 10),
      # 255 (fully opaque) for everyone else -- ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT under
      # wine: alpha is scaled to 160/255 of its baseline, with that baseline held
      # at 255 since
      # this codebase has no death-fade/explode sprite animation to scale it
      # from. Purely cosmetic, no accuracy/evasion effect, same as
      # #flying_offset -- shared by every site that (re)builds an enemy sprite
      # so all three agree.
      TRANSPARENT_ENEMY_OPACITY = 160
      def battler_opacity(member)
        member.transparent ? TRANSPARENT_ENEMY_OPACITY : 255
      end

      # RPG2000 is a front-view battle: the enemy troop is drawn as sprites over a
      # battle background, while the party is represented by the status window (not
      # sprites). Build the backdrop and one sprite per visible troop member,
      # centred on its database position. Hidden (invisible) members get no sprite
      # until a battle event reveals them — already implemented: a battle
      # event's Show Hidden Monster command is picked up by
      # #apply_battle_event_requests, which calls #reveal_battle_monster for
      # each index in the event's revealed-monster list (see
      # #take_revealed_monsters), building the sprite on screen mid-battle.
      def build_battle_sprites
        build_battle_back(encounter_backdrop)
        @ui[:enemy_sprites] = @ui[:troop].members.each_with_index.map do |enemy, i|
          next nil if enemy.hidden
          bmp = battler_bitmap(enemy)
          spr = Sprite.new
          spr.bitmap = bmp
          spr.x = enemy.x - bmp.width / 2
          spr.y = battler_y(enemy, bmp)
          spr.z = battler_z(i)
          spr.opacity = battler_opacity(enemy)
          spr
        end
        # The battler (graphic name + hue) each sprite was drawn from, so a
        # transformation mid-fight is noticed and redrawn (see
        # #refresh_battle_sprites) -- matching a reference implementation's own
        # sprite refresh, which rebuilds on either changing.
        @ui[:sprite_names] = @ui[:foes].map { |f| f.battler_name }
        @ui[:sprite_hues] = @ui[:foes].map { |f| f.battler_hue || 0 }
        refresh_battle_sprites
      end

      # RPG2003's alternative/gauge battle layouts draw each party member as
      # a sprite too (unlike RPG2000's status-window-only layout -- see
      # Game::Party#alternate_battle_layout?), sourced from the database's
      # Battler Animation table (chunk 32, db.battleranimations). Idle,
      # Defend, Dead and "some other active state" are the poses
      # #build_actor_sprite picks between (ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT
      # under wine).
      # A fallen member still gets a sprite (the Dead pose, or Idle when the
      # entry defines no Dead pose of its own) rather than none at all -- the
      # party status window shows everyone regardless either way, so this
      # only changes what a downed member's own battler sprite looks like.
      # A traditional-layout database (or a bare test fixture whose party
      # doesn't even answer #alternate_battle_layout?) builds nothing,
      # matching current behaviour exactly.
      def build_actor_sprites
        @ui[:actor_sprites] = nil
        return unless @state.party.respond_to?(:alternate_battle_layout?) &&
                      @state.party.alternate_battle_layout?
        @ui[:actor_sprites] = @ui[:allies].each_with_index.map do |ally, i|
          build_actor_sprite(ally.actor, i, defending: ally.defending, dead: ally.dead?,
                             states: ally.states)
        end
      end

      # Idle, Dead and Defend pose ids within a `db.battleranimations` entry's
      # `poses` table (lcf::rpg::BattlerAnimation::Pose_Idle/Pose_Dead/
      # Pose_Defend -- schema.rb's own comment on chunk 32 lists the full
      # 12-pose order this is drawn from: 0 idle, 4 dead, 7 defend, among the
      # rest).
      # `ACTOR_BAD_STATUS_POSE` is the same shift applied to
      # `AnimationState_BadStatus` (7) -- the generic pose an active state
      # falls back to when its own `battler_animation_id` field (`Game::
      # States.animation_pose`) names none of its own, matching liblcf's own
      # schema default for that field (6, not the C++ side's raw
      # pre-translation sentinel 100 -- see `Game::States.animation_pose`'s
      # own comment).
      ACTOR_IDLE_POSE = 0
      ACTOR_DEAD_POSE = 4
      ACTOR_BAD_STATUS_POSE = 6
      ACTOR_DEFEND_POSE = 7
      # `poses[id].animation_type` values: 0 a BattleCharSet sprite sheet
      # (implemented below), 1 a full Battle/<name> (CBA) animation sequence
      # played in place of a static sprite (not implemented here -- see
      # #build_actor_sprite).
      ACTOR_POSE_TYPE_BATTLE = 1
      # A BattleCharSet sheet is framed in fixed 48x48 cells, one row per
      # `battler_index` (ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT under wine).
      ACTOR_CHARSET_CELL = 48
      # Clear of both the enemy troop's own z range (#battler_z's 100 +
      # troop_size-1 span) and the animation overlay's z 150, so an actor
      # sprite never fights either for draw order; still well below every UI
      # window (z >= 300).
      def actor_sprite_z(i)
        200 + i
      end

      # A party member's Idle-, Defend-, Dead- or active-state-pose sprite, or
      # nil when this step cannot draw one: `actor.battler_animation_id`
      # names no `db.battleranimations` entry (Game::Actor
      # #battler_animation_id already logs that diagnostic itself), the
      # resolved entry defines none of the candidate poses at all (silent --
      # an entry legitimately covering only some of the 12 poses is normal
      # authoring, not a dangling reference), or the pose uses the
      # `animation_type == 1` battle/CBA format this step does not implement
      # (logged below, matching this codebase's "reported gap, not silently
      # invented" convention for unimplemented behaviour).
      #
      # `defending:`/`dead:` select Pose id 7 (Defend) / 4 (Dead) over Idle
      # -- ported from a reference implementation, not independently
      # confirmed against genuine RPG_RT under wine, whose idle-animation
      # logic checks defending status first, ahead of everything else,
      # and whose monster branch (the one unambiguous case without a
      # `situation.battler_animation_id` table to consult at all) resolves
      # the Knockout state straight to the dead pose; a defeated
      # actor is treated the same way here rather than through its own
      # state's configurable pose (a real database's Death row conventionally
      # already points there anyway). Defending wins over dead, matching the
      # reference's check order, though the two never actually coincide (a
      # downed actor never has a command to defend with).
      #
      # Neither defending nor dead: a reference implementation's own
      # remaining branch -- falling back to the state's own animation pose,
      # or Idle when there is none --
      # ported from that reference implementation, not independently confirmed against
      # genuine RPG_RT under wine -- reads `states:` (the combatant's own
      # currently-active state ids, not
      # the field-side `Actor#states` this class never carries battle
      # ailments onto) for its highest-priority one
      # (`Game::States.significant`, already the exact port of
      # `GetSignificantState` this reads) and shows *that* state's own
      # configured pose (`Game::States.animation_pose`), falling back to the
      # generic "bad status" pose (`ACTOR_BAD_STATUS_POSE`) when the state
      # names none of its own, and further to plain Idle if even that pose is
      # missing from this entry or no state is significant at all.
      #
      # Every candidate pose alike falls back to Idle when the entry defines
      # no pose of its own for it, exactly like an entry with no Idle pose
      # falls back to no sprite at all: a partially-authored table is normal,
      # not an error.
      #
      # Position is either `battlecommands.placement` manual (0)'s raw
      # database `battle_x`/`battle_y` or
      # automatic (1)'s computed grid slot (#automatic_battle_position) --
      # ported from a reference implementation's
      # actual C++ source, not independently confirmed against genuine
      # RPG_RT under wine: it splits exactly this way there.
      def build_actor_sprite(actor, i, defending: false, dead: false, states: nil)
        anim_id = actor.respond_to?(:battler_animation_id) ? (actor.battler_animation_id || 0) : 0
        table = db.respond_to?(:battleranimations) ? db.battleranimations : nil
        entry = (table && anim_id > 0) ? table[anim_id] : nil
        return nil unless entry
        poses = entry.respond_to?(:poses) ? entry.poses : nil
        return nil unless poses
        pose_id = if defending && poses[ACTOR_DEFEND_POSE]
                    ACTOR_DEFEND_POSE
                  elsif dead && poses[ACTOR_DEAD_POSE]
                    ACTOR_DEAD_POSE
                  else
                    situations = db.respond_to?(:situation) ? db.situation : nil
                    sig = Game::States.significant(states, situations)
                    state_pose = sig && Game::States.animation_pose(sig, situations)
                    (state_pose && poses[state_pose]) ? state_pose : ACTOR_IDLE_POSE
                  end
        pose = poses[pose_id]
        return nil unless pose

        if pose.animation_type == ACTOR_POSE_TYPE_BATTLE
          label = { ACTOR_DEFEND_POSE => 'defend', ACTOR_DEAD_POSE => 'dead',
                    ACTOR_IDLE_POSE => 'idle' }.fetch(pose_id, 'state')
          $stderr.puts "[RPG2k] actor ##{actor.id}: #{label} pose " \
                       "uses a battle-animation (CBA) sheet, not a BattleCharSet -- not yet " \
                       "implemented, sprite not drawn"
          return nil
        end

        bmp = actor_battlecharset_bitmap(pose.battler_name)
        return nil unless bmp

        x, y = automatic_battle_position(i)
        if x.nil?
          # Manual placement: the database's own battle_x/battle_y.
          x = actor.respond_to?(:battle_x) ? (actor.battle_x || 0) : 0
          y = actor.respond_to?(:battle_y) ? (actor.battle_y || 0) : 0
        end

        spr = Sprite.new
        spr.bitmap = bmp
        spr.src_rect = Rect.new(0, (pose.battler_index || 0) * ACTOR_CHARSET_CELL,
                                ACTOR_CHARSET_CELL, ACTOR_CHARSET_CELL)
        spr.x = x
        spr.y = y
        spr.z = actor_sprite_z(i)
        spr
      end

      # -- automatic battler placement (`battlecommands.placement == 1`) --------
      #
      # Port of a reference implementation's grid-position calculation, not
      # independently confirmed against genuine RPG_RT under wine: when the database
      # asks for automatic placement, each party member's sprite sits on a grid
      # slot computed from its party index, the party size and the encounter's
      # terrain (the `grid_top_y` / `grid_elongation` / `grid_inclination`
      # database-terrain fields 46-48), instead of the manual battle_x/battle_y.
      # Only grid table 0 is used -- the ordinary actor path indexes table_x 0
      # and table_y 0 (the other tables are the pincer/surround enemy paths this
      # runtime does not model). `row_x_offset` reads the `i`-th ally's own
      # row (`Combatant#back_row?`, ADR 0053 -- the in-battle Row command is
      # what actually moves it off the front-row default): a half-width for
      # front, 0 for back, exactly the reference implementation's own
      # front-row-gets-half-width, back-row-gets-zero rule.
      #
      # Returns [x, y] for the `i`-th member of `@ui[:allies]`, or nil when
      # the database asks for manual placement (the caller falls back to
      # battle_x/battle_y) or the party outgrows the reference grid (8 rows).
      def automatic_battle_position(i)
        return nil unless @state.party.respond_to?(:automatic_battle_placement?) &&
                          @state.party.automatic_battle_placement?
        pos = battle_grid_position(i, @ui[:allies].length)
        return nil unless pos
        half = ACTOR_CHARSET_CELL / 2
        ally = @ui[:allies][i]
        row_x_offset = ally && ally.back_row? ? 0 : half
        # The reference implementation's actor-path x/y for the normal battle condition, then the
        # same x clamp (y is deliberately unclamped for actors -- the
        # reference doesn't).
        x = SCREEN_W - (pos[0] + half + row_x_offset)
        y = pos[1] - half
        [Game.clamp(x, half, SCREEN_W - half), y]
      end

      # The reference implementation's grid table 0
      # -- the only table the ordinary actor path indexes (table_x 0, table_y
      # 0), one row per party size, one fraction per member index.
      GRID_TABLE_0 = [
        [0.5],
        [0.0, 1.0],
        [0.0, 0.5, 1.0],
        [0.0, 0.33, 0.66, 1.0],
        [0.0, 0.25, 0.5, 0.75, 1.0],
        [0.0, 0.0, 0.5, 0.5, 1.0, 1.0],
        [0.0, 0.25, 0.33, 0.5, 0.66, 0.75, 1.0],
        [0.0, 0.0, 0.33, 0.33, 0.66, 0.66, 1.0, 1.0]
      ].freeze
      # The reference implementation's no-terrain defaults (the editor's
      # database-terrain fields default to 0 / 375 / 16400, but the reference falls back to these when
      # no terrain is named, not to the editor defaults).
      GRID_TOP_Y_DEFAULT = 112
      GRID_ELONGATION_DEFAULT = 392
      GRID_INCLINATION_DEFAULT = 16000

      # The grid slot for the `i`-th of `party_size` members, or nil when the
      # party outgrows the table. Integer-truncated like the reference's
      # `(int)` casts.
      def battle_grid_position(i, party_size)
        row = GRID_TABLE_0[party_size - 1]
        return nil unless row && row[i]
        t = row[i]
        grid = battle_grid_params
        x = ((1.0 - t) * (grid[:inclination] / 1000.0)).to_i
        y = grid[:top_y] + (Math.sin(grid[:elongation] / 1000.0) * 120.0 * t).to_i
        [x, y]
      end

      # The encounter terrain's grid fields (database terrain chunks 46-48), or
      # the reference implementation's no-terrain defaults when the party's tile names no terrain.
      def battle_grid_params
        tid = @map.respond_to?(:terrain_id) ? @map.terrain_id(@state.x, @state.y) : 0
        row = tid && tid > 0 && db.respond_to?(:terrain) && db.terrain ? db.terrain[tid] : nil
        return { top_y: GRID_TOP_Y_DEFAULT, elongation: GRID_ELONGATION_DEFAULT,
                 inclination: GRID_INCLINATION_DEFAULT } unless row
        { top_y: row.respond_to?(:grid_top_y) ? (row.grid_top_y || 0) : 0,
          elongation: row.respond_to?(:grid_elongation) ? (row.grid_elongation || 0) : 0,
          inclination: row.respond_to?(:grid_inclination) ? (row.grid_inclination || 0) : 0 }
      end

      # Interpreter#do_change_party's hook (via `@ui[:events].
      # battle_screen`, set in #start) for a Change Party Member battle
      # event that actually added or removed a member -- mirrors a reference
      # implementation's party-change hook running synchronously, right when the
      # party changes, rather than leaving the screen to notice on some later
      # redraw. `actor` is the `Game::Actor` (from `Game::Party#roster`, so it
      # resolves the same whether they are still a member or just left).
      # `Game::Battle`'s own roster (`@ui[:battle]`) is left alone --
      # its `sync_allies_from_party`/`out_of_play?`/`member` bookkeeping
      # (ADR 0050) already reads correctly from the live party on its own
      # schedule; this only updates what's drawn.
      def on_battle_party_changed(actor, added)
        return unless @ui
        added ? add_battle_actor_sprite(actor) : remove_battle_actor_sprite(actor)
        refresh_battle_status
      end
      public :on_battle_party_changed

      # An actor just (re)joined the fight: reuse their existing `Combatant`
      # if `Game::Battle` already has one (they left and are rejoining this
      # same fight, so the reused object keeps its accumulated battle-only
      # state -- the same reuse-on-rejoin guarantee ADR 0050 gives the
      # mechanics), or build a fresh one exactly the way
      # `Game::Battle#sync_allies_from_party` would on its own next sync --
      # pushed onto `@ui[:battle].allies` (not just returned) so that
      # later sync finds it already there and reuses it too, rather than the
      # render layer and the battle ending up tracking two different
      # `Combatant` objects for the same actor.
      def add_battle_actor_sprite(actor)
        battle = @ui[:battle]
        combatant = battle.ally_by_actor_id(actor.id)
        unless combatant
          combatant = Game::Battle.from_actor(actor)
          battle.allies.push(combatant)
        end
        return if @ui[:allies].any? { |c| c.equal?(combatant) }
        @ui[:allies].push(combatant)
        return unless @ui[:actor_sprites]
        i = @ui[:allies].length - 1
        @ui[:actor_sprites].push(build_actor_sprite(combatant.actor, i, defending: combatant.defending, dead: combatant.dead?, states: combatant.states))
        reset_actor_battler_z
      end

      # An actor just left the fight: drop their `Combatant` from the
      # render-facing `@ui[:allies]` (not from `Game::Battle`'s own
      # roster -- see #on_battle_party_changed) and dispose their specific
      # sprite, leaving every other actor's sprite untouched. A rejoin later
      # builds a brand new sprite (#add_battle_actor_sprite always calls
      # #build_actor_sprite fresh); this never leaves a disposed `Sprite`
      # sitting in the collection for that to reuse.
      def remove_battle_actor_sprite(actor)
        idx = @ui[:allies].index { |c| c.actor && c.actor.id == actor.id }
        return unless idx
        @ui[:allies].delete_at(idx)
        sprites = @ui[:actor_sprites]
        return unless sprites
        dispose_battle_sprite(sprites.delete_at(idx))
        reset_actor_battler_z
      end

      # `combatant`'s row, Defend or Dead status just changed and its
      # on-screen alternate-layout sprite needs to catch up -- the new
      # automatic-placement X (`#automatic_battle_position`'s `row_x_offset`)
      # for a row change, or the Idle/Defend/Dead pose #build_actor_sprite
      # picks between otherwise -- rebuilt in place at the same index/Z, the
      # same dispose-then-#build_actor_sprite-fresh shape
      # #remove_battle_actor_sprite/#add_battle_actor_sprite already use for
      # a roster change. A no-op when the fight draws no actor sprites at
      # all (a traditional-layout database); manual placement's row_x_offset
      # is a no-op too, since its `battle_x`/`battle_y` never depend on row
      # (see `Combatant.from_actor`'s own row comment) -- only the pose can
      # still change there.
      def reposition_actor_sprite(combatant)
        sprites = @ui[:actor_sprites]
        return unless sprites
        i = @ui[:allies].index { |c| c.equal?(combatant) }
        return unless i && sprites[i]
        dispose_battle_sprite(sprites[i])
        sprites[i] = build_actor_sprite(combatant.actor, i, defending: combatant.defending, dead: combatant.dead?, states: combatant.states)
      end

      # Re-derive every surviving actor sprite's Z from its current index in
      # `@ui[:allies]` (#actor_sprite_z). An add or remove elsewhere in
      # the roster shifts everyone after it, so without this, two sprites can
      # end up sharing a Z once enough adds/removes have happened -- e.g.
      # remove index 1 of 3 (leaving index 2's sprite still at its old Z 202),
      # then add a new member at the new index 2, which would also compute Z
      # 202. Matches a reference implementation's own battler-Z reset, called
      # for the same reason right after a party change adds a sprite.
      def reset_actor_battler_z
        sprites = @ui[:actor_sprites]
        return unless sprites
        sprites.each_with_index { |spr, i| spr.z = actor_sprite_z(i) if spr }
      end

      # The BattleCharSet bitmap for an actor pose's `battler_name`, cached
      # like every other named battle graphic (see #cached_bitmap) and
      # colour-keyed the same way CharSet/Monster are. A missing/empty name
      # or a failed load draws the same solid placeholder block
      # #battler_bitmap falls back to for a missing enemy graphic (see
      # #placeholder_battler), sized to one BattleCharSet cell so the
      # src_rect crop in #build_actor_sprite still makes sense against it.
      def actor_battlecharset_bitmap(name)
        key = (name && !name.empty?) ? name : nil
        cached_bitmap(@battlecharset_cache, key) do
          if key
            begin
              Bitmap.new("BattleCharSet/#{name}", true)
            rescue StandardError => e
              $stderr.puts "[RPG2k] actor battler '#{name}' load failed: #{e.message}"
              actor_placeholder_battler
            end
          else
            actor_placeholder_battler
          end
        end
      end

      def actor_placeholder_battler
        bmp = Bitmap.new(ACTOR_CHARSET_CELL, ACTOR_CHARSET_CELL)
        bmp.fill_rect 0, 0, ACTOR_CHARSET_CELL, ACTOR_CHARSET_CELL, Color.new(180, 60, 60, 255)
        bmp
      end

      # Where a battle-event page's message panel sits when the database is
      # RPG2003 -- the top of the screen. Ported from a reference
      # implementation, not independently confirmed against genuine RPG_RT under
      # wine: while a battle is running, the message position resolves to
      # position 2 (bottom) for an
      # RPG2000 database, position 0 (top) for RPG2003 -- overriding any
      # Message-Options position entirely.
      # That is a pure
      # database-edition check, unrelated to
      # `battle_type`/gauge mode. See `#battle_text_window`, which picks
      # between this and the bottom (`BATTLE_PANEL_Y`, content-height
      # adjusted) by `@state.party.rpg2003?`.
      BATTLE_EVENT_MSG_Y = 8

      # The backdrop this encounter fights over. Enemy Encounter's own param2
      # selector can override the ordinary map/terrain default per fight,
      # read from a reference implementation's actual C++ source rather than
      # assumed -- ported from that reference implementation, not
      # independently confirmed against
      # genuine RPG_RT under wine: the enemy-encounter command handler sets
      # `args.background` to the
      # command's own string literal for param2==1, or `args.terrain_id` to an
      # explicit terrain id (param8) for param2==2 -- `Interpreter
      # #do_enemy_encounter` threads these onto `@battle_request` as
      # `:background`/`:terrain_id`. An explicit background name wins outright
      # (the battle spriteset's constructor uses it when non-empty, else
      # falls back to the terrain-based background); an
      # explicit terrain id reads straight off that terrain's own row --
      # bypassing the
      # map-tree walk entirely, unlike the ordinary default below. Only when
      # neither key is present (param2==0, the ordinary case) does this fall
      # back to whatever `Game::Backdrop` resolves for the current map, given
      # the terrain the party is standing on. '' when nothing names one, which
      # draws the flat field.
      def encounter_backdrop
        return @req[:background].to_s if @req.key?(:background)
        return @map.backdrop_for_terrain_id(@req[:terrain_id]) if @req.key?(:terrain_id)
        Game::Backdrop.name_for(@state.map_id, @map.map_properties,
                                @map.terrain_backdrop(@state.x, @state.y))
      end

      def build_battle_back(name = nil)
        bmp = battle_back_bitmap(name)
        spr = Sprite.new
        spr.bitmap = bmp
        spr.z = 5
        # The map layer the screen tone rides on is hidden for the fight, so
        # seed the backdrop with the live map tone -- otherwise a Tint Screen
        # already active when the encounter opened would reach the (hidden)
        # map and not the one element on screen until the tint next changes.
        # #update_map_tone keeps it in lockstep thereafter.
        spr.tone = @map.current_map_tone if @map.respond_to?(:current_map_tone)
        @ui[:back_sprite] = spr
      end

      # Mirror the map layer's screen tone onto the battle backdrop. The
      # backdrop is a top-level sprite, not a child of the toned
      # @map_viewport, so a Change Screen Tone active during a fight would
      # otherwise only reach the (hidden) map and skip the one element on
      # screen. A reference implementation tints the battle background under
      # a Tint Screen -- ported from
      # that reference implementation, not independently confirmed against genuine RPG_RT
      # under wine -- so #update_map_tone
      # calls this whenever the tint changes and #build_battle_back seeds it
      # on build.
      def apply_backdrop_tone(tone)
        spr = @ui[:back_sprite]
        spr.tone = tone if spr
      end

      # The battle backdrop: the Backdrop/<name> image a Change Battle Background
      # command (or the encounter) named, falling back to the flat colour field
      # when there is no name or the file is missing — the same fallback the map
      # uses for a missing chipset. Cached by name (see #cached_bitmap) so
      # re-entering the same encounter, or a battle event that swaps back to a
      # backdrop already shown this visit, does not re-decode it.
      def battle_back_bitmap(name)
        key = (name && !name.empty?) ? name : nil
        cached_bitmap(@backdrop_cache, key) do
          if key
            begin
              Bitmap.new("Backdrop/#{key}")
            rescue StandardError => e
              $stderr.puts "[RPG2k] battle backdrop '#{key}' failed to load: #{e.message}"
              flat_battle_back
            end
          else
            flat_battle_back
          end
        end
      end

      def flat_battle_back
        bmp = Bitmap.new(SCREEN_W, SCREEN_H)
        bmp.fill_rect 0, 0, SCREEN_W, SCREEN_H, Color.new(16, 16, 32, 255)
        bmp
      end

      # Change Battle Background (13210): swap the backdrop mid-fight, releasing
      # the sprite and bitmap the old one held.
      def rebuild_battle_back(name)
        dispose_battle_sprite(@ui[:back_sprite])
        @ui[:back_sprite] = nil
        build_battle_back(name)
      end

      # The battler graphic for `enemy` (Monster/<battler_name>, colour-keyed), or
      # a solid placeholder block when it has no graphic or the file is missing —
      # the same fallback strategy the map uses for a missing chipset. Cached by
      # name+hue (see #cached_bitmap) so a monster reused across troop slots, or a
      # transformation that returns to a battler already shown this visit, is
      # decoded (and hue-rotated) once. The hue rotation (database field 3, see
      # `Game::Enemy#battler_hue`) is applied to this decode alone, never to a
      # cached bitmap already shared by a same-named, differently-hued sibling —
      # `Bitmap#hue_change` (`mruby-rgss/src/lib.cxx`) mutates in place, so the
      # cache key must fold hue in rather than rotate a shared entry.
      def battler_bitmap(enemy)
        name = enemy.battler_name
        hue = enemy.respond_to?(:battler_hue) ? (enemy.battler_hue || 0) : 0
        key = (name && !name.empty?) ? "#{name}\0#{hue}" : nil
        cached_bitmap(@monster_cache, key) do
          if key
            begin
              bmp = Bitmap.new("Monster/#{name}", true)
              bmp.hue_change(hue) if hue != 0
              bmp
            rescue StandardError => e
              $stderr.puts "[RPG2k] battler load failed for #{enemy.name}: #{e.message}"
              placeholder_battler
            end
          else
            placeholder_battler
          end
        end
      end

      def placeholder_battler
        bmp = Bitmap.new(32, 32)
        bmp.fill_rect 0, 0, 32, 32, Color.new(180, 60, 60, 255)
        bmp
      end

      # Decay any in-flight target-scope Battle Animation flash (#fire_target_flash)
      # by one frame. RGSS's native Sprite#flash bakes its colour into the
      # composite and fades it linearly, but only when driven by an explicit
      # Sprite#update each frame (mruby-rgss/src/lib.cxx) -- the same contract
      # #update_map_tone already drives on @map_viewport/@upper_viewport, just
      # for the per-enemy sprites instead of a viewport tone. A sprite with no
      # flash in flight costs nothing here (native #update no-ops).
      def update_enemy_flashes
        (@ui[:enemy_sprites] || []).each { |s| s.update if s }
      end

      # Advance the per-battle frame counter #flying_offset reads and re-seat
      # any levitating troop member's sprite at its new bob height. A no-op
      # (bar the counter tick) for a plain RPG2000 fight or a troop with no
      # `levitate` member: #flying_offset already reads 0 for both, so the
      # assignment below is just re-writing the same y already set.
      def update_enemy_positions
        @ui[:frame] = (@ui[:frame] || 0) + 1
        sprites = @ui[:enemy_sprites]
        return unless sprites
        @ui[:troop].members.each_with_index do |member, i|
          spr = sprites[i]
          next unless spr && member.levitate
          spr.y = battler_y(member, spr.bitmap)
        end
      end

      # Show a living enemy's sprite, hide a defeated one — called after each
      # animated action so a downed enemy vanishes from the field.
      def refresh_battle_sprites
        sprites = @ui[:enemy_sprites]
        return unless sprites
        # A transformation swaps a monster's graphic mid-fight, so redraw any
        # combatant no longer wearing the battler its sprite was built from
        # before deciding what is visible.
        names = (@ui[:sprite_names] ||= [])
        hues = (@ui[:sprite_hues] ||= [])
        @ui[:foes].each_with_index do |foe, i|
          changed = names[i] != foe.battler_name || hues[i] != (foe.battler_hue || 0)
          next unless changed
          rebuild_battler_sprite(i, foe) if sprites[i]
          # Recorded here rather than only inside #rebuild_battler_sprite, so a
          # transformed slot with no sprite object to rebuild (a bare fixture,
          # say) still stops re-triggering this every frame.
          names[i] = foe.battler_name
          hues[i] = foe.battler_hue || 0
          # The battler swap is this method's only signal that a Transform ran
          # (Game::Battle#enemy_transform_action updates the combatant's stats
          # including battler_name/hue, but has no other hook into the scene) --
          # sync the troop's own Enemy object's reward fields off it too, same
          # as #total_exp/#total_gold/#drops' `hidden` mirroring a few lines
          # below.
          sync_troop_member_rewards(i, foe)
        end
        @ui[:foes].each_with_index do |foe, i|
          spr = sprites[i]
          # Out of play, not merely dead: a monster that has fled (its own Escape
          # action, or a page's Force Flee) or one still flagged invisible is off
          # the field and must not be drawn — the same test #living_foes uses to
          # keep it out of the target cursor.
          spr.visible = !foe.out_of_play? if spr
          # A combatant hidden by anything other than a battle page's own Force
          # Flee (its own Escape action, or self-destruct -- Game::Battle#
          # enemy_autodestruct) never runs through #remove_fled_monster, so
          # mirror it onto the *troop* member here. #total_exp/#total_gold/
          # #drops key off the troop member's own `hidden`, not the combatant's
          # -- without this they would still pay out for a monster that never
          # actually died this fight.
          member = @ui[:troop].members[i]
          member.hidden = true if member && foe.hidden && !member.hidden
        end
      end

      # Redraw troop slot `i` with `foe`'s current battler graphic, keeping its
      # place and depth, and release the sprite and bitmap the old one held.
      #
      # This is only ever reached for an actual Transform (see
      # #refresh_battle_sprites' own comment: a battler_name/hue change is
      # its one signal that one ran), so the near-white flash a reference
      # implementation plays at the moment of the swap belongs here too. Ported
      # from that reference implementation's actual C++ source, not
      # independently confirmed against
      # genuine RPG_RT under wine: it
      # transforms the enemy then flashes it white (31,31,31,31,20)
      # right after the swap, unconditionally
      # -- this codebase's own prior fix for this same behaviour (see the
      # `#enemy_transform_action` doc comment) quoted the reference's
      # HP/SP-clamp behaviour but stopped short of this second step,
      # so the swap itself has always been a silent instant cut rather than
      # this recognisable flash-of-light cue. Scaled by the same 0..31
      # to 0..255 convention `Interpreter::FLASH_SCALE`/#fire_target_flash
      # already use for a raw RGSS `Color`.
      def rebuild_battler_sprite(i, foe)
        sprites = @ui[:enemy_sprites]
        member = @ui[:troop].members[i]
        return unless member
        old = sprites[i]
        bmp = battler_bitmap(foe)
        spr = Sprite.new
        spr.bitmap = bmp
        spr.x = member.x - bmp.width / 2
        spr.y = battler_y(member, bmp)
        spr.z = battler_z(i)
        spr.opacity = battler_opacity(member)
        spr.visible = !foe.out_of_play?
        spr.flash(Color.new(31 * 8, 31 * 8, 31 * 8, 31 * 8), 20)
        sprites[i] = spr
        dispose_battle_sprite(old)
      end

      # A Transform repoints the combatant at a new database enemy row
      # (#enemy_transform_action already updates its combat stats), but the
      # troop's own Enemy object at the same slot -- the one #total_exp/
      # #total_gold/#drops actually read exp/gold/drop_id/drop_prob from,
      # entirely separate from the Combatant this scene fights with -- is
      # never told: a reference implementation's own transform logic
      # repoints a single backing data pointer, so every accessor, combat and
      # reward alike, reads the new monster from that one point on; this port
      # keeps two parallel objects for one troop slot instead, and only the
      # combat side was ever kept in sync. Re-seeds the troop member's reward
      # fields (position/levitate/hidden are untouched -- a Transform keeps
      # its place, and never revives a hidden member) from a fresh
      # `Game::Enemy` built off the combatant's own already-updated
      # `enemy_id`, the identical constructor `EnemyAi#enemy` used to resolve
      # what the combatant just turned into.
      def sync_troop_member_rewards(i, foe)
        member = @ui[:troop].members[i]
        return unless member && foe.respond_to?(:enemy_id) && foe.enemy_id
        member.reseed_rewards(Game::Enemy.new(db, foe.enemy_id))
      end

      def living_allies; @ui[:allies].reject(&:dead?); end

      # Allies selectable as a manually-chosen Battle Item target right now.
      # Unlike a skill target (still `#living_allies` below -- a reference
      # implementation's own dead-target handling for skills is a materially
      # larger state machine this fix does not touch), an item target is
      # drawn from the *whole* roster, dead members included: a reference
      # implementation puts the status window into an "all" choice mode for
      # a single-target medicine or
      # an ally-scope skill, and validating that mode is an
      # unconditional pass -- nothing
      # there excludes a KO'd party member. This picker used to start from
      # `#living_allies` instead, so a 蘇生専用 (`ko_only`) revive item could
      # never even be aimed at the ally it was meant to revive. Then narrowed
      # by the pending item's own 使用可能キャラ (`actor_set`) restriction
      # when there is one -- the same per-recipient gate `Game::Party#
      # use_medicine` already applies in the field menu (`Game::Party#
      # item_usable_by?`), which this picker had never consulted at all, so a
      # party member the item cannot affect used to be offered as a choice
      # anyway rather than not appearing in the first place. `@state.party`
      # not answering `item_usable_by?` (a battle test's stub party, which
      # never models equipment restrictions) degrades to "unrestricted", the
      # same default the real method itself falls back to for an item with no
      # actor_set at all.
      def battle_ally_targets
        return living_allies unless pending_kind == :item
        allies = @ui[:allies]
        return allies unless @state.party.respond_to?(:item_usable_by?)
        it = @ui[:pending] && @ui[:pending][:it]
        return allies unless it
        allies.select { |a| a.actor.nil? || @state.party.item_usable_by?(it, a.actor.id) }
      end
      # Targetable foes: alive *and* in play, so a troop member still flagged
      # invisible never appears in the target cursor.
      def living_foes;   @ui[:foes].reject(&:out_of_play?); end
      def current_actor; living_allies[@ui[:actor_i]]; end

      # The real Game::Actor behind the current battler (the snapshots are built
      # from the party in order), so the Skill menu can read its known skills.
      def current_actor_row
        idx = @ui[:allies].index(current_actor)
        idx ? @state.party.actors[idx] : nil
      end

      # The per-actor commands, in menu order (the cursor row is 1 + index,
      # below the actor-name header): each a `{ label:, action:,
      # command_id: }` pair, drawn by `#battle_commands` below and dispatched
      # by `#select_battle_command`. `command_id` is the ref into the
      # database's Battle-Commands table (`db.battlecommands.commands`) the
      # row came from -- the fixed four map to a reference implementation's
      # default command ids 1..4 (attack, skill, defense, item), not
      # independently confirmed against genuine RPG_RT under wine, a
      # customized list to its own
      # refs -- which the scene records onto the acting Combatant when the
      # row is chosen, for the RPG2003 battle combo and the battle-page
      # `command_actor` condition.
      #
      # An acting actor whose own RPG2003 battle-command list
      # (`Game::Actor#battle_commands`, edited by Change Battle Commands (1009)
      # or a class change) resolves to at least one usable entry drives the
      # menu; otherwise this falls back to the fixed **Attack, Skill, Defend,
      # Item** four — a reference implementation builds that exact array,
      # not the Item-before-Defend order
      # this used to assume, read from the database's battle-command terms with
      # the standard RPG2k labels as fallback. The Skill slot is not memoized:
      # it substitutes the acting actor's own RPG2000 rename
      # (`#skill_command_label` below) when the database sets one, so it can
      # change from one actor's turn to the next.
      #
      # The fixed-four ids (1 attack, 2 skill, 3 defense, 4 item) are
      # a reference implementation's own default command ids, not
      # independently confirmed against genuine RPG_RT under wine, which
      # builds exactly these four
      # entries in this order for an actor with no customized list -- the same
      # ids a real 2003 database's own Battle-Commands table conventionally
      # numbers its first four entries, and the ids the Enable Combo (1007)
      # command and the `command_actor` page condition refer to.
      #
      # RPG2003 also appends a fixed **Row** row after whichever list this
      # resolves to (#row_command_available?), the front/back toggle
      # (`#select_battle_command`'s `:row` arm) -- not itself a Battle-
      # Commands table entry (see #custom_battle_commands' own comment on why
      # id 0 is skipped there), so it always carries a nil `command_id`.
      def battle_command_rows
        actor = current_actor_row
        custom = actor && custom_battle_commands(actor)
        rows = custom || [
          { label: term(:battle_attack, 'Attack'), action: :attack, command_id: 1 },
          { label: skill_command_label, action: :skill, command_id: 2 },
          { label: term(:battle_defend, 'Defend'), action: :defend, command_id: 3 },
          { label: term(:battle_item, 'Item'), action: :item, command_id: 4 }
        ]
        rows += [{ label: term(:row, 'Row'), action: :row, command_id: nil }] if row_command_available?
        rows
      end

      # RPG2003's Row entry is not one of the customizable Battle-Commands
      # list's own rows -- per the fixed-four list above and per a reference
      # implementation's own comment marking it "not impl"
      # there too (ported from that reference implementation, not independently
      # confirmed against genuine RPG_RT under wine) -- it is a fixed extra
      # row that reference implementation appends after
      # whatever list a project customized, present on every RPG2003 fight
      # (that reference implementation's own row-disabling opt-out is an
      # editor-only extension with no real LCF field, so there is
      # nothing for a vanilla database to gate this on beyond the edition).
      def row_command_available?
        @ui[:battle] && @ui[:battle].respond_to?(:rpg2003?) && @ui[:battle].rpg2003?
      end

      # `actor`'s own RPG2003 battle-command list resolved to menu rows, or nil
      # when there is nothing usable in it (no data at all -- an RPG2000
      # database, or a class/actor row that never set field 80, both of which
      # `Game::Actor#battle_commands` itself already reports as `[0]`, Row
      # alone -- or every entry turned out unsupported), so the caller falls
      # back to the fixed four.
      #
      # Each id is either 0 (Row -- not a menu row here any more than in
      # a reference implementation's own equivalent, whose comment marks it
      # "not impl" and skips it the same way), -1 (an empty padding slot,
      # likewise skipped), or a positive ref into the database's own
      # Battle-Commands table (`Game::Actor#battle_command_row`) naming one
      # entry's `name` + `type`. The five types this engine actually drives --
      # Attack, (sub)Skill, Defense, Item and Special -- become a row; Escape
      # (the first actor's own Cancel already offers it) is skipped, same as
      # an unresolvable ref (a project whose database has no Battle-Commands
      # table decoded, or an id it doesn't define). Special is a turn that
      # does nothing (ported from a reference implementation, not
      # independently confirmed against genuine RPG_RT under wine) --
      # #select_battle_command
      # resolves it to a forfeited turn.
      def custom_battle_commands(actor)
        return nil unless actor.respond_to?(:battle_commands)
        cmds = actor.battle_commands
        return nil unless cmds
        rows = cmds.each_with_object([]) do |cmd_id, out|
          next if cmd_id.nil? || cmd_id <= 0 # Row / empty slot

          row = actor.battle_command_row(cmd_id)
          next unless row

          case row.type
          when Game::Actor::BATTLE_COMMAND_ATTACK
            out << { label: nonblank(row.name, term(:battle_attack, 'Attack')), action: :attack,
                     command_id: cmd_id }
          when Game::Actor::BATTLE_COMMAND_SKILL, Game::Actor::BATTLE_COMMAND_SUBSKILL
            out << { label: nonblank(row.name, skill_command_label), action: :skill,
                     command_id: cmd_id }
          when Game::Actor::BATTLE_COMMAND_DEFENSE
            out << { label: nonblank(row.name, term(:battle_defend, 'Defend')), action: :defend,
                     command_id: cmd_id }
          when Game::Actor::BATTLE_COMMAND_ITEM
            out << { label: nonblank(row.name, term(:battle_item, 'Item')), action: :item,
                     command_id: cmd_id }
          when Game::Actor::BATTLE_COMMAND_SPECIAL
            out << { label: nonblank(row.name, 'Special'), action: :special,
                     command_id: cmd_id }
          end
          # Escape: no menu row (see the method comment above) -- Special has
          # one now, since #select_battle_command drives it.
        end
        rows.empty? ? nil : rows
      end

      def battle_commands
        battle_command_rows.map { |c| c[:label] }
      end

      # The Skill command's own label. RPG2000's Actor sheet has a "custom
      # battle command" checkbox + name field (database fields 66/67,
      # `Game::Actor#rename_skill?` / `#skill_command_name`) that renames just
      # this one slot — falling back to the stock Skill term when the actor's
      # own rename is unset. Parsed by the schema and
      # never read anywhere in this gem before now, so a game that set it (e.g.
      # renaming Skill to "Magic") showed the generic term regardless.
      def skill_command_label
        actor = current_actor_row
        if actor && actor.respond_to?(:rename_skill?) && actor.rename_skill?
          nonblank(actor.skill_command_name, term(:battle_skill, 'Skill'))
        else
          term(:battle_skill, 'Skill')
        end
      end

      # Per-actor command menu: Attack, Skill, Defend or Item. Holding Down/Up
      # auto-repeats the cursor after the initial delay -- originally only
      # confirmed against a reference implementation (whose per-frame window
      # update loop drives every selectable window's cursor via the standard
      # trigger-then-repeat, before active/inactive state ever gates which
      # one's Decision/Cancel handling actually runs), now independently
      # confirmed against a genuine RPG_RT.exe under wine (cycle #130): a
      # synthetic autostart Enemy Encounter (troop 103, its own genuine
      # Victory/Escape/EndBattle trailing structure copied verbatim from a
      # real Nepheshel boss page) injected into a copy of map 12. A single
      # continuous hold of Down -- one keydown, no release -- from this
      # window's own default (Attack, the top row) advanced the cursor
      # through multiple rows (Attack -> Skill, stalled, then Skill -> Defend
      # -> Item within one later interval, and on to a wrap back to Attack),
      # captured mid-hold with no intervening keyup; a trigger-only cursor
      # would have stopped dead at the first row it reached and stayed there
      # until release. The sibling options window (`#drive_battle_options`,
      # just below) was independently confirmed the same way in the same
      # cycle: a single hold there cycled Fight -> Auto Battle -> Escape ->
      # (wrap) Fight -> ... with no release either. Both are the same
      # `Input.trigger?(...) || Input.repeat?(...)` shape as the other four
      # spots this scene fixed in the same original pass (`#drive_battle_
      # target`/`#drive_battle_skill`/`#drive_battle_item`/`#drive_battle_
      # ally_target`), so every cursor spot in this scene gains `|| #repeat?`
      # the same way.
      def drive_battle_command
        if Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @ui[:cmd] += 1
          @ui[:cmd] %= battle_commands.length
          draw_battle_command
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @ui[:cmd] -= 1
          @ui[:cmd] %= battle_commands.length
          draw_battle_command
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          select_battle_command
        elsif Input.trigger?(Input::B)
          # `ProcessSceneActionCommand`'s own B/Cancel branch plays Cancel
          # unconditionally, *before* deciding where it lands: `...Cancel...;
          # --actor_index; SelectPreviousActor();`. `SelectPreviousActor()`
          # itself is what branches on whether an earlier commandable ally
          # is left to re-command.
          play_system_se(SFX_CANCEL)
          prev_i = prev_commandable_actor_index
          if prev_i.nil?
            # `SelectPreviousActor()`'s `allies[0] == active_actor` branch:
            # the actor whose command list is open is already the first
            # commandable member, so this reopens the Battle/Auto Battle/
            # Escape options window (`SetState(State_SelectOption)`) rather
            # than attempting Escape directly.
            open_battle_options
          else
            # Re-commanding the previous actor is the ordinary case.
            @ui[:actor_i] = prev_i # re-command the previous commandable member
            @ui[:cmd] = 0
            draw_battle_command
          end
        end
      end

      # The Battle/Auto Battle/Escape options window's own menu rows, in
      # display order (top to bottom, matching real RPG2k's
      # `battle_options`/`Window_Command` build). `battle_fight`/
      # `battle_auto`/`battle_escape` are the database's Term fields
      # 101/102/103 -- decoded by the schema but never read before this.
      def battle_option_rows
        [
          { label: term(:battle_fight, 'Fight'), action: :battle },
          { label: term(:battle_auto, 'Auto Battle'), action: :auto_battle },
          { label: term(:battle_escape, 'Escape'), action: :escape }
        ]
      end

      # Whether any living ally could actually be handed a manual command
      # this round -- ported from a reference implementation's own guard, not
      # independently confirmed against genuine RPG_RT under wine, which
      # skips the options window
      # entirely (straight to actor selection) when the whole party is
      # asleep/paralysed/similarly restricted or already flagged for auto
      # battle, since neither Battle nor Auto Battle would have anything left
      # to act on -- exactly this pair of checks: no significant restriction
      # and not already on auto battle.
      def any_commandable_ally?
        battle = @ui[:battle]
        living_allies.any? { |a| !battle.command_restricted?(a) && !force_ai_actor?(a) }
      end

      # The command phase's first entry for this battle only -- opens the
      # options window once, automatically, the way `ProcessSceneActionStart`'s
      # final substate does unconditionally after the encounter/turn-0-event
      # messages resolve (`battle_message_window->Clear();
      # SetState(State_SelectOption);`). Every later re-entry into the command
      # phase this battle (round 2+, back from a between-rounds battle event
      # page) goes straight to the ordinary per-actor command window instead --
      # the window's *other* trigger, B/Cancel on the first commandable actor,
      # is wired separately in #drive_battle_command and is not gated by this
      # flag, matching `SelectPreviousActor()`'s own unconditional re-entry.
      def enter_command_phase
        if @ui[:options_shown] || !any_commandable_ally?
          @ui[:options_shown] = true
          open_next_command
        else
          @ui[:options_shown] = true
          open_battle_options
        end
      end

      def open_battle_options
        @ui[:phase] = :battle_options
        @ui[:opt] = 0
        draw_battle_options
      end

      # The options window's cursor menu -- Up/Down move the cursor, C
      # confirms the highlighted row. B/Cancel is a deliberate no-op: this is
      # the state machine's own root here (matching
      # `ProcessSceneActionFightAutoEscape`'s `eWaitForInput` substate, which
      # has no cancel handling at all -- there is no parent state to cancel
      # back to). Down/Up auto-repeat on a held key -- see #drive_battle_
      # command's own comment for the cycle #130 genuine-RPG_RT re-verification
      # covering this window too.
      def drive_battle_options
        rows = battle_option_rows
        if Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)
          @ui[:opt] += 1
          @ui[:opt] %= rows.length
          draw_battle_options
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) || Input.repeat?(Input::UP)
          @ui[:opt] -= 1
          @ui[:opt] %= rows.length
          draw_battle_options
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          select_battle_option
        end
      end

      # Act on the highlighted options-window row. Battle dismisses the
      # window and falls through to the ordinary per-actor command menu,
      # exactly where the battle already was before the window opened. Auto
      # Battle hands the whole round to `#queue_auto_battle_round`. Escape
      # reuses `#try_battle_escape` verbatim -- the same Decision-vs-Buzzer
      # gate on `allow_escape` this engine's old direct-B-press shortcut
      # already had, just triggered from the window instead.
      def select_battle_option
        case battle_option_rows[@ui[:opt]][:action]
        when :battle
          play_system_se(SFX_DECISION)
          @ui[:phase] = :command
          # `open_next_command`, not a direct `draw_battle_command` -- the
          # window opening never advanced `actor_i` past a restricted/
          # Forced-AI leading actor (matching a reference implementation's own
          # actor-advance skip happening once actor selection
          # is entered from here, not before -- ported from that reference
          # implementation, not independently confirmed against genuine RPG_RT
          # under wine).
          open_next_command
        when :auto_battle
          play_system_se(SFX_DECISION)
          queue_auto_battle_round
        when :escape
          if @req[:allow_escape]
            play_system_se(SFX_DECISION)
            try_battle_escape
          else
            play_system_se(SFX_BUZZER)
          end
        end
      end

      # "Auto Battle": every commandable living ally gets
      # `Game::Battle#choose_auto_battle_command`'s AI pick queued for the
      # round instead of the manual per-actor command menu -- the same
      # engine `#skip_restricted_actors` already calls per-actor for a
      # 強制AI-flagged ally (see `#force_ai_actor?`), just applied to the
      # whole party at once rather than one actor. A restricted ally
      # (asleep/paralysed/forced) is left alone exactly as the ordinary
      # command phase already leaves it -- its round action is decided
      # elsewhere, not by a queued command.
      def queue_auto_battle_round
        battle = @ui[:battle]
        living_allies.each do |a|
          next if battle.command_restricted?(a)
          battle.choose_auto_battle_command(a)
        end
        @ui[:actor_i] = living_allies.length
        @ui[:phase] = :command
        open_next_command
      end

      # Escape command (cancel on the first actor's menu): roll the party's
      # agility-based escape chance. On success show the result window (the
      # database's own `escape_success` wording, like a victory or defeat) and
      # flee once it is dismissed; on a failed roll the party forfeits the
      # round — every member skips and only the enemies act, bannered with
      # `escape_failure` the same way a landed hit is — and the next attempt is
      # likelier (Game::Battle#attempt_escape). Still within the opening
      # first-strike ambush round (`#first_strike?`), the attempt is
      # unconditionally handed a `preemptive` escape instead of a roll --
      # ported from a reference implementation, not independently confirmed
      # against genuine RPG_RT under wine: it checks its
      # own `first_strike` flag first, before ever touching `escape_chance`, so
      # a first-strike encounter's opening Escape always succeeds even against
      # enemies fast enough to floor the roll at 0%.
      def try_battle_escape
        battle = @ui[:battle]
        if battle.attempt_escape(battle.first_strike?)
          # A dedicated Escape SE, not Decision -- ported from a reference
          # implementation's own escape handling, not independently confirmed
          # against genuine RPG_RT under wine: the success branch plays
          # its escape SE right before ending the battle. A
          # failed attempt plays no SE at all there, just the message.
          play_system_se(SFX_ESCAPE)
          enter_battle_result(:escape)
        else
          $stderr.puts '[RPG2k battle] escape failed'
          show_battle_banner([term(:escape_failure, "Couldn't escape!")])
          living_allies.each { |a| battle.command_skip(a) }
          start_round_animation
        end
      end

      # Act on the highlighted command: Attack / Skill open a selection, Defend
      # is committed at once. Dispatches by `#battle_command_rows`' own
      # `action` for the highlighted row rather than a fixed row index, so a
      # customized, reordered or shortened list (`#custom_battle_commands`)
      # still routes to the right handler regardless of where each command
      # landed.
      # Which SE each command plays on confirm -- Decision immediately for
      # Attack/Defend (a reference implementation
      # plays it as their own first statement, before doing anything else),
      # Skill/Item deferred to #start_skill/#start_item since that reference
      # implementation's own
      # Decision-on-opening-the-submenu and Buzzer-on-nothing-to-pick are
      # both conditional on that submenu's own state there -- ported from
      # that reference implementation, not independently confirmed against genuine
      # RPG_RT under wine.
      def select_battle_command
        # Record the chosen battle command (its `command_id` ref into
        # `db.battlecommands.commands`, 1..4 for the fixed four -- see
        # #battle_command_rows) onto the acting Combatant, the way a reference
        # implementation records the last battle action when the
        # command window confirms. The RPG2003 battle combo (Enable Combo) and
        # the battle-page `command_actor` condition both read it; RPG2000 never
        # consults either, so recording it for every battle is harmless.
        row = battle_command_rows[@ui[:cmd]]
        # Row carries no real command_id (it is not a Battle-Commands table
        # entry -- see #battle_command_rows), so it clears any previously
        # recorded command instead of leaving a stale one behind, mirroring a
        # reference implementation's own clearing of the last battle action
        # right before handling the Row selection.
        if current_actor
          current_actor.last_battle_action = row[:command_id] if row[:command_id]
          current_actor.last_battle_action = nil if row[:action] == :row
        end
        case row[:action]
        when :attack
          play_system_se(SFX_DECISION)
          @ui[:pending] = { kind: :attack }
          @ui[:target_i] = 0
          @ui[:phase] = :target
          draw_battle_target
        when :skill then open_battle_skill
        when :defend
          play_system_se(SFX_DECISION)
          @ui[:battle].command_defend(current_actor)
          # The alternate-layout sprite swaps to its Defend pose the instant
          # the command commits (a reference implementation's own idle
          # animation checks the defending flag continuously; this codebase
          # rebuilds instead, so the trigger has to be explicit) -- #finish_round_
          # animation reverts it once Game::Battle#end_round clears
          # `defending` back to false for the next round.
          reposition_actor_sprite(current_actor)
          advance_actor
        when :item then open_battle_item
        when :special
          # RPG2003's Special battle command is a turn that does nothing:
          # a reference implementation, not independently confirmed against
          # genuine RPG_RT under wine, plays the
          # Decision SE and queues a no-op action, which
          # consumes the actor's turn (and, in a gauge battle, its charge)
          # with no action, message or animation -- exactly what
          # `Game::Battle#command_skip` resolves to here (#strike returns nil
          # for a skipped battler and the turn is passed).
          play_system_se(SFX_DECISION)
          @ui[:battle].command_skip(current_actor)
          advance_actor
        when :row
          # RPG2003's Row battle command: flip the acting ally's front/back
          # row (ADR 0053), refused with a Buzzer if it would empty the front
          # row (`Game::Battle#toggle_row`/`#can_leave_front_row?`, ported
          # from a reference implementation's guard, not
          # independently confirmed against genuine RPG_RT under wine) --
          # by that account it stays on the command menu rather than
          # committing a turn when that happens, so this only advances on
          # success. A
          # successful toggle is written back onto the real `Game::Actor`
          # (`#battle_row=`) so it survives past this battle -- Combatant#row
          # is a fight-scoped snapshot the same way #attr_ranks is (see the
          # Combatant Struct's own field comment) -- and, like Special,
          # consumes the turn as a `DoNothing` action
          # (`Game::Battle#command_skip`).
          if @ui[:battle].toggle_row(current_actor)
            if current_actor_row && current_actor_row.respond_to?(:battle_row=)
              current_actor_row.battle_row = current_actor.row
            end
            # The alternate-layout sprite's automatic-placement X depends on
            # row (#automatic_battle_position) -- move it now rather than
            # leaving the old position on screen until some unrelated
            # roster-change redraw happens to catch it up.
            reposition_actor_sprite(current_actor)
            play_system_se(SFX_DECISION)
            @ui[:battle].command_skip(current_actor)
            advance_actor
          else
            play_system_se(SFX_BUZZER)
          end
        end
      end

      # Enemy target-selection menu: pick which living enemy the Attack (or an
      # enemy-scope Skill) hits. When there are more living foes than the
      # window's own BATTLE_VISIBLE_ROWS (4), Down/Up is clamped to rows 1..4
      # -- blocked, not wrapped, at either end, the same shape
      # `#move_battle_list_index` already uses for the battle Item/Skill
      # grids -- instead of this method's own pre-existing plain modulo wrap,
      # which stays exactly as it was for a troop of 4 or fewer (see
      # #move_battle_target_cursor). Confirmed against a genuine RPG_RT.exe
      # (cycle #131): on a troop of 6 (member x/y positions read straight off
      # the .ldb, each individually killed to identify which one the cursor
      # actually had, since every member of a wild troop shares one on-screen
      # name), Down held/tapped repeatedly from row 1 stops dead at row 4 and
      # *never* reaches members 5/6 -- no scroll, no wrap-around back to row 1
      # either, even after 8 discrete taps and a 2.5s hold well past the
      # point auto-repeat would have cycled through the rest. Up from row 1
      # is symmetric: it never reaches member 6. A same-shape probe on a
      # troop of exactly 4 (which fits the window with no overflow) shows the
      # opposite: Down from row 4 *does* wrap back to row 1 -- and a troop of
      # 3 confirms Up from row 1 wraps to row 3. So only the overflow case
      # (more living foes than the window's 4 visible rows) needed a fix:
      # real RPG_RT cannot select past the 4 rows it first draws at all, it
      # does not scroll this particular list the way the Item/Skill grids do.
      # `#drive_battle_ally_target`'s identical-shaped modulo needs no
      # matching change -- RPG2000's own party cap keeps `allies.length` at 4
      # or fewer always, so it can never hit the overflow case this fixes.
      def drive_battle_target
        foes = living_foes
        if (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) && !foes.empty?
          move_battle_target_cursor(1, foes.length)
        elsif (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && !foes.empty?
          move_battle_target_cursor(-1, foes.length)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          target = foes[@ui[:target_i]]
          close_battle_target
          if pending_skill?
            apply_pending_skill(target)
          else
            @ui[:battle].command_attack(current_actor, target)
            @ui[:pending] = nil
            @ui[:phase] = :command
            advance_actor
          end
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_battle_target
          if pending_kind == :skill
            @ui[:phase] = :skill
            draw_battle_skill
          elsif pending_skill? # an item-invoked skill: back out to the item list
            @ui[:phase] = :item
            draw_battle_item
          else
            @ui[:pending] = nil
            @ui[:phase] = :command
            draw_battle_command
          end
        end
      end

      # Move the enemy-target cursor by `delta` (+-1) over `foes_count` living
      # foes: a plain modulo wrap when they all fit in the window
      # (`foes_count <= BATTLE_VISIBLE_ROWS`, this method's own pre-existing
      # behaviour, unchanged), blocked at either end with no wrap at all once
      # `foes_count` overflows it -- see #drive_battle_target's own comment
      # for the cycle #131 evidence behind the split.
      def move_battle_target_cursor(delta, foes_count)
        if foes_count > BATTLE_VISIBLE_ROWS
          target = @ui[:target_i] + delta
          return if target.negative? || target >= BATTLE_VISIBLE_ROWS
          @ui[:target_i] = target
        else
          @ui[:target_i] = (@ui[:target_i] + delta) % foes_count
        end
        draw_battle_target
        play_system_se(SFX_CURSOR)
      end

      def pending_kind; @ui[:pending] && @ui[:pending][:kind]; end

      # Whether the pending action casts a skill -- either chosen from the
      # Skill menu (`kind: :skill`) or invoked by a special/use_skill battle
      # item (`kind: :item` with a resolved `sk`, see #drive_battle_item's
      # confirm branch) -- as opposed to a plain medicine/switch item or a
      # basic Attack, both of which leave `sk` unset. #apply_pending_skill/
      # #apply_pending_skill_all read `@ui[:pending][:item_id]` themselves to
      # tell the two skill sources apart where that still matters (the SP
      # cost and the log entry's bag-consumption id).
      def pending_skill?; @ui[:pending] && @ui[:pending][:sk]; end

      # -- Skill sub-menu ------------------------------------------------------

      # Open the current actor's battle-skill list (nothing to open if they know
      # no battle-usable skill).
      def open_battle_skill
        actor = current_actor_row
        list = actor ? @state.party.battle_skills(actor, current_actor) : []
        # A status that seals skills (封印 / Silence) takes them off the menu
        # rather than letting the actor pick one that would be refused.
        battle = @ui[:battle]
        battler = current_actor
        if battle && battler
          list = list.reject do |sid, _cost|
            battle.skill_sealed?(battler, @state.party.db_skill(sid))
          end
        end
        @ui[:skills] = list
        # A reference implementation always plays Decision opening this list, and
        # Buzzer only once a confirm inside it finds nothing usable
        # (checking whether the selection is enabled)
        # -- ported from that reference implementation, not independently
        # confirmed against genuine RPG_RT under wine. This engine instead
        # never opens an empty list at all, so
        # Buzzer plays here, at the one point that same "nothing to pick"
        # outcome is actually known.
        if @ui[:skills].empty?
          play_system_se(SFX_BUZZER)
          return
        end
        play_system_se(SFX_DECISION)
        @ui[:skill_i] = 0
        @ui[:phase] = :skill
        draw_battle_skill
      end

      # Move a battle Item/Skill list cursor by `delta` cells (a row for
      # +-BATTLE_LIST_COLUMN_MAX, a column for +-1), left in place if the
      # target cell is off the grid -- originally only cited to a reference
      # implementation's window-update logic, the same
      # column-locked-Down/Up, flat-Right/Left shape `Scene::ItemMenu#
      # move_item_cursor` already uses for the field item/skill grid. Now
      # independently confirmed against a genuine RPG_RT.exe under wine
      # (cycle #133, `#drive_battle_item`'s own comment has the full
      # writeup): `#drive_battle_item` specifically, at every list-size
      # boundary this method's own shape distinguishes (1 item, 2 items/one
      # full row, an odd 3-item partial-second-row, an exact 8-item/4-row
      # grid with no overflow, and a 9-item overflow that scrolls) -- every
      # single case matched this method's pre-existing behaviour exactly, so
      # no change was needed here. `#drive_battle_skill` is now independently
      # confirmed too (cycle #134, its own comment has the full writeup) --
      # the same five boundary cases, all matching this method exactly, on a
      # hand-edited skill list rather than a hand-edited item list.
      def move_battle_list_index(index, delta, size)
        target = index + delta
        return nil if target.negative? || target >= size
        target
      end

      # Independently re-verified against a genuine RPG_RT.exe under wine
      # (cycle #134) -- the one piece cycle #133 left unrun of its own
      # closing note ("`#drive_battle_skill` was not independently re-run
      # this cycle ... this is not a fresh guess the way the pre-cycle-133
      # state was"). Gave the debug save's own party leader (chunk 108's
      # actor id **15** -- not id 1, whose level/HP the SAVE_TITLE hero_
      # level/hero_hp fields do *not* match; the file-select screen's
      # "LV50 HP600" only lines up with actor 15's own chunk-108 row, which
      # is what pins down which roster entry the debug save's solo "デモ用"
      # character actually is) a hand-edited skills list (chunk 108 field 52,
      # `SAVE_PARTY_ACTOR#skills`) via five separate wine sessions, one per
      # list-size boundary this grid's own 2-column/4-row shape distinguishes
      # -- the same five cases `#drive_battle_item`'s own comment covers, all
      # drawn from database skill ids 1-9 (all `type: 0`, an ordinary spell,
      # so `Game::Party#battle_skill?` includes every one regardless of
      # scope): 1 skill (single cell), 2 skills (one full row), 3 skills (odd,
      # a partial second row), 8 skills (an exact 4-row grid, no overflow) and
      # 9 skills (overflow past the grid). Same probe rig as cycles #130/#131/
      # #133 (a synthetic autostart Enemy Encounter, troop 103, tail-spliced
      # onto Map0012 from Map0478 event 2 page 2's own genuine Victory/Escape/
      # EndBattle trailing structure) -- Continue -> file 1 -> autostart fires
      # straight into the battle options window (no "X appeared!" message this
      # troop shows) -> Decision confirms Fight -> Down once (Attack -> Skill)
      # -> Decision opens the skill list, then held Down/Right/Left/Up.
      # Results, all matching `#move_battle_list_index`/`#battle_list_window`
      # exactly, the same as `#drive_battle_item`'s own findings: 1 skill
      # blocked in all four directions across a 1.2s held Down/Right/Up/Left;
      # 2 skills let Right/Left cross the row with Down/Up blocked (no second
      # row); 3 skills let Down reach the partial second row's lone cell, with
      # Right off its end blocked (no phantom cell) and Up returning to row 0;
      # 8 skills auto-repeated through a continuous 1.5s Down hold (row 0 -> 1
      # -> 2 -> 3 within that one hold, confirming genuine key-repeat the same
      # way cycle #130/#133 did) then stopped dead at the grid's own last
      # cell on a further hold, neither wrapping nor scrolling; 9 skills
      # scrolled (a genuine pixel scroll, confirmed on-screen -- the previous
      # top-left skill rolled off the top of the window) via a 2.5s Down hold
      # to reveal the 9th skill alone in a fifth, partial row, then blocked
      # there with no wrap and no phantom cell to its right either. Since
      # nothing needed fixing, this comment and the matching
      # `scripts/rpg2k_scene_check.rb` checks were updated to record the
      # re-verification, mirroring cycle #133's own precedent for
      # `#drive_battle_item`. `#drive_battle_ally_target` remains the one
      # battle cursor still unverified against genuine RPG_RT -- still
      # blocked on growing the debug save past its one live actor (cycle
      # #132's own open item (c); see this cycle's docs/TODO.md entry for
      # what was and was not learned about that this time around).
      # `Map0012.lmu`/`Save01.lsd` were edited only as scratch copies for
      # these probes and restored to their original bytes (byte-identical by
      # `md5sum`) once each wine session was torn down.
      def drive_battle_skill
        skills = @ui[:skills]
        if (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) && !skills.empty?
          move_battle_skill_cursor(BATTLE_LIST_COLUMN_MAX)
        elsif (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && !skills.empty?
          move_battle_skill_cursor(-BATTLE_LIST_COLUMN_MAX)
        elsif (Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)) && !skills.empty?
          move_battle_skill_cursor(1)
        elsif (Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)) && !skills.empty?
          move_battle_skill_cursor(-1)
        elsif Input.trigger?(Input::C)
          confirm_battle_skill
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_battle_skill
          @ui[:phase] = :command
          draw_battle_command
        end
      end

      def move_battle_skill_cursor(delta)
        target = move_battle_list_index(@ui[:skill_i], delta, @ui[:skills].length)
        return unless target
        @ui[:skill_i] = target
        draw_battle_skill
        play_system_se(SFX_CURSOR)
      end

      # Whether the highlighted skill (`sid`/`cost`/`sk`, already looked up)
      # cannot currently be cast: the caster cannot afford its SP, or is
      # missing a weapon-type Attribute the skill requires
      # (`Game::Party#weapon_attribute_ready?` -- the same equip-gate
      # `#can_cast?` already applies to a field cast and to a Forced-AI actor's
      # own skill eligibility, see `Game::Battle#skill_ready?`). Shared by
      # #confirm_battle_skill's buzz-and-stay gate and #draw_battle_skill's
      # row colour (see its own comment) so both agree by construction.
      def battle_skill_unavailable?(cost, sk)
        current_actor.mp < cost ||
          !@state.party.weapon_attribute_ready?(current_actor_row, sk)
      end

      # Choose the highlighted skill: if the caster cannot afford its SP, or is
      # missing a weapon-type Attribute the skill requires, this is a
      # reference implementation's own Buzzer case (covering both --
      # ported from that reference implementation, not independently confirmed
      # against genuine RPG_RT under wine);
      # otherwise Decision, then route to enemy / ally target selection (or
      # cast at once on a self-scope skill).
      def confirm_battle_skill
        sid, cost = @ui[:skills][@ui[:skill_i]]
        sk = @state.party.db_skill(sid)
        if battle_skill_unavailable?(cost, sk)
          play_system_se(SFX_BUZZER)
          return
        end
        play_system_se(SFX_DECISION)
        @ui[:pending] = { kind: :skill, sk: sk, sid: sid }
        close_battle_skill
        case @state.party.battle_skill_target(sk)
        when :self
          apply_pending_skill(current_actor)
        when :enemy
          @ui[:target_i] = 0
          @ui[:phase] = :target
          draw_battle_target
        when :all_enemy
          apply_pending_skill_all(living_foes)
        when :all_ally
          apply_pending_skill_all(living_allies)
        else # :ally
          @ui[:ally_i] = 0
          @ui[:phase] = :ally_target
          draw_battle_ally_target
        end
      end

      # Commit the pending skill on `target` (SP cost / effect from the model),
      # then move to the next actor. `item_id` set (a special/use_skill battle
      # item invoking this skill, see #drive_battle_item's confirm branch)
      # makes the item pay instead of the caster's own SP -- ported from a
      # reference implementation, not independently confirmed against
      # genuine RPG_RT under wine: it
      # consumes the item rather than spending SP whenever one backs
      # the cast -- and rides onto the built command for
      # #drive_battle_animate's bag consumption and #reflects_skill?'s own
      # item-casts-are-never-reflected exclusion.
      def apply_pending_skill(target)
        sk = @ui[:pending][:sk]
        sid = @ui[:pending][:sid]
        item_id = @ui[:pending][:item_id]
        c = @state.party.battle_skill_command(sk, current_actor, target, free: !item_id.nil?)
        @ui[:battle].command_skill(current_actor, target,
                                          name: sk.name, skill_id: sid, item_id: item_id,
                                          absorb: c[:absorb] ? true : false,
                                          # Left as `c[:attack]` verbatim (not coerced to a
                                          # boolean): a stub `battle_skill_command` in the test
                                          # suite that omits the key entirely needs `nil` to
                                          # reach #apply_skill_hit so its own sign-of-hp
                                          # fallback still applies, matching this build's real
                                          # Game::Party#battle_skill_command before this key
                                          # existed at all.
                                          attack: c[:attack],
                                          cost: c[:cost],
                                          hp: c[:hp], mp: c[:mp],
                                          inflict: c[:inflict], chance: c[:chance],
                                          variance: c[:variance] || 0,
                                          attributes: c[:attributes],
                                          attr_shift: c[:attr_shift],
                                          attr_ids: c[:attr_ids],
                                          stat_mod_keys: c[:stat_mod_keys],
                                          stat_effect: c[:stat_effect] || 0,
                                          cured: c[:cured],
                                          physical_rate: c[:physical_rate] || 0,
                                          switch_id: c[:switch_id])
        @ui[:pending] = nil
        @ui[:phase] = :command
        advance_actor
      end

      # Commit the pending all-target skill on every `targets` combatant (all
      # living enemies for an attack skill, all living allies for a heal): build
      # one per-target effect from the model (attack damage varies with each
      # target's defence) and queue them as a single volley. The shared SP cost /
      # infliction ride along once. `item_id`: see #apply_pending_skill's
      # identical comment -- the item pays instead of SP, and rides the
      # command for bag consumption / reflect exclusion.
      def apply_pending_skill_all(targets)
        sk = @ui[:pending][:sk]
        sid = @ui[:pending][:sid]
        item_id = @ui[:pending][:item_id]
        meta = @state.party.battle_skill_command(sk, current_actor, targets.first, free: !item_id.nil?)
        effects = targets.map do |t|
          c = @state.party.battle_skill_command(sk, current_actor, t, free: !item_id.nil?)
          { target: t, hp: c[:hp], mp: c[:mp] }
        end
        @ui[:battle].command_skill_all(current_actor, effects,
                                              name: sk.name, skill_id: sid, item_id: item_id,
                                              absorb: meta[:absorb] ? true : false,
                                              attack: meta[:attack], # see #apply_pending_skill's comment
                                              cost: meta[:cost],
                                              inflict: meta[:inflict], chance: meta[:chance],
                                              variance: meta[:variance] || 0,
                                              attributes: meta[:attributes],
                                              attr_shift: meta[:attr_shift],
                                              attr_ids: meta[:attr_ids],
                                              stat_mod_keys: meta[:stat_mod_keys],
                                              stat_effect: meta[:stat_effect] || 0,
                                              cured: meta[:cured],
                                              physical_rate: meta[:physical_rate] || 0)
        @ui[:pending] = nil
        @ui[:phase] = :command
        advance_actor
      end

      # -- Item sub-menu -------------------------------------------------------

      # Open the party's battle-usable items (nothing to open if the bag holds
      # none).
      def open_battle_item
        @ui[:items] = @state.party.battle_items
        # See #start_skill's identical comment -- the same Decision/
        # Buzzer split, ported from `Scene_Battle::ItemSelected`.
        if @ui[:items].empty?
          play_system_se(SFX_BUZZER)
          return
        end
        play_system_se(SFX_DECISION)
        @ui[:item_i] = 0
        @ui[:phase] = :item
        draw_battle_item
      end

      # Independently re-verified against a genuine RPG_RT.exe under wine
      # (cycle #133), companion work to cycle #130's re-verification of
      # `#drive_battle_command`/`#drive_battle_options` and cycle #131's fix
      # to `#drive_battle_target` -- this one was the first of the three
      # `#drive_battle_skill`/`#drive_battle_item`/`#drive_battle_ally_target`
      # cursors those two cycles left unrun. A synthetic autostart Enemy
      # Encounter (troop 103, the same probe cycles #130/#131 used, tail-
      # spliced onto a copy of Nepheshel's map 12) with the debug save's
      # inventory chunk (109) hand-edited to hold exactly 1/2/3/8/9 held
      # items -- every list-size case this grid's own shape distinguishes:
      # a single cell (blocked in all four directions, including a 1.2s held
      # Down); one full row (Right/Left cross it, Down/Up blocked -- no
      # second row exists); an odd 3-item list (Down reaches the partial
      # second row's lone cell, Right off the end of it does *not* reach a
      # hidden/phantom cell the way the equip candidate list's trailing
      # Remove entry does -- cycle #129's own finding does not generalise
      # here); an exact 8-item/4-row grid with no overflow (a continuous
      # 1.5s Down hold auto-repeats row 0 -> row 1 -> row 2 -> row 3 within
      # one hold, confirming genuine key-repeat same as cycle #130's own
      # finding, then stops dead at row 3/col 1, the grid's own last cell --
      # neither wrapping to row 0 nor scrolling for lack of anywhere to
      # scroll to); and a 9-item overflow (a 2.5s Down hold reaches the 9th
      # item alone in a fifth, partial row -- the window genuinely *does*
      # scroll to reveal it, unlike the enemy-target list cycle #131 found
      # does not scroll at all -- then blocks there with no wrap and no
      # phantom trailing cell, exactly mirroring the 3-item case). Every one
      # of these matched `#move_battle_list_index`'s pre-existing behaviour
      # exactly, so this method needed no change -- confirmed correct, not
      # merely inherited from a shared code shape, the same outcome cycle
      # #130 reached for the options/command cursors.
      def drive_battle_item
        items = @ui[:items]
        if (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) && !items.empty?
          move_battle_item_cursor(BATTLE_LIST_COLUMN_MAX)
        elsif (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && !items.empty?
          move_battle_item_cursor(-BATTLE_LIST_COLUMN_MAX)
        elsif (Input.trigger?(Input::RIGHT) || Input.repeat?(Input::RIGHT)) && !items.empty?
          move_battle_item_cursor(1)
        elsif (Input.trigger?(Input::LEFT) || Input.repeat?(Input::LEFT)) && !items.empty?
          move_battle_item_cursor(-1)
        elsif Input.trigger?(Input::C)
          item_id, _count = @ui[:items][@ui[:item_i]]
          # A row now can hold an item #battle_items lists but is not
          # battle-usable (see its own doc comment) -- selectable, since the
          # cursor moves freely onto it, but Decision just buzzes and stays,
          # the same "greyed entry" shape the field Item menu's
          # Scene::ItemMenu#choose_item already gates its own dispatch
          # behind.
          unless @state.party.battle_usable?(item_id)
            play_system_se(SFX_BUZZER)
            return
          end
          play_system_se(SFX_DECISION)
          it = @state.party.db_item(item_id)
          @ui[:pending] = { kind: :item, item_id: item_id, it: it }
          close_battle_item
          # A type-9 special item, or an equipment item flagged `use_skill`,
          # invokes the skill named in its `skill_id` instead of being plain
          # medicine -- the invoked skill's own scope decides where this goes
          # next, exactly like #confirm_battle_skill dispatches an ordinary
          # skill chosen from the Skill menu (`Scene_Battle::AssignSkill`,
          # `src/scene_battle.cpp`, dispatches an item-backed skill through
          # the identical scope switch). `#battle_usable?` already excluded
          # this item from the list entirely unless its skill is battle-usable
          # in the first place (never Escape/Teleport, see #battle_skill?), so
          # every skill reached here is one #battle_skill_target can resolve.
          sk = @state.party.skill_invoking_item?(it) ? @state.party.db_skill(it.skill_id) : nil
          if sk
            @ui[:pending][:sk] = sk
            @ui[:pending][:sid] = it.skill_id
            case @state.party.battle_skill_target(sk)
            when :self
              apply_pending_skill(current_actor)
            when :enemy
              @ui[:target_i] = 0
              @ui[:phase] = :target
              draw_battle_target
            when :all_enemy
              apply_pending_skill_all(living_foes)
            when :all_ally
              apply_pending_skill_all(living_allies)
            else # :ally
              @ui[:ally_i] = 0
              @ui[:phase] = :ally_target
              draw_battle_ally_target
            end
          elsif @state.party.switch_item?(item_id)
            apply_pending_switch_item
          elsif @state.party.item_all_allies?(it)
            # The whole roster, dead included -- a reference implementation's
            # own entire-party branch targets the full party
            # itself, not a living-only subset, which is
            # what lets an all-party 蘇生専用 item revive every KO'd member
            # in one cast.
            apply_pending_item_all(@ui[:allies])
          else
            @ui[:ally_i] = 0
            @ui[:phase] = :ally_target
            draw_battle_ally_target
          end
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_battle_item
          @ui[:phase] = :command
          draw_battle_command
        end
      end

      def move_battle_item_cursor(delta)
        target = move_battle_list_index(@ui[:item_i], delta, @ui[:items].length)
        return unless target
        @ui[:item_i] = target
        draw_battle_item
        play_system_se(SFX_CURSOR)
      end

      # -- Ally target (heal skill / medicine) --------------------------------

      # Only Down/Up move the ally-target cursor -- Right/Left are dead input
      # here, not folded onto the same axis.
      #
      # Independently re-verified (cycle #136, 2026-08-24), overturning a
      # prior cycle's own claim (which had secretly cited a reference
      # implementation's source, since removed) that Right/Left mirror
      # Down/Up. Confirmed against
      # genuine RPG_RT.exe under wine (Nepheshel), using a technique cycle
      # #135 had time-boxed away from and this cycle finished: a synthetic
      # autostart event on a scratch copy of Map0012, carrying live `Change
      # Party Member` (event code 10330, `[0, 0, <actor id>]`) commands
      # prepended onto Map0478 event 2 page 2's own genuine Enemy-Encounter-
      # through-EndBattle trailing structure (troop 103, codes 10710/20710/
      # 20711/20713/0, tail-spliced verbatim as cycles #130-134 did) --
      # letting the genuine runtime itself grow the live party in memory
      # before battle starts, rather than hand-editing a save's `party`
      # field (confirmed a dead end by cycle #135: it crashes RPG_RT.exe
      # outright). This produced real, undamaged 2- and 4-member parties
      # (デモ用+ファル; デモ用+ファル+ティララ+ディーヴァ) with no crash --
      # unblocking this check and cycle #132's own open multi-actor
      # question in the field target-confirm screen (see that entry's own
      # follow-up below). Tested via Continue -> file 1 -> autostart ->
      # confirm Fight -> Down x3 to Item -> Decision on 薬草 (single-ally
      # scope) -> ally-target screen, screenshot-verified after every single
      # keypress (never assuming a fixed press count, matching cycle #135's
      # own recommended fix for its title-cursor flakiness): with 2 allies,
      # Down/Up wrap correctly (0->1->0, and Up from 0 reaches 1) exactly as
      # this method already computed, but Right and Left from *either* row
      # left the cursor on the same row every single time -- rechecked with
      # a full settle wait after each individual press once a first batched
      # sequence looked ambiguous (proved to be simple frame lag, not a real
      # movement, once isolated one key at a time). With 4 allies the same
      # holds at both boundaries: Right from row 0 and row 3 both no-op,
      # Left from row 0 no-ops (does not reach row 3 the way Up correctly
      # does), and a plain Down x4 visits all four rows in order before
      # wrapping, Up from row 0 wraps straight to row 3. Fixed by dropping
      # the Right/Left arms entirely -- Down/Up (trigger or repeat) are the
      # only inputs that move `@ui[:ally_i]`.
      def drive_battle_ally_target
        allies = battle_ally_targets
        if (Input.trigger?(Input::DOWN) || Input.repeat?(Input::DOWN)) && !allies.empty?
          @ui[:ally_i] += 1
          @ui[:ally_i] %= allies.length
          draw_battle_ally_target
          play_system_se(SFX_CURSOR)
        elsif (Input.trigger?(Input::UP) || Input.repeat?(Input::UP)) && !allies.empty?
          @ui[:ally_i] -= 1
          @ui[:ally_i] %= allies.length
          draw_battle_ally_target
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C) && !allies.empty?
          # `Scene_Battle::AllySelected` was not itself fetched verbatim,
          # but it is one of the same family of "Selected" callbacks as
          # Attack/Defend/Item/Skill above, every one of which plays
          # Decision as its own first statement before acting.
          play_system_se(SFX_DECISION)
          target = allies[@ui[:ally_i]]
          close_battle_ally_target
          if pending_skill?
            apply_pending_skill(target)
          else
            apply_pending_item(target)
          end
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_battle_ally_target
          if pending_kind == :skill
            @ui[:phase] = :skill
            draw_battle_skill
          else
            @ui[:phase] = :item
            draw_battle_item
          end
        end
      end

      # Commit a switch item: it has no target at all -- the same as the field
      # menu's own switch item (Scene::ItemMenu#apply_switch_item) skips
      # straight past target selection -- so this queues immediately off
      # #drive_battle_item's Confirm, with `current_actor` standing in for
      # `command_item`'s `target:` (never read for a switch effect; a switch
      # item's hp/mp are always 0, so it does not touch its HP/MP either).
      # `switch_id` rides the log entry the same way `item_id` does, so
      # #drive_battle_animate can flip it -- and only then, deferred to when
      # the action actually lands, exactly like the bag deduction it sits
      # beside there.
      def apply_pending_switch_item
        pending = @ui[:pending]
        @ui[:battle].command_item(current_actor, current_actor,
                                         item_id: pending[:item_id],
                                         name: pending[:it].name,
                                         switch_id: pending[:it].switch_id)
        @ui[:pending] = nil
        @ui[:phase] = :command
        advance_actor
      end

      # Commit the pending item on `target` (recovery from the model; the bag is
      # consumed later, when the action lands), then move to the next actor.
      def apply_pending_item(target)
        pending = @ui[:pending]
        c = @state.party.battle_item_command(pending[:it], target)
        @ui[:battle].command_item(current_actor, target,
                                         item_id: pending[:item_id],
                                         name: pending[:it].name,
                                         hp: c[:hp], mp: c[:mp], cured: c[:cured])
        @ui[:pending] = nil
        @ui[:phase] = :command
        advance_actor
      end

      # Commit an all-party item on every living ally: one per-member recovery
      # from the model, queued as a single volley that consumes one item.
      def apply_pending_item_all(targets)
        pending = @ui[:pending]
        effects = targets.map do |t|
          c = @state.party.battle_item_command(pending[:it], t)
          { target: t, hp: c[:hp], mp: c[:mp] }
        end
        cured = @state.party.battle_item_command(pending[:it], targets.first)[:cured]
        @ui[:battle].command_item_all(current_actor, effects,
                                             item_id: pending[:item_id],
                                             name: pending[:it].name, cured: cured)
        @ui[:pending] = nil
        @ui[:phase] = :command
        advance_actor
      end

      # Move to the next living party member, or start playing out the round once
      # every member has a command.
      def advance_actor
        @ui[:actor_i] += 1
        @ui[:cmd] = 0
        open_next_command
      end

      # Advance `actor_i` past any living ally the round already decides
      # for automatically -- a "do nothing" or forced attack-ally/
      # attack-enemy restriction, see `Game::Battle#command_restricted?` --
      # then either open the next actually-commandable ally's menu or, if
      # every remaining living ally is restricted, start the round right
      # away exactly as running out of allies after the last command
      # already does. Without this, an asleep/paralysed/confused/berserk
      # ally still got the ordinary Attack/Skill/Defend/Item prompt, and a
      # party entirely under such states (e.g. everyone put to sleep by an
      # enemy's spell) froze the command phase forever waiting on choices
      # that could never change the outcome -- the "unrecoverable
      # input-blocking state lock" case flagged as still open next to the
      # empty/all-KO'd-party fix above.
      def open_next_command
        skip_restricted_actors
        if @ui[:actor_i] >= living_allies.length
          start_round_animation
        else
          draw_battle_command
        end
      end

      # Also auto-commands (rather than merely skipping) a 強制AI-flagged ally
      # that isn't otherwise restricted: `Game::Actor#force_ai?` -- checked
      # only once `#command_restricted?` has already answered false, matching
      # `Scene_Battle_Rpg2k::SelectNextActor`'s own real check order (CanAct
      # -> forced attack-ally/attack-enemy restriction -> auto_battle) -- gets
      # `Game::Battle#choose_auto_battle_command` to queue its action right
      # here instead of ever drawing the manual command window for it.
      def skip_restricted_actors
        battle = @ui[:battle]
        allies = living_allies
        i = @ui[:actor_i]
        loop do
          a = allies[i]
          break unless a
          if battle.command_restricted?(a)
            i += 1
          elsif force_ai_actor?(a)
            battle.choose_auto_battle_command(a)
            i += 1
          else
            break
          end
        end
        @ui[:actor_i] = i
      end

      def force_ai_actor?(combatant)
        combatant.actor && combatant.actor.respond_to?(:force_ai?) && combatant.actor.force_ai?
      end

      # The index of the previous living ally free to receive a manual
      # command, walking backward from just before the current one and
      # skipping any restricted ally the same way `#skip_restricted_actors`
      # does going forward -- nil once nothing earlier is left to
      # re-command, matching a reference implementation's own actor-select
      # logic recursing back
      # to the Fight/Auto/Escape menu once it would land on the very first
      # ally.
      def prev_commandable_actor_index
        battle = @ui[:battle]
        allies = living_allies
        i = @ui[:actor_i] - 1
        i -= 1 while i >= 0 && (battle.command_restricted?(allies[i]) || force_ai_actor?(allies[i]))
        i >= 0 ? i : nil
      end

      # Frames each attack of the round lingers on screen before the next lands
      # -- only when the action has no battle animation to pace it instead
      # (`#drive_battle_animate` sets this timer to 0 and lets
      # `#battle_animation_playing?` drive the wait when one plays, so this
      # constant is specifically the "just the text" case).
      #
      # A reference implementation does not use one flat gate here; it holds
      # each stage of the action separately, and
      # *without* the player holding Decision/Shift to skip ahead,
      # it always burns the full wait of every stage it
      # passes through -- decrementing every frame regardless of input and
      # only short-circuiting
      # early once a skip key is actually held. All of this is ported from
      # that reference implementation, not independently confirmed against
      # genuine RPG_RT under wine. Tracing
      # the default (no-skip) path for a plain attack that hits, with no
      # animation, no crit and no state change -- the common case this
      # constant covers -- through every stage that fires:
      # the action-begin stage (no state-proc message) 4 frames,
      # the usage stage's start-message
      # wait of 40 frames,
      # the animation stage with no animation still applies
      # the same 40-frame wait,
      # the execute stage's 4 frames,
      # the damage stage's begin 4 frames, its message-line
      # damage wait of 40 frames, and its post-stage 10 frames --
      # 4+40+40+4+4+40+10 = 142 frames (~2.4s at 60fps) before RPG_RT would
      # move on. This banner shows the "attacks" and "damage" lines at once
      # rather than as RPG_RT's two sequential message pages, so it does not
      # need the full 142 to be equally readable; 90 frames (~1.5s) lands
      # much closer to that real pace than the old 20 (~0.33s, barely long
      # enough to register the hit at all) while still reading as one beat
      # rather than RPG_RT's own two-page hold.
      BATTLE_ANIM_FRAMES = 90

      # Begin animating the commanded round: dismiss the command menu and prime
      # the battle's per-action queue. From here #drive_battle_animate lands one
      # attack per BATTLE_ANIM_FRAMES until the round's queue empties.
      def start_round_animation
        if @ui[:cmd_win]
          @ui[:cmd_win].dispose
          @ui[:cmd_win] = nil
        end
        @ui[:battle].begin_round
        @ui[:phase] = :animate
        @ui[:anim_timer] = 0 # land the first attack next frame
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
          @map.step_map_animation
          return
        end
        if @ui[:anim_timer] > 0
          @ui[:anim_timer] -= 1
          return
        end
        # A battle page is checked once per *acting battler*, not once per
        # round -- a reference implementation runs this "before each
        # battler acts and also right after the last battler acts" (the
        # latter half is #finish_round_animation's own check, already in
        # place). The boundary between two battlers' actions is exactly where
        # the previous #step_action call left nothing buffered (a dual-wield
        # swing or an all-target Skill/Item queues several hits from *one*
        # battler; the check belongs between battlers, not between hits).
        # The acting battler rides along as the per-battler check's source, so
        # the turn_enemy / turn_actor / command_actor conditions test the
        # battler the check is for (Game::BattlePage.active?).
        if @ui[:battler_boundary]
          @ui[:battler_boundary] = false
          return if run_battle_events(:animate, @ui[:battle].acting_battler)
        end
        entry = @ui[:battle].step_action
        if entry
          # An Item action spends one *use* from the real bag when it lands (so
          # backing out during the command phase never spends it), which only
          # costs a copy once the item's 使用回数 runs out -- the same
          # Game::Party#consume_item_use the field menu goes through, so a
          # multi-use bomb or a 特殊効果 weapon behaves identically in a fight.
          # A switch item flips its switch at the same moment -- the state table
          # is the scene's, same as the field menu's own Scene::ItemMenu, and
          # this is the only place a queued switch-item action ever reaches it.
          @state.party.consume_item_use(entry[:item_id]) if entry[:item_id]
          @state.switches[entry[:switch_id]] = true if entry[:switch_id]
          log_round([entry])
          refresh_battle_status
          refresh_battle_sprites
          show_battle_action(entry)
          play_battle_action_se(entry)
          # When an animation plays, it is the wait; otherwise the banner timer
          # is, exactly as before.
          @ui[:anim_timer] =
            start_battle_animation(entry) ? 0 : BATTLE_ANIM_FRAMES
          @ui[:battler_boundary] = @ui[:battle].pending_empty?
        else
          finish_round_animation
        end
      end

      def battle_animation_playing?
        !@map.map_animation.nil? && @map.map_animation[:battle]
      end

      # Play the animation this action names, over its target. RPG2000 keeps the
      # animation on the **skill** and on the **item**, not on the action -- 557
      # skill rows and 170 item rows across the test beds name one, and none of
      # them played. Returns true when one started.
      #
      # A plain attack now plays one too: Game::Battle#deal_attack resolves
      # the attacking actor's own weapon/unarmed animation (Actor#
      # attack_animation_id) and carries it on the log entry as
      # `attack_animation_id`, which #battle_animation_id below reads once
      # neither a skill nor an item claims the entry.
      def start_battle_animation(entry)
        id = battle_animation_id(entry)
        return false unless id && id > 0
        tx, ty, height = battle_animation_pixel(entry)
        target = @map.anim_target(tx, ty, height: height, index: entry[:target_index],
                                  flash_target: nil)
        anim = @map.build_animation(id, [target], true)
        return false unless anim
        @map.map_animation = anim
        @map.fire_animation_flashes(anim) # frame 0 flashes, as the map path does
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
        return row.animation_id if row && row.respond_to?(:animation_id)
        # Neither a skill nor an item: a plain Attack, whose own animation
        # Game::Battle#deal_attack already resolved onto the log entry.
        entry[:attack_animation_id]
      end

      # Where it plays: over the targeted enemy's sprite. RPG2000 draws no sprite
      # for a party member -- its battle is first-person -- so an action aimed at
      # one plays over the middle of the screen instead of nowhere. The third
      # element is the sprite's own pixel height, for #animation_position_offset
      # to split into head/feet thirds -- nil for the screen-centre fallback,
      # which has no sprite to measure and so never moves off it.
      def battle_animation_pixel(entry)
        i = entry[:target_index]
        sprites = @ui[:enemy_sprites]
        spr = i && sprites ? sprites[i] : nil
        bmp = spr && spr.bitmap
        return [SCREEN_W / 2, SCREEN_H / 2, nil] unless bmp
        [spr.x + bmp.width / 2, spr.y + bmp.height / 2, bmp.height]
      end

      # Show Battle Animation (13260), the battle-page form of the map's own
      # 11210: it needs this round's own positioning (#battle_animation_pixel,
      # the targeted enemy's live sprite -- or the ally-side screen-centre
      # fallback) and Character Flash mechanism (#fire_target_flash, an
      # `@ui[:enemy_sprites]` entry), the same two `battle_animation_id`/
      # `entry`-shaped inputs #start_battle_animation already builds from a
      # round's own log entry -- just keyed off `req[:target]` (the command's
      # own troop-member param) directly instead of an entry's
      # `target_index`, since a battle page names its target explicitly
      # rather than inheriting it from whichever action just landed. Called
      # from Scene::Map#start_map_animation, which every battle-page-issued
      # Show Battle Animation request (`req[:battle]`) dispatches to.
      #
      # `req[:allies]` is RPG2003's own Ally/Enemy target-type flag
      # (Interpreter#do_show_battle_animation_b) -- an ally-targeted
      # animation gets no `target_index` at all, the same convention every
      # ally-targeted battle-round entry already uses (`@enemies.index` in
      # Game::Battle returns nil for a party member), which in turn is why
      # #battle_animation_pixel's own nil-sprite branch already falls back to
      # screen-centre: RPG2000's battle draws no on-screen ally sprite to
      # target at all.
      #
      # A `target` of -1 is a reference implementation's "whole side" sentinel,
      # not independently confirmed against genuine RPG_RT under wine: the
      # animation
      # plays over every living troop member at once -- every living enemy
      # when the ally flag is clear, or a single screen-centre animation (the
      # same ally-side fallback above) when it is set, since RPG2000's
      # front-view battle draws no ally sprite to point at.
      # A single-target request (`req[:target] >= 0`) no-ops when the index
      # names no actual party/troop slot -- ported from a reference
      # implementation's
      # source, not independently confirmed against genuine RPG_RT under
      # wine: it leaves the target unresolved (and
      # so never plays the animation at all) for an Ally index
      # (1-based, `target -= 1` first) outside the party's bounds, or an
      # Enemy index outside the troop's bounds -- both plain party/troop
      # array bounds checks, dead members included; that reference
      # implementation never consults liveness here. `#start_battle_page_animation` used to
      # draw an out-of-range Ally target at screen-centre regardless
      # (`elsif req[:allies]` never even looked at the index) and an
      # out-of-range Enemy target through `#battle_animation_pixel`'s own
      # "no sprite" fallback, which is also screen-centre -- neither path
      # ever no-op'd. A per-slot battle-event page reused across encounters
      # with different party/troop sizes (e.g. an "Ally 4" animation on a
      # 3-member party) flashed a spurious screen-centre animation, and
      # stalled the page for the animation's own duration on a "wait for
      # completion" request, where real RPG_RT plays nothing and falls
      # through the same tick.
      def battle_page_target_resolves?(req)
        return true unless req[:target] && req[:target] >= 0
        if req[:allies]
          idx = req[:target] - 1
          idx >= 0 && idx < @state.party.actors.size
        else
          req[:target] < (@ui[:foes] || []).size
        end
      end

      def start_battle_page_animation(req)
        return nil unless battle_page_target_resolves?(req)
        targets =
          if req[:target] && req[:target] < 0
            whole_side_anim_targets(req[:allies])
          elsif req[:allies]
            [@map.anim_target(SCREEN_W / 2, SCREEN_H / 2, height: nil, index: nil,
                              flash_target: nil)]
          else
            tx, ty, height = battle_animation_pixel(target_index: req[:target])
            [@map.anim_target(tx, ty, height: height, index: req[:target],
                              flash_target: nil)]
          end
        @map.build_animation(req[:animation], targets, true)
      end

      # The target descriptors for a whole-side Show Battle Animation: one per
      # living, on-screen troop member. Skips slots with no sprite (a hidden
      # troop member -- #build_battle_sprites never created one) and any member
      # now out of play (dead or fled -- its sprite is hidden, its index still
      # present in `@ui[:enemy_sprites]`); the remaining sprites' live on-screen
      # positions are what the animation is drawn over, and their indices are
      # what a flash_scope-1 / screen_shaking-1 timing pulses. Ally-side
      # animations get no on-screen sprite in RPG2000's front view, so the
      # whole side collapses to the single screen-centre fallback.
      def whole_side_anim_targets(allies)
        return [@map.anim_target(SCREEN_W / 2, SCREEN_H / 2, height: nil, index: nil,
                                 flash_target: nil)] if allies
        sprites = @ui[:enemy_sprites] || []
        foes = @ui[:foes] || []
        out = []
        sprites.each_with_index do |spr, i|
          foe = foes[i]
          next if spr.nil? || (foe && foe.out_of_play?)
          bmp = spr.bitmap
          next unless bmp
          out << @map.anim_target(spr.x + bmp.width / 2, spr.y + bmp.height / 2,
                                  height: bmp.height, index: i, flash_target: nil)
        end
        out
      end

      # Close out an animated round: clear the commands, drop the action banner,
      # and branch to the result window or the next command phase.
      def finish_round_animation
        battle = @ui[:battle]
        # `end_round` clears every ally's `defending` for the new round --
        # revert any sprite still showing the Defend pose from the round
        # that just ended, snapshotted here since `#end_round` itself wipes
        # the flag this reads (#reposition_actor_sprite is a no-op when
        # there are no alternate-layout actor sprites to begin with). Anyone
        # felled during the round just gone needs the same catch-up onto
        # the Dead pose -- `dead?` itself survives `#end_round` untouched,
        # so it is read after rather than snapshotted before.
        defenders = @ui[:allies].select(&:defending)
        battle.end_round
        (defenders + @ui[:allies].select(&:dead?)).uniq { |a| a.object_id }
          .each { |ally| reposition_actor_sprite(ally) }
        close_battle_action
        if battle.finished?
          enter_battle_result(battle.result)
        else
          @ui[:actor_i] = 0
          @ui[:cmd] = 0
          @ui[:phase] = :command
          # A new turn re-arms every page: RPG2000 fires a battle page once per
          # turn in which its condition holds, not once per battle.
          @ui[:pages_run] = {}
          open_next_command unless run_battle_events
        end
      end

      # -- battle-event pages --------------------------------------------------

      # Start the next troop battle-event page whose condition holds and that has
      # not yet fired this turn, switching to the :event phase. Returns whether a
      # page was started, so the caller knows whether to draw the command window
      # or hand the frame to the event. A troop that scripts nothing, or whose
      # pages have all fired, simply returns false.
      #
      # `return_phase` is where #leave_battle_event_phase resumes once the page
      # (and any chained page after it) finishes: `:command` for the between-
      # rounds check (the default -- the normal case, opening the next round's
      # command menu), `:animate` for the between-battlers check
      # (#drive_battle_animate), which needs to pick back up mid-round rather
      # than restart the command phase.
      #
      # `source` is the battler this page check runs *for* -- the battle's
      # #acting_battler at a battler's action boundary (see
      # Game::BattlePage.active?), which gates the per-battler turn_* /
      # command_actor conditions on that battler. A round-boundary check (the
      # default, no source) leaves them ungated.
      def run_battle_events(return_phase = :command, source = nil)
        ui = @ui
        return false unless ui && ui[:troop].pages
        matched = Game::BattlePage.select_all(ui[:troop].pages, @state.switches,
                                              @state.variables, ui[:battle], source)
        entry = matched.find { |(id, _)| !ui[:pages_run][id] }
        return false unless entry
        ui[:pages_run][entry[0]] = true
        cmds = entry[1].event
        return run_battle_events(return_phase, source) if cmds.nil? || cmds.empty? # empty page: try the next
        ui[:events].battle = ui[:battle]
        ui[:events].battle_source = source
        ui[:events].start(cmds)
        ui[:event_return_phase] = return_phase
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
        it = @ui[:events]
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
        when :animation then @map.drive_map_animation(it)
        when :wait
          @ui[:event_timer] ||= @map.frames_from_tenths(it.wait_frames)
          if @ui[:event_timer] <= 0
            @ui[:event_timer] = nil
            it.resume
          else
            @ui[:event_timer] -= 1
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
        unless @ui[:event_win]
          lines = it.wait_kind == :choice ? it.choice_labels : it.message_lines
          @ui[:event_win] = battle_text_window(lines || [], 340)
          return # shown this frame; take the button from the next one
        end
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        choice = it.wait_kind == :choice
        close_battle_event_window
        choice ? it.choose(0) : it.resume
      end

      def close_battle_event_window
        return unless @ui && @ui[:event_win]
        @ui[:event_win].dispose
        @ui[:event_win] = nil
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
        kills = it.take_monster_kills
        kills.each { play_monster_kill_se }
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
        member = @ui[:troop].members[index]
        return unless member && member.hidden
        member.hidden = false
        # Bring the combatant into the fight as well, not just the sprite: until
        # now it took no turn and could not be targeted (Combatant#out_of_play?).
        foe = @ui[:battle].enemy(index)
        foe.hidden = false if foe
        bmp = battler_bitmap(member)
        spr = Sprite.new
        spr.bitmap = bmp
        spr.x = member.x - bmp.width / 2
        spr.y = battler_y(member, bmp)
        spr.z = battler_z(index)
        spr.opacity = battler_opacity(member)
        dispose_battle_sprite(@ui[:enemy_sprites][index])
        @ui[:enemy_sprites][index] = spr
      end

      # Force Flee: the troop member ran, so drop its sprite. Game::Battle has
      # already hidden the combatant (which takes it out of play without counting
      # as a kill), and the troop member's own flag is set so a later rebuild does
      # not draw it again.
      def remove_fled_monster(index)
        member = @ui[:troop].members[index]
        member.hidden = true if member
        dispose_battle_sprite(@ui[:enemy_sprites][index])
        @ui[:enemy_sprites][index] = nil
      end

      # The escape sound RPG_RT plays when a Force Flee sends enemies running.
      def play_escape_se
        play_system_se(SFX_ESCAPE)
      end

      # The kill sound a reference implementation's own scripted
      # Change-Monster-HP handling plays directly the instant a
      # scripted Change Monster HP finishes a troop member off --
      # ported from that reference implementation,
      # not independently confirmed against genuine RPG_RT under
      # wine -- the same cue an ordinary
      # lethal Attack/Skill already gets via #play_battle_action_se's own
      # `entry[:defeated]` check, which this event-command path never
      # produces an `entry` for.
      def play_monster_kill_se
        play_system_se(SFX_ENEMY_DEATH)
      end

      # Terminate Battle: leave the fight with no victory / defeat processing.
      # Returns whether the battle was ended, so the caller stops driving it.
      def finish_terminated_battle
        return false unless @ui[:battle].terminated?
        close_battle_event_window
        finish_battle(:abort)
        true
      end

      # The running page finished: fire the next matching page (chained pages
      # keep the same return_phase, so a battler-boundary check that opens
      # several pages in a row still resumes mid-round rather than jumping to
      # the command phase partway through), or hand the turn back — to the
      # result window when the page decided the fight, to the mid-round
      # animation loop when this page was a between-battlers check, otherwise
      # to the party's command phase (a between-rounds check, the default).
      def leave_battle_event_phase
        close_battle_event_window
        return_phase = @ui[:event_return_phase] || :command
        return if run_battle_events(return_phase)
        battle = @ui[:battle]
        if battle.finished?
          enter_battle_result(battle.result)
        elsif return_phase == :animate
          @ui[:phase] = :animate
        else
          @ui[:phase] = :command
          enter_command_phase
        end
      end

      def enter_battle_result(result)
        @ui[:result] = result
        @map.play_victory_bgm if result == :victory
        lines = battle_result_lines(result, @ui[:troop])
        [@ui[:status_win], @ui[:cmd_win]].each { |w| w.dispose if w }
        @ui[:status_win] = nil
        @ui[:cmd_win] = nil
        open_battle_result(lines)
        @ui[:phase] = :result
      end

      def drive_battle_result
        return unless Input.trigger?(Input::C) || Input.trigger?(Input::B)
        finish_battle(@ui[:result])
      end

      # Close the battle and hand the outcome back to the event. A defeat in an
      # encounter whose defeat mode is "game over" (rather than a [Defeat]
      # handler) ends the game instead of resuming the event; every other outcome
      # — victory, escape, or a defeat with a custom handler — resumes it. Hands
      # the outcome to whichever interpreter actually opened this fight
      # (`@owner` -- the foreground by default, or a Parallel
      # Process's own interpreter, see Scene::Map#drive_battle), captured before
      # #dispose clears @ui out from under it (via Scene::Map#close_battle,
      # which drops the map's own @battle reference too).
      #
      # A random encounter's wipe with an active RPG2003 Death Handler
      # (`@req[:random]` and `!@req[:defeat_game_over]`, see Interpreter
      # #start_random_battle) is neither of those two outcomes: it skips the
      # Game Over screen the way any other non-"game over" defeat does, but
      # then runs the death handler itself (Interpreter#start_death_handler)
      # in place of the ordinary "resume the event that opened this" a
      # scripted encounter's own [Defeat] handler would get -- a random
      # encounter has no such event to resume into.
      def finish_battle(result)
        # Persist the party's post-battle HP (and any knock-outs) before leaving
        # the fight, so damage taken sticks and a downed member stays down.
        @ui[:battle].apply_to_party
        # Capture the fight's own round count (Game::Battle#turn, its live
        # @rounds counter) before #dispose discards the Battle object --
        # this is RPG2000's "turns passed in latest battle" (Game::State
        # #last_battle_turns, LCF inventory chunk 109 field 41).
        @state.last_battle_turns = @ui[:battle].turn
        # Tally the Control Variables "Other" battle counters here, together and
        # unconditionally, matching a reference implementation's own
        # end-of-battle handling: the battle-count tally runs for every result
        # (victory/escape/defeat/abort alike) before the individual win/escape/
        # defeat counter and before the game-over dispatch that can follow a
        # defeat -- not scattered across the moment the encounter is armed (long
        # before the fight has actually concluded) and a resume path a
        # game-over-ending defeat skips entirely.
        @state.battle_count += 1
        case result
        when :victory then @state.win_count += 1
        when :defeat  then @state.defeat_count += 1
        when :escape  then @state.escape_count += 1
        end
        # A defeat in "game over" mode (no custom [Defeat] handler) with the whole
        # party knocked out ends the game; every other outcome resumes the event.
        game_over = result == :defeat && @req[:defeat_game_over] &&
                    @state.party.all_dead?
        death_handler = result == :defeat && @req[:random] &&
                        !@req[:defeat_game_over] && @state.party.all_dead?
        owner = @owner
        @map.close_battle
        if game_over
          @map.perform_game_over(owner)
        else
          @map.restore_pre_battle_bgm
          owner.resume_battle(result)
          owner.start_death_handler if death_handler
        end
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
        want_crit = e[:critical] ? true : false
        start = want_start && battle_start_line(t, e, want_start)
        result = want_result && battle_result_line(t, e)
        crit = want_crit &&
               Game::States::BattleText.critical(t, e[:target_ally] ? true : false)
        # All or nothing per entry: a half-translated line ("スライムの攻撃！"
        # with no damage sentence under it) reads worse than the composed
        # English, so a blank term drops the whole entry back to the fallback
        # — which already carries the crit note itself (`battle_action_line`'s
        # ' (critical!)' suffix), so a blank `actor_critical` / `enemy_critical`
        # loses nothing by falling back whole.
        return [battle_action_line(e)] if (want_start && !start) ||
                                          (want_result && !result) ||
                                          (want_crit && !crit)
        lines = []
        lines << start if start
        lines << crit if crit
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
        lines = skill_start_lines(e, row, caster)
        return [battle_action_line(e)] if lines.empty?
        t = db.respond_to?(:term) ? db.term : nil
        rest = battle_skill_result(t, row, e)
        return [battle_action_line(e)] unless rest
        lines + rest
      rescue StandardError => ex
        $stderr.puts "[RPG2k] skill message lookup failed: #{ex.message}"
        [battle_action_line(e)]
      end

      # The opening line(s) of a skill's log entry: the *casting item's own*
      # generic "used it!" line when a special/use_skill battle item invoked
      # this skill and left its own `using_message` field (item schema field
      # 51 -- distinct from the skill-only `using_message1`/`using_message2`
      # string fields) at the database default 0, else the skill's own
      # sentence(s) (`#skill_start`).
      #
      # Ported from a reference implementation's actual C++ source, not
      # independently confirmed against genuine RPG_RT under wine: it
      # checks whether the casting item exists and its own `using_message`
      # is 0 **before** ever looking at the skill's own `using_message1`/
      # `using_message2`, using the item's own start message instead when
      # that guard holds.
      # falling through to the skill's own sentence only once that guard
      # fails -- i.e. only when the item sets `using_message` nonzero. Since
      # `mruby-lcf/mrblib/schema.rb`'s item `using_message` field defaults to
      # 0, an ordinary skill-casting item left at its editor default (the
      # common case) opens with its own name ("リトはやくそうを使った！"), not
      # the skill's borrowed sentence. This used to unconditionally take the
      # skill's own two sentences for *every* item-invoked skill regardless
      # of the item's `using_message` flag -- the item's own message was
      # database data this build read (`Game::Party#skill_hit`'s `sk.hit ==
      # -1` fallback already proves the pattern of respecting such sentinels)
      # but never actually consulted here.
      #
      # A skill cast from the Skill menu itself carries no `item_id` at all,
      # so it is untouched: it always takes its own sentence, matching
      # `GetStartMessage`'s `item` being null in that case. An `item_id` the
      # database no longer has a row for (a dangling id) falls back the same
      # way -- there is no real `item` to read `using_message` off, so this
      # degrades to the skill's own sentence rather than a blank item name,
      # matching this codebase's usual dangling-id-degrades-gracefully rule.
      def skill_start_lines(e, row, caster)
        bt = Game::States::BattleText
        it = e[:item_id] && @state.party.db_item(e[:item_id])
        if it
          uses_skill_message = it.respond_to?(:using_message) && (it.using_message || 0) != 0
          unless uses_skill_message
            t = db.respond_to?(:term) ? db.term : nil
            line = bt.item_start(t, caster, it.name.to_s)
            return line ? [line] : []
          end
        end
        bt.skill_start(row, caster)
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
          if e[:switch_id]
            # A switch item always "does something" (flips its switch), even
            # though it restores no HP/MP and cures nothing -- unlike a
            # medicine it never "achieves nothing", so it is just the "used
            # it!" line alone, the same silent flip the field menu shows.
            []
          elsif skill_achieved_nothing?(e)
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
      # RPG2000 has none for it — a skill or an item names itself instead
      # (`#battle_skill_body`/`#skill_start_lines`, `#battle_item_body`), and
      # "does nothing" is a state's own sentence rather than a term.
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
          body = if !parts.empty? then "+#{parts.join(' / ')}"
                 elsif e[:switch_id] then 'switch on'
                 else 'no effect'
                 end
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
      # The per-turn state reminder line (Combatant#turn_state_message, via
      # `entry[:state_message]`) opens the banner, ahead of the action's own
      # lines -- ported from a reference implementation's source, not
      # independently confirmed against genuine RPG_RT under wine: it shows
      # it right at the start of the battler's turn, before whatever it goes on
      # to do. A blank reminder (a healed state with no configured
      # `message_recovery`, which that reference implementation still
      # flashes for but has no text to show) is dropped rather than rendered
      # as an empty line.
      def battle_action_lines(entry)
        lines = battle_action_body(entry) + battle_state_lines(entry)
        msg = entry[:state_message]
        msg && !msg.empty? ? [msg] + lines : lines
      end

      # The result window's text: the outcome, and on a win the EXP / gold gained
      # (granted here). RPG2000 shows this after the fight before returning to the
      # map. The headline is the database's own wording -- the 用語 table's
      # `victory` / `defeat` fields, the same table (and the same "falls back to
      # composed English when the database leaves it blank" rule)
      # Game::States::BattleText already reads every per-action line from.
      # The EXP / gold / item lines are composed from their own terms too now
      # (`exp_received`, the `gold_received_a` / `_b` pair, `item_received`),
      # ported from a reference implementation's actual C++ source rather
      # than guessed at (not independently confirmed against genuine RPG_RT
      # under wine): its stock-RPG2000 (non-Maniac-Patch)
      # branch -- `exp << terms.
      # exp_received` (no separating space outside the RPG2k3-English
      # release), `terms.gold_recieved_a << " " << money << terms.gold <<
      # terms.gold_recieved_b`, `item_name << terms.item_recieved`. These
      # three term fields were parsed by the schema and never read anywhere
      # in `mruby-rpg2k` before now, so a game that customised them (a
      # translation, a non-English original) showed this codebase's
      # hardcoded English regardless.
      #
      # A level-up (and any skill the growth table teaches at it) is
      # announced too now, the missing half of the same gap: a reference
      # implementation builds the EXP/gold/item summary as one
      # page, then applies each active ally's exp gain right
      # after it, which is exactly `Game::Interpreter#do_change_exp`'s own
      # gain_exp-then-announce shape (`queue_level_up_messages`,
      # `mrblib/interpreter.rb`) -- so each actor's level/skill snapshot is
      # taken here the same way, right before its own `#gain_exp`. Unlike
      # that interpreter path (still the documented "plain English line for
      # now" simplification), this screen already reads real database terms
      # for every other line, so `#battle_level_up_message` /
      # `#battle_skill_learned_message` below do too, built from that
      # reference implementation's
      # stock-RPG2000/CP932 branch: `name <<
      # "は" << terms.level << " " << new_level << " " << terms.level_up` and
      # `skill.name << terms.skill_learned` (no actor name -- it always
      # follows that actor's own level-up line, same as here). RPG_RT shows
      # these on their own page per actor rather than inline with the EXP
      # tally; this screen has no per-page window, only one flat line list
      # for the whole result, so they are appended to that list instead, in
      # the same after-the-tally order the real sequence uses.
      def battle_result_lines(result, troop)
        return [term(:escape_success, 'Escaped!')] if result == :escape
        return [term(:defeat, 'The party was defeated...')] unless result == :victory
        exp = troop.total_exp
        gold = troop.total_gold
        @state.party.gain_gold(gold)
        lines = [term(:victory, 'Victory!')]
        lines << "#{exp}#{term(:exp_received, ' EXP gained.')}" if exp > 0
        if gold > 0
          lines << "#{term(:gold_received_a, 'Found')} #{gold}#{term(:gold, 'G')}" \
                   "#{term(:gold_received_b, '.')}"
        end
        # Each defeated enemy may drop its treasure item (rolled on the battle's
        # own RNG); grant it to the bag and name it in the result window.
        troop.drops(@ui[:battle].rng).each do |iid|
          @state.party.gain_item(iid, 1)
          it = @state.party.db_item(iid)
          name = it ? it.name : "item #{iid}"
          lines << "#{name}#{term(:item_received, ' obtained.')}"
        end
        @state.party.actors.each do |a|
          # A KO'd party member earns nothing from the victory -- a reference
          # implementation's own EXP-granting loop iterates only the active
          # battlers, not the raw roster, excluding anyone hidden, dead, or
          # not in the party.
          next if a.respond_to?(:dead?) && a.dead?
          before_level = a.respond_to?(:level) ? a.level : nil
          before_skills = a.respond_to?(:skills) ? a.skills.dup : []
          a.gain_exp(exp)
          lines.concat(battle_level_up_lines(a, before_level, before_skills)) if before_level
        end
        lines
      end

      # Level-up (and, for each level, any growth-table skill it teaches)
      # lines for one actor's post-battle EXP gain, mirroring
      # `Game::Interpreter#queue_level_up_messages`'s own before/after skill
      # comparison: `before_skills` is that actor's skill list snapshotted
      # right before `#gain_exp`, so a skill already known (an earlier
      # explicit Change Skill teach) is told apart from one this exact gain
      # just taught. Returns [] when the level did not rise.
      def battle_level_up_lines(actor, before_level, before_skills)
        return [] if actor.level <= before_level
        lines = []
        ((before_level + 1)..actor.level).each do |lv|
          lines << battle_level_up_message(actor, lv)
          next unless actor.respond_to?(:learn_table)
          actor.learn_table.each do |sid, at|
            next unless at == lv && !before_skills.include?(sid)
            sk = @state.party.db_skill(sid)
            lines << battle_skill_learned_message(actor, sk) if sk
          end
        end
        lines
      end

      # The one line a level-up announces, built from the database's own
      # `level`/`level_up` terms the way a reference implementation's
      # stock/CP932 branch does (see `#battle_result_lines`'s own
      # comment) -- falls back to composed English, matching every other
      # line on this screen, only when the database leaves `level_up` blank
      # (a raw `level_up` term with no `level` term set still gets the
      # 'Lv' stand-in rather than losing the whole line to English).
      def battle_level_up_message(actor, level)
        up = term(:level_up, nil)
        return "#{actor.name} is now level #{level}!" unless up
        "#{actor.name}は#{term(:level, 'Lv')} #{level} #{up}"
      end

      # The one line a newly-learned skill announces, immediately following
      # its level's own line above -- a reference implementation's
      # stock/CP932 branch names only the skill, never the actor,
      # since it always trails that actor's own level-up line the way it
      # does here too. Falls back to composed English (which does name the
      # actor, since a database leaving `skill_learned` blank gets no
      # level-up line's context to lean on either) when the term is blank.
      def battle_skill_learned_message(actor, sk)
        learned = term(:skill_learned, nil)
        return "#{actor.name} learned #{sk.name}!" unless learned
        "#{sk.name}#{learned}"
      end

      # RPG_RT's battle windows share one fixed panel: a 320x80 strip along
      # the bottom edge with 16px rows -- not the content-fitted, 14px-row
      # windows this screen used to draw. The panel's own outer rect (x=0,
      # y=screen_height-80, w=320, h=80) is independently confirmed against
      # genuine RPG_RT.exe under wine -- see #battle_text_window's own
      # citation for the capture, run on this same window shape. The 16px
      # row pitch matches this screen's own message-window `MSG_LINE_H`,
      # itself measured directly off a wine capture rather than assumed
      # (scene/map.rb#draw_shop_command_prompt's own citation, cycle #148).
      BATTLE_LINE_H = 16
      BATTLE_PANEL_Y = SCREEN_H - 80
      BATTLE_PANEL_H = 80
      # The actor-command window (and the Battle/Auto Battle/Escape options
      # window, which shares its rect) is a fixed 76px, ported from a
      # reference implementation, not independently confirmed against
      # genuine RPG_RT under wine; the status window takes the rest of the
      # row.
      BATTLE_CMD_W = 76
      BATTLE_STATUS_W = SCREEN_W - BATTLE_CMD_W
      # The enemy target list (`CreateBattleTargetWindow`) is a fixed 136px, and
      # only ever covers the status window's footprint -- the per-actor command
      # window stays on screen beside it. Target selection only ever happens
      # from the per-actor command phase (Attack/a targeted Skill/Item), never
      # from the options window, so the status window's footprint here is
      # always its command-phase one (#battle_status_x's `0`).
      BATTLE_TARGET_W = 136
      # How many rows fit at once: the panel's fixed 64px content area (80
      # minus the 8px border on each side) divided by the 16px row height. A
      # longer Item/Skill list scrolls past this, keeping the cursor's row in
      # view (`#move_battle_list_index`); the enemy-target list does not --
      # see #drive_battle_target's own comment (cycle #131) -- a troop with
      # more living members than this cannot have the extra ones targeted by
      # the player's cursor at all, real RPG_RT included.
      BATTLE_VISIBLE_ROWS = 4
      # The battle Item/Skill lists are a two-column grid, not a single
      # stacked column -- ported from a reference implementation's source,
      # not independently confirmed against genuine RPG_RT under wine: its
      # item and skill windows both set a two-column layout in their own
      # constructors, and the battle screen backs its item/skill windows
      # with exactly those classes. The enemy-target list (single column)
      # and the ally-target list (hand-rolled) are correctly single-column
      # already -- this constant is
      # only for #draw_battle_item/#draw_battle_skill.
      BATTLE_LIST_COLUMN_MAX = 2

      # Column origins within the status panel's contents, in the order
      # a reference implementation's battle status window uses them: who,
      # what condition they
      # are in, then the gauges. The condition column is why this window is
      # laid out in columns at all — a state is drawn in its *own* palette
      # colour, which a single `draw_text` of a whole line cannot do.
      # Ported from that reference implementation's source, not
      # independently confirmed against
      # genuine RPG_RT under wine: RPG2k
      # branch: name at 4, state at 86, HP at 142, SP at 202 for a party
      # with no maxima over 999.
      #
      # "For a party with no maxima over 999" is a real ceiling, not a rounding
      # note: the panel itself is a fixed 244px (`BATTLE_STATUS_W`, RPG_RT's own
      # screen width minus its fixed 76px command box), so the SP column only
      # ever has `inner content width (228) - 202 = 26px` before the panel's own
      # right border -- nowhere near "SP 999/999"'s ~66px, and not even quite
      # enough for a plain "SP 50/50". `#battle_status_window` clips every
      # column's text to the gap before the *next* column (or the panel's own
      # edge, for SP) rather than trusting it to fit, so an actor with generous
      # HP/SP -- or simply a widescreen font -- truncates cleanly instead of
      # spilling into its neighbour's cell.
      STATUS_NAME_X  = 4
      STATUS_STATE_X = 86
      STATUS_HP_X    = 142
      STATUS_MP_X    = 202

      # The status panel's own x, mirroring a reference implementation's own
      # window-positioning logic, not independently confirmed against
      # genuine RPG_RT under wine:
      # three windows -- the options window, the status window, then the
      # per-actor command window -- sit left-to-right, but only one of the
      # two 76px command-shaped windows is ever showing at once, so the
      # status window slides to whichever side is free. During the top-level
      # Battle/Auto Battle/Escape choice (`@ui[:phase] == :battle_options`)
      # the options window takes the left slot (x=0) and the status window
      # is pushed to `BATTLE_CMD_W`; once an actor is choosing Attack/Skill/
      # Defend/Item the per-actor command window takes the *right* slot
      # instead (`#draw_battle_command`'s own `BATTLE_STATUS_W`) and the
      # status window returns to x=0.
      def battle_status_x
        @ui[:phase] == :battle_options ? BATTLE_CMD_W : 0
      end

      # Rebuild the status panel: the party's HP and SP, each with the one
      # condition a reference implementation's own source shows — the
      # significant state, or the
      # database's "normal" term when there is none (ported from that
      # reference implementation's
      # source, not independently confirmed against genuine RPG_RT under
      # wine) — so a status inflicted by a skill or
      # by a battle page's Change Monster Condition is visible rather than only
      # simulated. RPG2000 is front-view: the enemy troop is never listed here
      # (that reference implementation builds exactly one status window,
      # defaulted to not showing enemies) -- it is represented only by its
      # battler
      # sprites and, when targeted, by the target window's name list. The row
      # of whichever actor is currently being commanded gets the cursor,
      # mirroring a reference implementation's own actor-select cursor
      # update.
      #
      # `battle_type` 2 (gauge, `#gauge_battle_layout?`) replaces this whole
      # panel with RPG2003's face/bar "gauge card" layout instead
      # (`#battle_status_gauge_window`) -- `battle_type` 1 (alternative) is
      # unchanged, and still builds the same text rows this always has, since
      # only 2 asks for the card presentation (a reference implementation
      # branches the same way, on
      # the gauge battle type specifically, not on "not
      # traditional"). Falls back to the text rows when the gauge window
      # cannot be built (no System2 graphic, or a failed load) rather than
      # leaving the panel blank.
      def refresh_battle_status
        @ui[:status_win].dispose if @ui[:status_win]
        win = battle_status_gauge_window(@ui[:allies]) if gauge_battle_layout?
        @ui[:status_win] = win || begin
          rows = @ui[:allies].map { |a| battle_status_row(a) }
          # No row highlighted while the options window is open -- matching
          # `status_window->SetIndex(-1)` in `ProcessSceneActionFightAutoEscape`'s
          # own `eMoveWindow` substate; nobody is "the acting actor" until
          # Battle or Auto Battle is chosen.
          idx = @ui[:phase] == :battle_options ? nil : @ui[:allies].index(current_actor)
          battle_status_window(rows, idx)
        end
      end

      # Whether the database's `battlecommands.battle_type` is specifically 2
      # (gauge) -- distinct from `Game::Party#alternate_battle_layout?`, which
      # is also true for the plain sprite-only layout (1) and still uses the
      # unchanged text status window for that case. A bare test fixture (or
      # any database `#alternate_battle_layout?` itself already reads false
      # for) reads false here too.
      def gauge_battle_layout?
        @state.party.respond_to?(:gauge_battle_layout?) && @state.party.gauge_battle_layout?
      end

      # One party member's row as [text, x, colour index] segments: name,
      # condition, then the HP / SP gauges. The HP/MP segments carry three
      # extra trailing fields (cur, max, can_knockout) that #battle_status_window
      # uses to recolor just the current-value figure -- the name/state
      # segments leave them nil (a 3-element array, same as always), which
      # the shared drawing loop's destructuring already tolerates.
      def battle_status_row(b)
        hp = b.hp < 0 ? 0 : b.hp
         [[b.name, STATUS_NAME_X, 0], battle_state_segment(b),
          ['HP', STATUS_HP_X, 0, hp, b.display_max_hp, true],
          ['MP', STATUS_MP_X, 0, b.mp, b.display_max_mp, false]]
      end

      # The condition column, as a status-panel segment: the same reading the
      # field windows draw (Scene::Base#state_display), placed in its column.
      def battle_state_segment(b)
        text, color = state_display(b.states)
        [text, STATUS_STATE_X, color]
      end

      # `Window_BattleStatus`'s own default `actor_face_height` (24) -- the
      # small-window variant (14) is `battlecommands.window_size`, which
      # schema.rb has not decoded yet (see this change's changelog entry), so
      # every gauge card always uses the large-window offset.
      ACTOR_FACE_HEIGHT = 24

      # The gauge card layout (`battle_type` 2): one 80px-wide card per party
      # member -- face, HP/SP bars and digit-glyph numbers, drawn straight
      # from the database's own System2 graphic -- ported column-for-column
      # from a reference implementation's real gauge-card drawing
      # (the equivalent gauge-battle-type branch) --
      # ported from that reference implementation's source, not
      # independently confirmed against
      # genuine RPG_RT under wine. Borderless like that reference
      # implementation's own gauge
      # window ("simulate a borderless window...
      # makes the implementation on scene-side easier"), and never gets a
      # cursor rect: no row is ever highlighted here, unlike the
      # text status window's acting-actor cursor. The ATB/wait gauge row
      # that reference implementation also draws
      # is skipped -- this runtime has no ATB/wait-timer
      # subsystem to read a value from. Returns nil (so `#refresh_battle_status`
      # falls back to the plain text rows) when the database names no System2
      # graphic, or names one that fails to load -- there is no sensible
      # placeholder gauge sprite sheet the way there's a placeholder colour
      # block for a missing battler graphic.
      def battle_status_gauge_window(allies)
        system2 = battle_system2_bitmap
        return nil unless system2
        inner_w = BATTLE_STATUS_W - Window::BORDER * 2
        inner_h = BATTLE_PANEL_H - Window::BORDER * 2
        win = Window.new(battle_status_x, BATTLE_PANEL_Y, BATTLE_STATUS_W, BATTLE_PANEL_H)
        win.z = 300
        win.transparent = true
        c = Bitmap.new(inner_w, inner_h)
        allies.each_with_index { |ally, i| draw_battle_gauge_card(c, system2, ally, i) }
        win.contents = c
        win
      end

      # One party member's gauge card at column `i`. `ally` is a
      # `Game::Battle::Combatant` (`Game::Battle.from_actor`) -- its `.actor`
      # is the underlying `Game::Actor`, the only place `faceset_name`/
      # `faceset_index` (chunk 11 fields 15/16, including any Change Actor
      # Face override) live. Ported from `RefreshGauge`'s own gauge-card
      # block: the face, then the bar's left cap / stretched centre / right
      # cap at `System2` (0,32,16,48)/(16,32,16,48)/(32,32,16,48), then the
      # HP row (`which` 0) and SP row (`which` 1) fills and numbers -- the
      # exact x/y arithmetic (`32 + 80*i`, `40 + 80*i`, `y + 12 + 4`) is
      # copied from the real source rather than re-derived.
      def draw_battle_gauge_card(c, system2, ally, i)
        draw_battle_gauge_face(c, ally.actor, i)
        x = 32 + i * 80
        y = ACTOR_FACE_HEIGHT
        c.blt x, y, system2, Rect.new(0, 32, 16, 48)
        x += 16
        fill_x = x
        c.stretch_blt Rect.new(x, y, 25, 48), system2, Rect.new(16, 32, 16, 48)
        x += 25
        c.blt x, y, system2, Rect.new(32, 32, 16, 48)
        hp = ally.hp < 0 ? 0 : ally.hp
        draw_gauge_system2(c, system2, fill_x, y, hp, ally.display_max_hp, 0)
        draw_gauge_system2(c, system2, fill_x, y + 16, ally.mp, ally.display_max_mp, 1)
        num_x = 40 + 80 * i
        draw_number_system2(c, system2, num_x, y, hp)
        draw_number_system2(c, system2, num_x, y + 12 + 4, ally.mp)
      end

      # The card's face portrait -- the same 48x48 FaceSet crop
      # `#load_face_bitmap`/`FACE_SIZE` already draw for the name-entry and
      # message-face screens, just placed at this card's column instead of
      # its own window. Draws nothing (leaving the card's bars/numbers alone)
      # for an actor with no faceset set, or a faceset file that fails to
      # load, the same "a missing portrait shows nothing" rule
      # `#load_face`/`#draw_kana_face` already use -- and, matching every
      # other optional actor field this screen reads (`battler_animation_id`,
      # `battle_x`/`battle_y`), `#respond_to?`-guarded so a bare test fixture
      # actor with no faceset fields at all still draws the rest of the card.
      def draw_battle_gauge_face(c, actor, i)
        return unless actor && actor.respond_to?(:faceset_name)
        face = @map.load_face_bitmap(actor.faceset_name)
        return unless face
        index = actor.respond_to?(:faceset_index) ? (actor.faceset_index || 0) : 0
        src = Rect.new((index % 4) * Map::FACE_SIZE,
                       (index / 4) * Map::FACE_SIZE,
                       Map::FACE_SIZE, Map::FACE_SIZE)
        c.blt 80 * i, ACTOR_FACE_HEIGHT, face, src
      end

      # The HP (`which` 0) or SP (`which` 1) bar fill: a `25 * cur / max`
      # wide stretch of the fill tile at `System2` `(48, 32 + 16*which, 16,
      # 16)` -- except an exactly-full gauge (`cur == max`) reads the
      # visually distinct "full" fill tile 16px over, at `(64, ...)`,
      # instead of the normal partial-fill one. Ported from
      # `Window_BattleStatus::DrawGaugeSystem2` exactly, including its
      # `max == 0` no-draw guard (a stat with no pool at all, e.g. an actor
      # with 0 max SP, draws no fill for that row).
      def draw_gauge_system2(c, system2, x, y, cur, max, which)
        return if max == 0
        gauge_x = cur == max ? 16 : 0
        width = 25 * cur / max
        c.stretch_blt Rect.new(x, y, width, 16), system2,
                     Rect.new(48 + gauge_x, 32 + 16 * which, 16, 16)
      end

      # Right-aligned up-to-4-digit number in 8x16 glyph cells (`System2`
      # `(digit * 8, 80, 8, 16)`), leading zeros suppressed rather than drawn
      # -- ported from `Window_BattleStatus::DrawNumberSystem2` exactly,
      # including its exact leading-zero cascade: a thousands (or hundreds)
      # digit that comes out to 0 still lets the *next* digit down draw via
      # its own `handle_zero` carry, so 100 draws all three digits ("100")
      # while 7 draws only the ones cell (three blank cells then "7") and 42
      # draws the tens+ones cells ("42", blank above).
      def draw_number_system2(c, system2, x, y, value)
        handle_zero = false
        if value >= 1000
          c.blt x, y, system2, Rect.new((value / 1000) * 8, 80, 8, 16)
          value %= 1000
          handle_zero = true if value < 100
        end
        if handle_zero || value >= 100
          handle_zero = false
          c.blt x + 8, y, system2, Rect.new((value / 100) * 8, 80, 8, 16)
          value %= 100
          handle_zero = true if value < 10
        end
        if handle_zero || value >= 10
          c.blt x + 16, y, system2, Rect.new((value / 10) * 8, 80, 8, 16)
          value %= 10
        end
        c.blt x + 24, y, system2, Rect.new(value * 8, 80, 8, 16)
      end

      # The RPG2003 System2 graphic (gauge fill/caps and the digit glyphs the
      # gauge card draws numbers with) -- one cache entry, keyed by name like
      # every other named battle graphic (`#cached_bitmap`), since a project
      # only ever declares the one in `system.system2_name` (chunk 22 field
      # 20, schema.rb). A blank name or a failed load returns nil (and logs,
      # for the latter) so `#battle_status_gauge_window` falls back to the
      # plain text status row instead of crashing -- unlike
      # `#battler_bitmap`/`#actor_battlecharset_bitmap`, there is no sensible
      # placeholder gauge sprite sheet to draw in its place.
      def battle_system2_bitmap
        name = db.system.respond_to?(:system2_name) ? db.system.system2_name : nil
        return nil unless name && !name.empty?
        cached_bitmap(@system2_cache, name) do
          begin
            Bitmap.new("System2/#{name}", true)
          rescue StandardError => e
            $stderr.puts "[RPG2k] System2 graphic '#{name}' load failed: #{e.message}"
            nil
          end
        end
      end

      # The current actor's command menu — Attack / Skill / Defend / Item, with
      # a cursor. A reference implementation's own source does not put the
      # actor's name in this
      # window at all (it builds it once from the
      # four command terms in that order; ported from that reference
      # implementation's source, not
      # independently confirmed against genuine RPG_RT under wine): the
      # acting actor is shown by the cursor
      # `#refresh_battle_status` puts on their row in the status window instead
      # (a reference implementation's own actor-index cursor). The Skill
      # slot's own
      # label can still change per actor (`#skill_command_label`), the same way
      # a reference implementation updates that one row's item text
      # after the window is built rather than rebuilding the whole thing.
      def draw_battle_command
        actor = current_actor
        return unless actor
        @ui[:cmd_win].dispose if @ui[:cmd_win]
        labels = battle_commands
        win = Window.new(BATTLE_STATUS_W, BATTLE_PANEL_Y, BATTLE_CMD_W, BATTLE_PANEL_H)
        win.z = 320
        win.windowskin = windowskin
        inner_w = BATTLE_CMD_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |label, i|
          c.draw_text 0, i * BATTLE_LINE_H, inner_w, BATTLE_LINE_H, label
        end
        win.contents = c
        win.cursor_rect =
          Rect.new(0, @ui[:cmd] * BATTLE_LINE_H, inner_w, BATTLE_LINE_H)
        @ui[:cmd_win] = win
        refresh_battle_status
      end

      # The Battle/Auto Battle/Escape options window -- the same 76px shape
      # the per-actor command window uses (only one of the two is ever on
      # screen at a time), with `#battle_option_rows`' three entries instead
      # of the usual four, but docked to the *left* edge (x=0) rather than
      # the command window's right one -- a reference implementation's own
      # window-positioning logic lays
      # the options window before the status window, then the status window
      # past it, while the per-actor
      # command window comes after the status window instead. See
      # `#battle_status_x`, which pushes the status panel to `BATTLE_CMD_W`
      # to make room for this window here.
      def draw_battle_options
        @ui[:cmd_win].dispose if @ui[:cmd_win]
        labels = battle_option_rows.map { |r| r[:label] }
        win = Window.new(0, BATTLE_PANEL_Y, BATTLE_CMD_W, BATTLE_PANEL_H)
        win.z = 320
        win.windowskin = windowskin
        inner_w = BATTLE_CMD_W - Window::BORDER * 2
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |label, i|
          c.draw_text 0, i * BATTLE_LINE_H, inner_w, BATTLE_LINE_H, label
        end
        win.contents = c
        win.cursor_rect =
          Rect.new(0, @ui[:opt] * BATTLE_LINE_H, inner_w, BATTLE_LINE_H)
        @ui[:cmd_win] = win
        refresh_battle_status
      end

      # The target-selection menu — the living enemies, with a cursor. Fixed at
      # `CreateBattleTargetWindow`'s own rect: it covers the status window's
      # footprint (not the command window's, which stays on screen beside it).
      def draw_battle_target
        foes = living_foes
        @ui[:target_win].dispose if @ui[:target_win]
        @ui[:target_win] =
          battle_list_window(0, BATTLE_TARGET_W, foes.map(&:name),
                             @ui[:target_i], 330)
      end

      def close_battle_target
        return unless @ui[:target_win]
        @ui[:target_win].dispose
        @ui[:target_win] = nil
      end

      # A bottom-anchored list window of `labels` with the cursor on `sel`, at
      # left edge `x` and width `w`, fixed to the panel's own height (80px, the
      # shape every RPG_RT battle list window shares) — the shared shape of the
      # Skill / Item / target / ally-target menus. `column_max` (1 for every
      # caller except #draw_battle_item/#draw_battle_skill, see
      # `BATTLE_LIST_COLUMN_MAX`) lays `labels` out row-major across that many
      # columns instead of one; a list longer than `BATTLE_VISIBLE_ROWS`
      # *rows* scrolls, keeping `sel`'s own row in view, for a long Item/Skill
      # list. The enemy-target list never actually sends a `sel` past
      # `BATTLE_VISIBLE_ROWS - 1` any more (#drive_battle_target caps it), so
      # this scrolls it in principle only -- real RPG_RT does not scroll that
      # particular list at all, see that method's own comment.
      # `idxs`, parallel to `labels`, is an optional windowskin swatch index
      # per row (0 enabled / 3 disabled, `Scene::Base#draw_system_text`'s own
      # convention) -- nil (every caller except #draw_battle_item/
      # #draw_battle_skill) keeps the plain flat-white `draw_text` every
      # other list here has always used; the item and skill lists are the
      # two that can hold a listed-but-disabled row (see #draw_battle_item /
      # #draw_battle_skill).
      def battle_list_window(x, w, labels, sel, z, column_max: 1, idxs: nil)
        rows = BATTLE_VISIBLE_ROWS
        inner_w = w - Window::BORDER * 2
        col_w = inner_w / column_max
        row_count = column_max > 1 ? [(labels.length / column_max.to_f).ceil, 1].max : labels.length
        sel_row = sel / column_max
        scroll = row_count > rows ? [[sel_row - rows + 1, 0].max, row_count - rows].min : 0
        win = Window.new(x, BATTLE_PANEL_Y, w, BATTLE_PANEL_H)
        win.z = z
        win.windowskin = windowskin
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |label, i|
          row = i / column_max
          next if row < scroll || row >= scroll + rows
          col = i % column_max
          y = (row - scroll) * BATTLE_LINE_H
          if idxs
            draw_system_text(c, col * col_w, y, col_w, BATTLE_LINE_H, label, windowskin, idxs[i])
          else
            c.draw_text col * col_w, y, col_w, BATTLE_LINE_H, label
          end
        end
        win.contents = c
        unless labels.empty?
          sel_col = sel % column_max
          win.cursor_rect = Rect.new(sel_col * col_w, (sel_row - scroll) * BATTLE_LINE_H, col_w, BATTLE_LINE_H)
        end
        win
      end

      # The current actor's battle skills as "Name  cost", with a cursor. Full
      # width, same rect as the item menu — a reference implementation's own
      # skill and item
      # windows cover both the status and command windows while open,
      # ported from that reference implementation's source, not
      # independently confirmed against genuine RPG_RT under wine. A listed
      # but not
      # currently castable skill (see
      # #battle_skill_unavailable?) draws in the windowskin's disabled
      # swatch, matching the field Skill menu and #draw_battle_item just
      # below -- confirmed for the field Skill list directly against a
      # genuine RPG_RT.exe (see Scene::SkillMenu#build_skill_window's own
      # comment for the measured colours); not independently re-verified for
      # this battle-side sibling this session, ported on the strength of
      # sharing the identical `battle_list_window`/`draw_system_text`
      # machinery #draw_battle_item already has confirmed pixel-for-pixel.
      def draw_battle_skill
        @ui[:skill_win].dispose if @ui[:skill_win]
        labels = @ui[:skills].map do |sid, cost|
          sk = @state.party.db_skill(sid)
          "#{sk ? sk.name : "Skill #{sid}"}  #{cost}"
        end
        idxs = @ui[:skills].map do |sid, cost|
          sk = @state.party.db_skill(sid)
          battle_skill_unavailable?(cost, sk) ? 3 : 0
        end
        @ui[:skill_win] = battle_list_window(0, SCREEN_W, labels, @ui[:skill_i], 325,
                                             column_max: BATTLE_LIST_COLUMN_MAX, idxs: idxs)
      end

      def close_battle_skill
        return unless @ui[:skill_win]
        @ui[:skill_win].dispose
        @ui[:skill_win] = nil
      end

      # The party's battle items as "Name  xN", with a cursor. A listed but
      # not battle-usable item (see Game::Party#battle_items) draws in the
      # windowskin's disabled swatch, matching the field Item menu.
      def draw_battle_item
        @ui[:item_win].dispose if @ui[:item_win]
        labels = @ui[:items].map do |id, count|
          it = @state.party.db_item(id)
          "#{it ? it.name : "Item #{id}"}  x#{count}"
        end
        idxs = @ui[:items].map { |id, _count| @state.party.battle_usable?(id) ? 0 : 3 }
        @ui[:item_win] = battle_list_window(0, SCREEN_W, labels, @ui[:item_i], 325,
                                            column_max: BATTLE_LIST_COLUMN_MAX, idxs: idxs)
      end

      def close_battle_item
        return unless @ui[:item_win]
        @ui[:item_win].dispose
        @ui[:item_win] = nil
      end

      # The living party members selectable as a heal target ("Name HP h/mh"),
      # with a cursor -- narrowed by #battle_ally_targets when a pending item's
      # actor_set excludes some of them. A reference implementation's own
      # source reuses the
      # status window itself for this, ported from that reference
      # implementation's source, not independently confirmed against
      # genuine RPG_RT under wine; this screen still draws a
      # separate window, but at the status window's own rect and footprint so
      # it reads the same way -- covering the party's HP display, leaving the
      # command window in view beside it.
      def draw_battle_ally_target
        @ui[:ally_win].dispose if @ui[:ally_win]
        labels = battle_ally_targets.map do |a|
          "#{a.name}  #{a.hp < 0 ? 0 : a.hp}/#{a.display_max_hp}"
        end
        @ui[:ally_win] =
          battle_list_window(0, BATTLE_STATUS_W, labels, @ui[:ally_i], 335)
      end

      def close_battle_ally_target
        return unless @ui[:ally_win]
        @ui[:ally_win].dispose
        @ui[:ally_win] = nil
      end

      # Banner the attack that just landed ("Hero hits Slime for 12", "…
      # defeated!") low on the screen while the round animates, so each action
      # reads on screen as well as its HP tick. Replaced by the next action's
      # banner and dropped when the round settles.
      def show_battle_action(entry)
        show_battle_banner(battle_action_lines(entry))
      end

      # The low action banner itself, shared by a landed hit (#show_battle_action)
      # and a failed Escape attempt: both are transient status text over the
      # still-running fight, replaced by whatever banners next and dropped when
      # the round settles.
      def show_battle_banner(lines)
        @ui[:action_win].dispose if @ui[:action_win]
        @ui[:action_win] = battle_panel_window(lines, 340)
      end

      # The system SFX a landed action plays, alongside its banner. Each check
      # is independent rather than an elsif chain -- a reference
      # implementation's own source
      # plays its own cue for each thing that happened to the same hit, not
      # one sound standing in for all of them: a killing blow plays the
      # damage sound and then the death cry, and an item that lands a hit
      # plays the item's own cue alongside the hit's (that reference
      # implementation fires the damage cue and, on top
      # of a kill, the kill cue, as separate calls rather than one replacing
      # another) -- ported from that reference implementation's source, not
      # independently
      # confirmed against genuine RPG_RT under wine.
      def play_battle_action_se(entry)
        # `attacker_ally` only rides on a plain Attack's own entry (never a
        # skill/item hit -- see Battle#deal_attack), and is `false` rather
        # than absent for an enemy's swing, so this fires before the hit's
        # own resolution SE, matching RPG_RT playing it at the very start of
        # the action.
        play_system_se(SFX_ENEMY_ATTACK) if entry[:attacker_ally] == false
        play_system_se(SFX_DODGE) if entry[:missed]
        if entry[:damage] && entry[:damage] > 0
          play_system_se(entry[:target_ally] ? SFX_ACTOR_DAMAGE : SFX_ENEMY_DAMAGE)
        end
        play_system_se(SFX_ENEMY_DEATH) if entry[:defeated] && !entry[:target_ally]
        play_system_se(SFX_ITEM) if entry[:item_id]
        # An enemy's own AI-chosen Escape basic action plays the same system
        # escape cue the party hears on its own successful Escape command --
        # a reference implementation's own escape-SE logic returns
        # the escape cue whenever the algorithm's *source* is an enemy (an
        # ally's own Escape defers to the base class's silent default
        # instead, played separately by #try_battle_escape). `entry[:fled]`
        # is only ever produced by `#enemy_basic_action`'s BASIC_ESCAPE arm,
        # so it is inherently enemy-only here -- no risk of double-playing
        # this alongside the party's own escape SE.
        play_system_se(SFX_ESCAPE) if entry[:fled]
        # An enemy's own Auto Destruction basic action plays its own
        # explosion cue unconditionally -- a reference implementation's own
        # self-destruct escape-SE logic returns
        # the kill cue with no gate on whether the blast
        # actually defeats anyone, unlike the ordinary post-hit
        # `SFX_ENEMY_DEATH` line just above (`entry[:defeated] &&
        # !entry[:target_ally]`), which can never fire here at all since
        # every self-destruct target is a party member (`target_ally` is
        # always true). `entry[:autodestruct_se]` only ever rides on the
        # first of a multi-target blast's buffered entries (see
        # #enemy_autodestruct's own comment), so this plays exactly once
        # per action, matching RPG_RT.
        play_system_se(SFX_ENEMY_DEATH) if entry[:autodestruct_se]
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
        terms = db.respond_to?(:term) ? db.term : nil
        (entry[:stat_changed] || {}).each do |key, delta|
          term_name = STAT_CHANGE_TERM[key]
          next unless term_name && delta && delta != 0
          lines << (Game::States::BattleText.parameter_change(terms, name, delta, term_name) ||
                    "#{name}'s #{term_name} #{delta > 0 ? 'rose' : 'fell'} by #{delta.abs}")
        end
        attr_ids = entry[:attr_shifted] || []
        unless attr_ids.empty?
          positive = (entry[:attr_shift_dir] || 1) > 0
          props = db.respond_to?(:property) ? db.property : nil
          attr_ids.each do |aid|
            row = props ? props[aid] : nil
            attr_name = row && row.respond_to?(:name) ? row.name : "attribute #{aid}"
            lines << (Game::States::BattleText.attribute_shift(terms, name, positive, attr_name) ||
                      "#{name}'s resistance to #{attr_name} #{positive ? 'rose' : 'fell'}")
          end
        end
        lines
      end

      # The 用語 field naming each ATK/DEF/SPI(mind)/AGI stat itself (as
      # opposed to `Game::Battle::STAT_MOD_FIELD`, which names the Combatant
      # accessor that holds the modifier) -- what #battle_state_lines passes
      # `BattleText.parameter_change` as `points`.
      STAT_CHANGE_TERM = { atk: :attack, def: :defense, spi: :mind, agi: :agility }.freeze

      def state_label(id, table)
        Game::States.name(id, table) || "state #{id}"
      end

      def close_battle_action
        return unless @ui[:action_win]
        @ui[:action_win].dispose
        @ui[:action_win] = nil
      end

      def open_battle_result(lines)
        @ui[:result_win] = battle_panel_window(lines, 320)
      end

      # RPG_RT's own battle message window (the per-action banner, the
      # result panel) is a fixed 320x80 strip at the bottom of the screen --
      # the same rect as the status/command windows it visually replaces
      # while it is up -- not a panel sized to fit its text. This exact rect
      # is independently confirmed against genuine RPG_RT.exe under wine --
      # see #battle_text_window's own citation for the capture; that method
      # draws the identical BATTLE_PANEL_Y/BATTLE_PANEL_H/SCREEN_W rect this
      # one does, just for the battle-event message window rather than the
      # action banner/result panel.
      def battle_panel_window(lines, z)
        inner_w = SCREEN_W - Window::BORDER * 2
        win = Window.new(0, BATTLE_PANEL_Y, SCREEN_W, BATTLE_PANEL_H)
        win.z = z
        win.windowskin = windowskin
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          c.draw_text 0, i * BATTLE_LINE_H, inner_w, BATTLE_LINE_H, line
        end
        win.contents = c
        win
      end

      # A text panel of `lines` at depth `z`, used for the battle-event page
      # message window -- RPG_RT's own fixed 320x80 panel (`BATTLE_PANEL_Y`/
      # `BATTLE_PANEL_H`, the exact rect this file's other battle windows
      # already share -- see their own citation above `BATTLE_PANEL_Y`),
      # never a box sized to fit its content. Confirmed against genuine
      # RPG_RT.exe under wine: Nepheshel's own troop pages never use Show
      # Message (`analyze_game.rb --troops` finds none), so this needed a
      # synthetic turn-0 troop battle-event page injected directly into a
      # copy of the database and a synthetic autostart Enemy Encounter
      # event injected into a copy of a map (both restored afterward) --
      # the resulting screen (640x480 physical, RPG2000's 320x240 logical
      # doubled) showed the message panel's border flush against the
      # screen's left edge (x=0..1), right edge (x=638..639) and bottom
      # edge, its top edge at physical y=320 == logical y=160, i.e. exactly
      # `x=0, y=BATTLE_PANEL_Y (160), width=SCREEN_W (320), height=
      # BATTLE_PANEL_H (80)` -- while this method's old box measured
      # `x=10, width=SCREEN_W-20 (300), height=` the message's own one-line
      # content height, the same stale "inset 10px, content-sized" shape
      # already fixed for the (field) message window, the shop list window
      # and the Inn prompt window. Positioned at the top (`BATTLE_EVENT_MSG_Y`)
      # for an RPG2003 database, or flush against the bottom edge
      # (`BATTLE_PANEL_Y`) for RPG2000 -- only the size was wrong; the
      # RPG2000/RPG2003 y split above was already correct and untouched.
      def battle_text_window(lines, z)
        inner_w = SCREEN_W - Window::BORDER * 2
        y = @state.party.rpg2003? ? BATTLE_EVENT_MSG_Y : BATTLE_PANEL_Y
        win = Window.new(0, y, SCREEN_W, BATTLE_PANEL_H)
        win.z = z
        win.windowskin = windowskin
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        lines.each_with_index do |line, i|
          c.draw_text 0, i * BATTLE_LINE_H, inner_w, BATTLE_LINE_H, line
        end
        win.contents = c
        win
      end

      # The party status panel: each row is a list of [text, x, colour index]
      # segments rather than one string, so a row can mix colours. Drawn through
      # `draw_system_text`, which fills the glyphs from the System graphic's own
      # palette swatch (and falls back to flat white text when the project ships
      # no windowskin) — the way RPG_RT colours a state name. Docked to
      # `#battle_status_x` (0, beside the per-actor command window, or
      # `BATTLE_CMD_W`, beside the options window -- see that method), with a
      # cursor on `cursor_idx`'s row when the acting actor is one of these rows.
      #
      # Each segment is clipped (`#clip_text_to_width`, Scene::Base) to the gap
      # before the *next* segment in the same row, not to the panel's own right
      # edge — `draw_system_text`'s own `w`/`h` only ever feed centre/right
      # alignment (see its comment), so an uncapped width let an actor's name,
      # state or HP text run straight through its neighbour's column instead of
      # stopping at it. `battle_status_row`/`battle_state_segment` always
      # returns these four segments in ascending-x order, so "the next
      # segment's x" is always the next column's own origin; the last segment
      # (SP) clips to the panel's own inner edge instead, same as before.
      # Draws "LABEL cur/max" the way #battle_status_window's HP/MP columns
      # need it: only the current-value figure recolors via
      # #value_font_color (Scene::Base) -- critical (index 4, ≤ 1/4 max) or
      # knocked-out (index 5, HP only) -- the label and "/max" suffix stay
      # the ordinary swatch. Mirrors Scene::StatusMenu#draw_stat_segment,
      # which the field Status screen already uses for the identical rule;
      # confirmed against genuine RPG_RT.exe under wine that the battle
      # status panel follows it too (a save edited to a below-1/4-max HP
      # showed only the HP figure recoloring, "/max" and "MP" unchanged).
      # Clips the whole "LABEL cur/max" run to `w` first (matching every
      # other column's own overflow guard, `#clip_text_to_width`) and only
      # then splits the surviving text back into its three colored pieces,
      # so a column too narrow for the full string still can't bleed into
      # its neighbour.
      def draw_battle_stat_segment(c, x, y, w, label, cur, max, can_knockout)
        full = "#{label} #{cur}/#{max}"
        clipped = clip_text_to_width(c, full, w)
        label_part = clipped[0, label.length + 1] || ''
        rest = clipped[(label.length + 1)..-1] || ''
        cur_s = cur.to_s
        cur_part = rest[0, cur_s.length] || ''
        max_part = rest[cur_s.length..-1] || ''
        color = value_font_color(cur, max, can_knockout)
        cx = x
        draw_system_text c, cx, y, w, BATTLE_LINE_H, label_part, windowskin
        cx += c.text_size(label_part).width
        draw_system_text c, cx, y, w, BATTLE_LINE_H, cur_part, windowskin, color
        cx += c.text_size(cur_part).width
        draw_system_text c, cx, y, w, BATTLE_LINE_H, max_part, windowskin
      end

      def battle_status_window(rows, cursor_idx = nil)
        inner_w = BATTLE_STATUS_W - Window::BORDER * 2
        win = Window.new(battle_status_x, BATTLE_PANEL_Y, BATTLE_STATUS_W, BATTLE_PANEL_H)
        win.z = 300
        win.windowskin = windowskin
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        rows.each_with_index do |segments, i|
          segments.each_with_index do |(text, x, color, cur, max, can_knockout), j|
            next_x = j + 1 < segments.size ? segments[j + 1][1] : inner_w
            w = next_x - x
            y = i * BATTLE_LINE_H
            if cur
              draw_battle_stat_segment(c, x, y, w, text, cur, max, can_knockout)
            else
              draw_system_text c, x, y, w, BATTLE_LINE_H,
                               clip_text_to_width(c, text.to_s, w), windowskin,
                               color
            end
          end
        end
        win.contents = c
        if cursor_idx
          win.cursor_rect = Rect.new(0, cursor_idx * BATTLE_LINE_H, inner_w, BATTLE_LINE_H)
        end
        win
      end

      def dispose
        return unless @ui
        [@ui[:status_win], @ui[:cmd_win],
         @ui[:target_win], @ui[:skill_win],
         @ui[:item_win], @ui[:ally_win],
         @ui[:action_win], @ui[:result_win],
         @ui[:event_win]].each { |w| w.dispose if w }
        dispose_battle_sprite(@ui[:back_sprite])
        (@ui[:enemy_sprites] || []).each { |s| dispose_battle_sprite(s) }
        (@ui[:actor_sprites] || []).each { |s| dispose_battle_sprite(s) }
        @ui = nil
      end

      # Dispose a battle sprite. Its bitmap (the backdrop or a battler, see
      # #battle_back_bitmap / #battler_bitmap) is a shared @backdrop_cache or
      # @monster_cache entry that may still be referenced elsewhere (another
      # troop slot, a later encounter reusing the same graphic this visit),
      # so only the sprite itself is freed here.
      def dispose_battle_sprite(spr)
        return unless spr
        spr.dispose
      end

      # The battle-round half of #hold_animation_target_flash's forced clear:
      # the same RGSS Sprite#flash primitive #fire_target_flash arms a flash
      # with, called with a zero duration (flash_count 0 reads as "not
      # flashing," mruby-rgss/src/lib.cxx's own spr_flash/spr_update) to drop
      # whatever flash -- this animation's own decayed-away one, or an
      # unrelated one -- is currently in flight on that enemy sprite. A nil
      # target_index (an ally-scoped animation, no on-screen sprite) or a
      # missing @ui (the animation already finished/the fight already
      # ended) is a silent no-op, matching #fire_target_flash's own guard.
      def clear_target_flash(target_index)
        sprites = @ui && @ui[:enemy_sprites]
        spr = target_index && sprites ? sprites[target_index] : nil
        spr.flash(nil, 0) if spr
      end

      # yado.tk / the LCF schema itself (`animation_timing`'s flash_scope field,
      # 0 none / 1 target / 2 screen): a Battle Animation frame's flash can pulse
      # its *target* instead of the whole screen -- previously dropped outright,
      # since only flash_scope 2 was ever handled here. Scoped to the
      # battle-round path (a skill/item's `target_index`, see
      # #battle_animation_pixel): RPG2000's battle is front-view, so an
      # ally-targeted entry has no on-screen sprite to flash (target_index is
      # nil there, same as it already is for centring the animation itself).
      # A map-triggered Show Battle Animation (11210) aimed at a map character
      # is a different target class entirely, handled by #fire_map_target_flash
      # below. Uses the RGSS Sprite#flash/#update primitive
      # (mruby-rgss/src/lib.cxx) already ported natively but unused elsewhere
      # in this codebase, decayed each frame by #update_enemy_flashes.
      def fire_target_flash(target_index, t)
        sprites = @ui && @ui[:enemy_sprites]
        spr = target_index && sprites ? sprites[target_index] : nil
        return unless spr
        spr.flash(Color.new((t.flash_red || 0) * 8, (t.flash_green || 0) * 8,
                            (t.flash_blue || 0) * 8, (t.flash_power || 0) * 8),
                  Map::ANIM_FLASH_FRAMES)
      end

      # The screen_shaking-1 counterpart to #fire_target_flash: arms a timed
      # shake of just the animation's own target sprite, ported from a
      # reference implementation's actual C++ source verbatim, not
      # independently confirmed
      # against genuine RPG_RT under wine -- it shakes every one of the
      # animation's own
      # battler targets, the exact
      # same triple it already fires for the screen
      # case. This codebase's front-view battle has no per-sprite native
      # shake primitive the way Sprite#flash exists for the colour pulse, so
      # the state is tracked in a plain `@ui[:enemy_shake]` hash
      # (paralleling `enemy_sprites` by index) and stepped by
      # #update_enemy_shakes every frame -- the same `Shake::NextPosition`
      # sine-wave port Game::Screen#update_shake already drives for the
      # whole-screen case, just applied to one sprite's own x. RPG2000's
      # battle is front-view, so an ally-targeted entry has no sprite to
      # shake (target_index is nil there, the same gap #fire_target_flash's
      # own comment already documents) -- a silent no-op, not an error.
      def fire_target_shake(target_index)
        sprites = @ui && @ui[:enemy_sprites]
        return unless target_index && sprites && sprites[target_index]
        @ui[:enemy_shake] ||= []
        @ui[:enemy_shake][target_index] =
          { power: Map::ANIM_SHAKE_POWER, speed: Map::ANIM_SHAKE_SPEED,
            frames: Map::ANIM_SHAKE_FRAMES, offset: 0 }
      end

      # Advance every in-flight #fire_target_shake state by one frame --
      # called from #update every frame, right alongside
      # #update_enemy_flashes/#update_enemy_positions. A direct port of
      # Game::Screen#update_shake's own step (see there for the reference
      # implementation provenance), just keyed per
      # troop-member index instead of a single screen-wide state, and applied
      # to that member's own sprite x (recomputed from its live database
      # position the same way #update_enemy_positions already recomputes y
      # for a levitating member, so a sprite rebuilt mid-shake --
      # #reveal_battle_monster, #remove_fled_monster -- is never left
      # offset from a stale base). A slot with nothing active costs nothing.
      def update_enemy_shakes
        shakes = @ui[:enemy_shake]
        return unless shakes
        sprites = @ui[:enemy_sprites]
        troop = @ui[:troop]
        shakes.each_index do |i|
          st = shakes[i]
          next unless st
          spr = sprites && sprites[i]
          member = troop && troop.members[i]
          unless spr && member
            shakes[i] = nil
            next
          end
          st[:frames] -= 1
          if st[:frames] <= 0
            st[:offset] = 0
            shakes[i] = nil
          else
            amplitude = 1 + 2 * st[:power]
            phase = (st[:frames] * 4 * (st[:speed] + 2)) % 256
            newpos = (amplitude * Math.sin(phase * Math::PI / 128) * -1).to_i
            cutoff = (st[:speed] * amplitude) / 8 + 1
            st[:offset] = Game.clamp(newpos, st[:offset] - cutoff, st[:offset] + cutoff)
          end
          spr.x = member.x - spr.bitmap.width / 2 + st[:offset]
        end
      end
    end
  end
end

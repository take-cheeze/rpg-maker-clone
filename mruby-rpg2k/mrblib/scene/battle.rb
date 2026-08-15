class RPG2k
  module Scene
    # RPG2000's turn-based fight.
    #
    # RPG_RT runs an encounter as a scene of its own: `Scene_Battle` takes the
    # screen over from `Scene_Map` for as long as the fight lasts, which is why
    # its backdrop is all there is behind the troop and why no part of the map
    # is drawn beside it (EasyRPG Player's `src/scene_battle.cpp`). This port
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
        # RPG_RT's own `Scene_Battle` constructor (src/scene_battle.cpp) plays
        # the database's Battle Start system SE (`SFX_BeginBattle`) as its very
        # first act, unconditionally and before even the battle BGM swap --
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
        # RPG_RT's own `Scene_Battle_Rpg2k::ProcessSceneActionStart`
        # (EasyRPG Player's `src/scene_battle_rpg2k.cpp`) narrates the
        # encounter before the party is ever asked for a command: one
        # `terms.encounter` line per visible (non-`hidden`) troop member
        # -- `Game_EnemyParty::GetActiveBattlers`, "not dead or hidden" --
        # each built by concatenating the enemy's own name in front of the
        # term (`Window_BattleMessage::PushWithSubject`'s stock, non-
        # Maniac-Patch branch: `subject + message`, no placeholder), then,
        # if this encounter is a first-strike ambush
        # (`req[:first_strike]`, already threaded through to `Game::Battle`
        # above for the actual mechanic), a final fixed `terms.
        # special_combat` line with no name substitution -- pushed
        # *in addition to*, not instead of, the per-enemy lines, exactly as
        # real RPG_RT orders them. Nothing shows when the troop is entirely
        # hidden and the fight is not a first strike, matching
        # `if (!visible_enemies.empty()) SetWait(...)` gating the whole
        # substate there.
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
      # Real RPG_RT paces this per-line with wordwrap and per-page wait
      # timers -- `SetWait(4, 4)` before the first line, `SetWait(8, 8)`
      # between lines that are not the page's last, and `SetWait(30, 70)`
      # (repeated again for the first-strike line, when there is one) on
      # whichever line ends a page -- and, per `CheckWait`, holds the full
      # `max_wait` of each of those unless the player actively skips ahead.
      # This screen has no per-page message window (see #battle_result_lines'
      # own comment on the same simplification), so the whole banner -- every
      # line at once -- holds for one flat beat instead. That beat used to
      # match only RPG_RT's own minimum `SetWait(4, 4)` gate, not its real
      # per-line reading pause, which read as barely a flicker; 70 frames
      # (~1.2s) matches RPG_RT's own default no-skip hold on a single
      # encounter line (`SetWait(30, 70)`) instead -- long enough to actually
      # read the banner before the command menu takes over the same screen
      # rect, closer to (if still short of, for a troop with several enemies
      # or a first strike, both of which stack more `SetWait(30, 70)`s that
      # this one flat beat cannot represent) real RPG_RT's own pace.
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
      # given; EasyRPG's own `Game_Enemy::GetFlyingOffset` supplies both
      # missing facts and, more importantly, the edition gate the yado.tk
      # source never mentioned at all: `if (!Player::IsRPG2k3() || !IsFlying())
      # return 0;` -- "2k does not support flying, albeit mentioned in the
      # help file" (their comment). So a genuine RPG2000 database's own
      # `levitate` flag has no on-screen effect whatsoever, real RPG_RT bug and
      # all; only an RPG2003 one draws the +/-4px, 256-frame-period sine bob
      # (`round(sin(2*PI*frame/256) * 4)`, their `frame` a per-battler counter
      # incremented once per battle frame) computed here from this scene's own
      # per-battle `@ui[:frame]` instead -- a single shared phase for
      # every levitating member rather than EasyRPG's per-battler-randomized
      # start offset, since nothing in either wiki mirror (both unreachable
      # this session) describes members desyncing from one another, only that
      # each one "changes its Y position".
      FLYING_AMPLITUDE = 4
      FLYING_PERIOD = 256
      def flying_offset(member)
        return 0 unless member.levitate && @state.party.rpg2003?
        frame = @ui[:frame] || 0
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
      # 255 (fully opaque) for everyone else -- verified against EasyRPG
      # Player's actual C++ source, `Sprite_Enemy::Draw`'s `alpha = 160 * alpha
      # / 255` (`src/sprite_enemy.cpp`), with `alpha` at its 255 baseline since
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
      # until a battle event reveals them — a mechanism still to come.
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
        # #refresh_battle_sprites) -- matching EasyRPG's own
        # `Sprite_Enemy::Refresh`, which rebuilds on either changing.
        @ui[:sprite_names] = @ui[:foes].map { |f| f.battler_name }
        @ui[:sprite_hues] = @ui[:foes].map { |f| f.battler_hue || 0 }
        refresh_battle_sprites
      end

      # RPG2003's alternative/gauge battle layouts draw each living party
      # member as a sprite too (unlike RPG2000's status-window-only layout --
      # see Game::Party#alternate_battle_layout?), sourced from the
      # database's Battler Animation table (chunk 32, db.battleranimations --
      # decoded in a prior change, nothing read it until now). Scoped to the
      # plain Idle pose only (Pose id 0): no active state, not defending --
      # EasyRPG's Sprite_Actor::DoIdleAnimation (src/sprite_actor.cpp) swaps
      # in a Defend or state-mapped pose in those two cases, which is
      # follow-up work for a later change, not this one. A dead party member
      # gets no sprite (mirrors a hidden troop member never getting one
      # either in #build_battle_sprites above); the party status window keeps
      # showing everyone regardless, so a member left spriteless here (dead,
      # or any of the gaps #build_actor_sprite itself documents) is never
      # invisible to the player. A traditional-layout database (or a bare
      # test fixture whose party doesn't even answer #alternate_battle_layout?)
      # builds nothing, matching current behaviour exactly.
      def build_actor_sprites
        @ui[:actor_sprites] = nil
        return unless @state.party.respond_to?(:alternate_battle_layout?) &&
                      @state.party.alternate_battle_layout?
        @ui[:actor_sprites] = @ui[:allies].each_with_index.map do |ally, i|
          next nil if ally.dead?
          build_actor_sprite(ally.actor, i)
        end
      end

      # Idle pose id within a `db.battleranimations` entry's `poses` table
      # (lcf::rpg::BattlerAnimation::Pose_Idle -- schema.rb's own comment on
      # chunk 32 lists the full 12-pose order).
      ACTOR_IDLE_POSE = 0
      # `poses[id].animation_type` values: 0 a BattleCharSet sprite sheet
      # (implemented below), 1 a full Battle/<name> (CBA) animation sequence
      # played in place of a static sprite (not implemented here -- see
      # #build_actor_sprite).
      ACTOR_POSE_TYPE_BATTLE = 1
      # A BattleCharSet sheet is framed in fixed 48x48 cells, one row per
      # `battler_index` (EasyRPG's Sprite_Actor::OnBattlercharsetReady --
      # `SetSrcRect(Rect(0, battler_index * 48, 48, 48))`).
      ACTOR_CHARSET_CELL = 48
      # Clear of both the enemy troop's own z range (#battler_z's 100 +
      # troop_size-1 span) and the animation overlay's z 150, so an actor
      # sprite never fights either for draw order; still well below every UI
      # window (z >= 300).
      def actor_sprite_z(i)
        200 + i
      end

      # A living party member's Idle-pose sprite, or nil when this step
      # cannot draw one: `actor.battler_animation_id` names no
      # `db.battleranimations` entry (Game::Actor#battler_animation_id
      # already logs that diagnostic itself), the resolved entry defines no
      # Idle pose at all (silent -- an entry legitimately covering only some
      # of the 12 poses is normal authoring, not a dangling reference), or
      # the pose uses the `animation_type == 1` battle/CBA format this step
      # does not implement (logged below, matching this codebase's "reported
      # gap, not silently invented" convention for unimplemented behaviour).
      #
      # Position is the raw database `battle_x`/`battle_y`
      # (Game_Actor::GetOriginalPosition) -- confirmed against EasyRPG's
      # actual C++ source this is only what `battlecommands.placement`
      # manual (0) uses; automatic (1) instead computes a real grid formula
      # (`CalculateBaseGridPosition`, src/game_battle.cpp) this step does not
      # implement either, so that case also just logs and falls back to the
      # same raw coordinates rather than guessing at the formula.
      def build_actor_sprite(actor, i)
        anim_id = actor.respond_to?(:battler_animation_id) ? (actor.battler_animation_id || 0) : 0
        table = db.respond_to?(:battleranimations) ? db.battleranimations : nil
        entry = (table && anim_id > 0) ? table[anim_id] : nil
        return nil unless entry
        pose = entry.respond_to?(:poses) && entry.poses ? entry.poses[ACTOR_IDLE_POSE] : nil
        return nil unless pose

        if pose.animation_type == ACTOR_POSE_TYPE_BATTLE
          $stderr.puts "[RPG2k] actor ##{actor.id}: idle pose uses a battle-animation (CBA) " \
                       "sheet, not a BattleCharSet -- not yet implemented, sprite not drawn"
          return nil
        end

        bmp = actor_battlecharset_bitmap(pose.battler_name)
        return nil unless bmp

        if @state.party.respond_to?(:automatic_battle_placement?) &&
           @state.party.automatic_battle_placement?
          $stderr.puts "[RPG2k] actor ##{actor.id}: automatic battler placement not yet " \
                       "implemented, using the database's manual battle_x/battle_y"
        end

        spr = Sprite.new
        spr.bitmap = bmp
        spr.src_rect = Rect.new(0, (pose.battler_index || 0) * ACTOR_CHARSET_CELL,
                                ACTOR_CHARSET_CELL, ACTOR_CHARSET_CELL)
        spr.x = actor.respond_to?(:battle_x) ? (actor.battle_x || 0) : 0
        spr.y = actor.respond_to?(:battle_y) ? (actor.battle_y || 0) : 0
        spr.z = actor_sprite_z(i)
        spr
      end

      # Interpreter#do_change_party's hook (via `@ui[:events].
      # battle_screen`, set in #start) for a Change Party Member battle
      # event that actually added or removed a member -- mirrors EasyRPG's
      # `Game_Party::AddActor`/`RemoveActor` calling
      # `Scene_Battle_Rpg2k::OnPartyChanged` synchronously, right when the
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
        @ui[:actor_sprites].push(combatant.dead? ? nil : build_actor_sprite(combatant.actor, i))
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

      # Re-derive every surviving actor sprite's Z from its current index in
      # `@ui[:allies]` (#actor_sprite_z). An add or remove elsewhere in
      # the roster shifts everyone after it, so without this, two sprites can
      # end up sharing a Z once enough adds/removes have happened -- e.g.
      # remove index 1 of 3 (leaving index 2's sprite still at its old Z 202),
      # then add a new member at the new index 2, which would also compute Z
      # 202. Matches EasyRPG's own `ResetAllBattlerZ()`, called for the same
      # reason right after `OnPartyChanged` adds a sprite.
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

      # Where a battle-event page's message panel sits — above the action banner,
      # so a page talking mid-round does not fight it for the same row.
      BATTLE_EVENT_MSG_Y = 8

      # The backdrop this encounter fights over: whatever Game::Backdrop resolves
      # for the current map, given the terrain the party is standing on. '' when
      # nothing names one, which draws the flat field.
      def encounter_backdrop
        Game::Backdrop.name_for(@state.map_id, @map.map_properties,
                                @map.terrain_backdrop(@state.x, @state.y))
      end

      def build_battle_back(name = nil)
        bmp = battle_back_bitmap(name)
        spr = Sprite.new
        spr.bitmap = bmp
        spr.z = 5
        @ui[:back_sprite] = spr
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
          rebuild_battler_sprite(i, foe) if sprites[i] && changed
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
        sprites[i] = spr
        dispose_battle_sprite(old)
        @ui[:sprite_names][i] = foe.battler_name
        @ui[:sprite_hues][i] = foe.battler_hue || 0
      end

      def living_allies; @ui[:allies].reject(&:dead?); end

      # Allies selectable as a manually-chosen Battle Item target right now.
      # Unlike a skill target (still `#living_allies` below -- EasyRPG's own
      # `Skill::vExecute` dead-target handling is a materially larger state
      # machine this fix does not touch), an item target is drawn from the
      # *whole* roster, dead members included: EasyRPG's `Scene_Battle::
      # ItemSelected`/`AssignSkill` both put the status window into
      # `Window_BattleStatus::ChoiceMode_All` for a single-target medicine or
      # an ally-scope skill, and `IsChoiceValid`'s `ChoiceMode_All` case is an
      # unconditional `return true` (src/window_battlestatus.cpp) -- nothing
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
      # below the actor-name header): each a `{ label:, action: }` pair, drawn
      # by `#battle_commands` below and dispatched by `#select_battle_command`.
      #
      # An acting actor whose own RPG2003 battle-command list
      # (`Game::Actor#battle_commands`, edited by Change Battle Commands (1009)
      # or a class change) resolves to at least one usable entry drives the
      # menu; otherwise this falls back to the fixed **Attack, Skill, Defend,
      # Item** four — EasyRPG's `Scene_Battle_Rpg2k::CreateBattleCommandWindow`
      # builds that exact array (`command_attack`, `command_skill`,
      # `command_defend`, `command_item`), not the Item-before-Defend order
      # this used to assume, read from the database's battle-command terms with
      # the standard RPG2k labels as fallback. The Skill slot is not memoized:
      # it substitutes the acting actor's own RPG2000 rename
      # (`#skill_command_label` below) when the database sets one, so it can
      # change from one actor's turn to the next.
      def battle_command_rows
        actor = current_actor_row
        custom = actor && custom_battle_commands(actor)
        return custom if custom

        [
          { label: term(:battle_attack, 'Attack'), action: :attack },
          { label: skill_command_label, action: :skill },
          { label: term(:battle_defend, 'Defend'), action: :defend },
          { label: term(:battle_item, 'Item'), action: :item }
        ]
      end

      # `actor`'s own RPG2003 battle-command list resolved to menu rows, or nil
      # when there is nothing usable in it (no data at all -- an RPG2000
      # database, or a class/actor row that never set field 80, both of which
      # `Game::Actor#battle_commands` itself already reports as `[0]`, Row
      # alone -- or every entry turned out unsupported), so the caller falls
      # back to the fixed four.
      #
      # Each id is either 0 (Row -- not a menu row here any more than in
      # EasyRPG's own `Game_Actor::GetBattleCommands`, whose comment marks it
      # "not impl" and skips it the same way), -1 (an empty padding slot,
      # likewise skipped), or a positive ref into the database's own
      # Battle-Commands table (`Game::Actor#battle_command_row`) naming one
      # entry's `name` + `type`. Only the four types this engine actually
      # drives -- Attack, (sub)Skill, Defense, Item -- become a row; Escape
      # (the first actor's own Cancel already offers it) and Special (no
      # handler modelled anywhere in this engine) are skipped, same as an
      # unresolvable ref (a project whose database has no Battle-Commands
      # table decoded, or an id it doesn't define).
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
            out << { label: nonblank(row.name, term(:battle_attack, 'Attack')), action: :attack }
          when Game::Actor::BATTLE_COMMAND_SKILL, Game::Actor::BATTLE_COMMAND_SUBSKILL
            out << { label: nonblank(row.name, skill_command_label), action: :skill }
          when Game::Actor::BATTLE_COMMAND_DEFENSE
            out << { label: nonblank(row.name, term(:battle_defend, 'Defend')), action: :defend }
          when Game::Actor::BATTLE_COMMAND_ITEM
            out << { label: nonblank(row.name, term(:battle_item, 'Item')), action: :item }
          end
          # Escape / Special: no menu row (see the method comment above).
        end
        rows.empty? ? nil : rows
      end

      def battle_commands
        battle_command_rows.map { |c| c[:label] }
      end

      # The Skill command's own label. RPG2000's Actor sheet has a "custom
      # battle command" checkbox + name field (database fields 66/67,
      # `Game::Actor#rename_skill?` / `#skill_command_name`) that renames just
      # this one slot — EasyRPG's own `Game_Actor::GetSkillName`: `rename_skill
      # ? skill_name : Data::terms.command_skill`. Parsed by the schema and
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

      # Per-actor command menu: Attack, Skill, Defend or Item.
      def drive_battle_command
        if Input.trigger?(Input::DOWN)
          @ui[:cmd] += 1
          @ui[:cmd] %= battle_commands.length
          draw_battle_command
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP)
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
      # this round -- EasyRPG's own `IsAnyControllable()` guard inside
      # `ProcessSceneActionFightAutoEscape`, which skips the options window
      # entirely (straight to actor selection) when the whole party is
      # asleep/paralysed/similarly restricted or already flagged for auto
      # battle, since neither Battle nor Auto Battle would have anything left
      # to act on. `Game_Actor::IsControllable()` is exactly this pair of
      # checks: `GetSignificantRestriction() == Restriction_normal &&
      # !GetAutoBattle()`.
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
      # back to).
      def drive_battle_options
        rows = battle_option_rows
        if Input.trigger?(Input::DOWN)
          @ui[:opt] += 1
          @ui[:opt] %= rows.length
          draw_battle_options
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP)
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
          # Forced-AI leading actor (matching real RPG_RT's own
          # `SelectNextActor` doing that skip itself once `State_SelectActor`
          # is entered from here, not before).
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
      # likelier (Game::Battle#attempt_escape).
      def try_battle_escape
        battle = @ui[:battle]
        if battle.attempt_escape
          # A dedicated Escape SE, not Decision -- confirmed against
          # EasyRPG's own ProcessSceneActionEscape: the success branch plays
          # `GetSystemSE(SFX_Escape)` right before ending the battle. A
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
      # Attack/Defend (`Scene_Battle::AttackSelected`/`DefendSelected` both
      # play it as their own first statement, before doing anything else),
      # Skill/Item deferred to #start_skill/#start_item since
      # RPG_RT's own Decision-on-opening-the-submenu and Buzzer-on-nothing-
      # to-pick are both conditional on that submenu's own state there.
      def select_battle_command
        case battle_command_rows[@ui[:cmd]][:action]
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
          advance_actor
        when :item then open_battle_item
        end
      end

      # Enemy target-selection menu: pick which living enemy the Attack (or an
      # enemy-scope Skill) hits.
      def drive_battle_target
        foes = living_foes
        if Input.trigger?(Input::DOWN) && !foes.empty?
          @ui[:target_i] += 1
          @ui[:target_i] %= foes.length
          draw_battle_target
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) && !foes.empty?
          @ui[:target_i] -= 1
          @ui[:target_i] %= foes.length
          draw_battle_target
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          target = foes[@ui[:target_i]]
          close_battle_target
          if pending_kind == :skill
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
          else
            @ui[:pending] = nil
            @ui[:phase] = :command
            draw_battle_command
          end
        end
      end

      def pending_kind; @ui[:pending] && @ui[:pending][:kind]; end

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
        # RPG_RT always plays Decision opening this list, and Buzzer only
        # once a confirm inside it finds nothing usable
        # (`Scene_Battle::SkillSelected`'s own `!skill || !CheckEnable`
        # check) -- this engine instead never opens an empty list at all, so
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

      def drive_battle_skill
        skills = @ui[:skills]
        if Input.trigger?(Input::DOWN) && !skills.empty?
          @ui[:skill_i] += 1
          @ui[:skill_i] %= skills.length
          draw_battle_skill
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) && !skills.empty?
          @ui[:skill_i] -= 1
          @ui[:skill_i] %= skills.length
          draw_battle_skill
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          confirm_battle_skill
        elsif Input.trigger?(Input::B)
          play_system_se(SFX_CANCEL)
          close_battle_skill
          @ui[:phase] = :command
          draw_battle_command
        end
      end

      # Choose the highlighted skill: if the caster cannot afford its SP, or is
      # missing a weapon-type Attribute the skill requires
      # (`Game::Party#weapon_attribute_ready?` -- the same equip-gate
      # `#can_cast?` already applies to a field cast and to a Forced-AI actor's
      # own skill eligibility, see `Game::Battle#skill_ready?`), this is
      # RPG_RT's own Buzzer case (`SkillSelected`'s `CheckEnable` covers both);
      # otherwise Decision, then route to enemy / ally target selection (or
      # cast at once on a self-scope skill).
      def confirm_battle_skill
        sid, cost = @ui[:skills][@ui[:skill_i]]
        sk = @state.party.db_skill(sid)
        if current_actor.mp < cost ||
           !@state.party.weapon_attribute_ready?(current_actor_row, sk)
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
      # then move to the next actor.
      def apply_pending_skill(target)
        sk = @ui[:pending][:sk]
        sid = @ui[:pending][:sid]
        c = @state.party.battle_skill_command(sk, current_actor, target)
        @ui[:battle].command_skill(current_actor, target,
                                          name: sk.name, skill_id: sid,
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
                                          cured: c[:cured])
        @ui[:pending] = nil
        @ui[:phase] = :command
        advance_actor
      end

      # Commit the pending all-target skill on every `targets` combatant (all
      # living enemies for an attack skill, all living allies for a heal): build
      # one per-target effect from the model (attack damage varies with each
      # target's defence) and queue them as a single volley. The shared SP cost /
      # infliction ride along once.
      def apply_pending_skill_all(targets)
        sk = @ui[:pending][:sk]
        sid = @ui[:pending][:sid]
        meta = @state.party.battle_skill_command(sk, current_actor, targets.first)
        effects = targets.map do |t|
          c = @state.party.battle_skill_command(sk, current_actor, t)
          { target: t, hp: c[:hp], mp: c[:mp] }
        end
        @ui[:battle].command_skill_all(current_actor, effects,
                                              name: sk.name, skill_id: sid,
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
                                              cured: meta[:cured])
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

      def drive_battle_item
        items = @ui[:items]
        if Input.trigger?(Input::DOWN) && !items.empty?
          @ui[:item_i] += 1
          @ui[:item_i] %= items.length
          draw_battle_item
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) && !items.empty?
          @ui[:item_i] -= 1
          @ui[:item_i] %= items.length
          draw_battle_item
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::C)
          play_system_se(SFX_DECISION)
          item_id, _count = @ui[:items][@ui[:item_i]]
          it = @state.party.db_item(item_id)
          @ui[:pending] = { kind: :item, item_id: item_id, it: it }
          close_battle_item
          if @state.party.switch_item?(item_id)
            apply_pending_switch_item
          elsif @state.party.item_all_allies?(it)
            # The whole roster, dead included -- EasyRPG's own entire_party
            # branch (`Scene_Battle::ItemSelected`) targets `Main_Data::
            # game_party.get()` itself, not a living-only subset, which is
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

      # -- Ally target (heal skill / medicine) --------------------------------

      def drive_battle_ally_target
        allies = battle_ally_targets
        if Input.trigger?(Input::DOWN) && !allies.empty?
          @ui[:ally_i] += 1
          @ui[:ally_i] %= allies.length
          draw_battle_ally_target
          play_system_se(SFX_CURSOR)
        elsif Input.trigger?(Input::UP) && !allies.empty?
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
          if pending_kind == :skill
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
      # re-command, matching EasyRPG's `SelectPreviousActor` recursing back
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
      # RPG_RT does not use one flat gate here; it holds each stage of the
      # action separately (`Scene_Battle_Rpg2k::SetWait`/`SetWaitForUsage`,
      # `src/scene_battle_rpg2k.cpp`), and *without* the player holding
      # Decision/Shift to skip ahead, `CheckWait` always burns the full
      # `max_wait` of every stage it passes through -- confirmed by reading
      # `CheckWait` itself: it decrements every frame regardless of input and
      # only short-circuits early once a skip key is actually held. Tracing
      # the default (no-skip) path for a plain attack that hits, with no
      # animation, no crit and no state change -- the common case this
      # constant covers -- through every stage that fires:
      # `ProcessBattleActionBegin` (no state-proc message) `SetWait(4,4)`,
      # `ProcessBattleActionUsage`'s start-message
      # `SetWaitForUsage(Normal, 0)` = `SetWait(20,40)`,
      # `ProcessBattleActionAnimationImpl` with no animation still applies
      # the same `SetWaitForUsage(Normal, 0)` = `SetWait(20,40)`,
      # `ProcessBattleActionExecute` `SetWait(4,4)`,
      # `ProcessBattleActionDamage`'s `eBegin` `SetWait(4,4)`, its `eMessage`
      # damage line `SetWait(20,40)`, and its `ePost` `SetWait(0,10)` --
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
        # round -- EasyRPG's CheckBattleEndAndScheduleEvents runs "before each
        # battler acts and also right after the last battler acts" (the
        # latter half is #finish_round_animation's own check, already in
        # place). The boundary between two battlers' actions is exactly where
        # the previous #step_action call left nothing buffered (a dual-wield
        # swing or an all-target Skill/Item queues several hits from *one*
        # battler; the check belongs between battlers, not between hits).
        if @ui[:battler_boundary]
          @ui[:battler_boundary] = false
          return if run_battle_events(:animate)
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
        anim = @map.build_animation(id, tx, ty, true, target_index: entry[:target_index],
                               target_height: height)
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
      def start_battle_page_animation(req)
        tx, ty, height =
          if req[:allies]
            [SCREEN_W / 2, SCREEN_H / 2, nil]
          else
            battle_animation_pixel(target_index: req[:target])
          end
        target_index = req[:allies] ? nil : req[:target]
        @map.build_animation(req[:animation], tx, ty, true, target_index: target_index,
                             target_height: height)
      end

      # Close out an animated round: clear the commands, drop the action banner,
      # and branch to the result window or the next command phase.
      def finish_round_animation
        battle = @ui[:battle]
        battle.end_round
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
      def run_battle_events(return_phase = :command)
        ui = @ui
        return false unless ui && ui[:troop].pages
        matched = Game::BattlePage.select_all(ui[:troop].pages, @state.switches,
                                              @state.variables, ui[:battle])
        entry = matched.find { |(id, _)| !ui[:pages_run][id] }
        return false unless entry
        ui[:pages_run][entry[0]] = true
        cmds = entry[1].event
        return run_battle_events(return_phase) if cmds.nil? || cmds.empty? # empty page: try the next
        ui[:events].battle = ui[:battle]
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
          @ui[:event_win] =
            battle_text_window(lines || [], BATTLE_EVENT_MSG_Y, 340)
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
      def finish_battle(result)
        # Persist the party's post-battle HP (and any knock-outs) before leaving
        # the fight, so damage taken sticks and a downed member stays down.
        @ui[:battle].apply_to_party
        # Capture the fight's own round count (Game::Battle#turn, its live
        # @rounds counter) before #dispose discards the Battle object --
        # this is RPG2000's "turns passed in latest battle" (Game::State
        # #last_battle_turns, LCF inventory chunk 109 field 41).
        @state.last_battle_turns = @ui[:battle].turn
        # A defeat in "game over" mode (no custom [Defeat] handler) with the whole
        # party knocked out ends the game; every other outcome resumes the event.
        game_over = result == :defeat && @req[:defeat_game_over] &&
                    @state.party.all_dead?
        owner = @owner
        @map.close_battle
        if game_over
          @map.perform_game_over(owner)
        else
          @map.restore_pre_battle_bgm
          owner.resume_battle(result)
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
      def battle_action_lines(entry)
        battle_action_body(entry) + battle_state_lines(entry)
      end

      # The result window's text: the outcome, and on a win the EXP / gold gained
      # (granted here). RPG2000 shows this after the fight before returning to the
      # map. The headline is the database's own wording -- the 用語 table's
      # `victory` / `defeat` fields, the same table (and the same "falls back to
      # composed English when the database leaves it blank" rule)
      # Game::States::BattleText already reads every per-action line from.
      # The EXP / gold / item lines are composed from their own terms too now
      # (`exp_received`, the `gold_received_a` / `_b` pair, `item_received`),
      # confirmed against EasyRPG Player's actual C++ source rather than
      # guessed at: `PartyMessage::GetExperienceGainedMessage` /
      # `GetGoldReceivedMessage` / `GetItemReceivedMessage`
      # (`src/game_message_terms.cpp`), stock-RPG2000 (non-`Feature::
      # HasPlaceholders`, non-Maniac-Patch) branch -- `exp << terms.
      # exp_received` (no separating space outside the RPG2k3-English
      # release), `terms.gold_recieved_a << " " << money << terms.gold <<
      # terms.gold_recieved_b`, `item_name << terms.item_recieved`. These
      # three term fields were parsed by the schema and never read anywhere
      # in `mruby-rpg2k` before now, so a game that customised them (a
      # translation, a non-English original) showed this codebase's
      # hardcoded English regardless.
      #
      # A level-up (and any skill the growth table teaches at it) is
      # announced too now, the missing half of the same gap: EasyRPG's
      # `Scene_Battle_Rpg2k::ProcessSceneActionVictory`
      # (`src/scene_battle_rpg2k.cpp`) builds the EXP/gold/item summary as one
      # page, then calls `Game_Actor::ChangeExp` once per active ally right
      # after it, which is exactly `Game::Interpreter#do_change_exp`'s own
      # gain_exp-then-announce shape (`queue_level_up_messages`,
      # `mrblib/interpreter.rb`) -- so each actor's level/skill snapshot is
      # taken here the same way, right before its own `#gain_exp`. Unlike
      # that interpreter path (still the documented "plain English line for
      # now" simplification), this screen already reads real database terms
      # for every other line, so `#battle_level_up_message` /
      # `#battle_skill_learned_message` below do too, built from EasyRPG's
      # `ActorMessage::GetLevelUpMessage` / `GetLearningMessage`
      # (`src/game_message_terms.cpp`), stock-RPG2000/CP932 branch: `name <<
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
          # A KO'd party member earns nothing from the victory -- EasyRPG's own
          # EXP-granting loop (Scene_Battle_Rpg2k::ProcessSceneActionVictory)
          # iterates Game_Party_Base::GetActiveBattlers, not the raw roster,
          # and GetActiveBattlers excludes anyone failing Game_Battler::
          # Exists() (`!IsHidden() && !IsDead() && IsInParty()`).
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
      # `level`/`level_up` terms the way EasyRPG's stock/CP932
      # `GetLevelUpMessage` branch does (see `#battle_result_lines`'s own
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
      # its level's own line above -- EasyRPG's stock/CP932
      # `GetLearningMessage` branch names only the skill, never the actor,
      # since it always trails that actor's own level-up line the way it
      # does here too. Falls back to composed English (which does name the
      # actor, since a database leaving `skill_learned` blank gets no
      # level-up line's context to lean on either) when the term is blank.
      def battle_skill_learned_message(actor, sk)
        learned = term(:skill_learned, nil)
        return "#{actor.name} learned #{sk.name}!" unless learned
        "#{sk.name}#{learned}"
      end

      # RPG_RT's battle windows share one fixed panel: a 320x80 strip along the
      # bottom edge with 16px rows -- not the content-fitted, 14px-row windows
      # this screen used to draw. EasyRPG's Scene_Battle_Rpg2k / Scene_Battle
      # construct status_window / command_window / target_window / item_window /
      # skill_window / battle_message_window all at
      # `(x, screen_height - 80, w, 80)`, and Window_Selectable's own
      # `menu_item_height` (16, matching this screen's message-window
      # `MSG_LINE_H`) is what actually spaces their rows.
      BATTLE_LINE_H = 16
      BATTLE_PANEL_Y = SCREEN_H - 80
      BATTLE_PANEL_H = 80
      # The actor-command window is a fixed 76px (`option_command_mov` in
      # EasyRPG), docked to the right edge; the status window takes the rest of
      # the row (`MENU_WIDTH - option_command_mov`).
      BATTLE_CMD_W = 76
      BATTLE_STATUS_W = SCREEN_W - BATTLE_CMD_W
      # The enemy target list (`CreateBattleTargetWindow`) is a fixed 136px, and
      # only ever covers the status window's footprint -- the command window
      # stays on screen beside it.
      BATTLE_TARGET_W = 136
      # How many rows show at once before a longer list (an 8-monster troop, a
      # long skill list) scrolls: the panel's fixed 64px content area (80 minus
      # the 8px border on each side) divided by the 16px row height.
      BATTLE_VISIBLE_ROWS = 4

      # Column origins within the status panel's contents, in the order RPG_RT's
      # battle status window uses them: who, what condition they are in, then the
      # gauges. The condition column is why this window is laid out in columns at
      # all — a state is drawn in its *own* palette colour, which a single
      # `draw_text` of a whole line cannot do. (EasyRPG's
      # `Window_BattleStatus::Refresh`, RPG2k branch: name at 4, state at 86,
      # HP at 142, SP at 202 for a party with no maxima over 999.)
      STATUS_NAME_X  = 4
      STATUS_STATE_X = 86
      STATUS_HP_X    = 142
      STATUS_MP_X    = 202

      # Rebuild the status panel: the party's HP and SP, each with the one
      # condition RPG_RT shows — the significant state, or the database's
      # "normal" term when there is none — so a status inflicted by a skill or
      # by a battle page's Change Monster Condition is visible rather than only
      # simulated. RPG2000 is front-view: the enemy troop is never listed here
      # (EasyRPG's Scene_Battle_Rpg2k builds exactly one Window_BattleStatus,
      # defaulted to `enemy: false`) -- it is represented only by its battler
      # sprites and, when targeted, by the target window's name list. The row
      # of whichever actor is currently being commanded gets the cursor,
      # mirroring `status_window->SetIndex` in EasyRPG's `SelectNextActor`.
      #
      # `battle_type` 2 (gauge, `#gauge_battle_layout?`) replaces this whole
      # panel with RPG2003's face/bar "gauge card" layout instead
      # (`#battle_status_gauge_window`) -- `battle_type` 1 (alternative) is
      # unchanged, and still builds the same text rows this always has, since
      # only 2 asks for the card presentation (EasyRPG's own
      # `Window_BattleStatus::Refresh`/`RefreshGauge` branch the same way, on
      # `battle_type == BattleType_gauge` specifically, not on "not
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
      # condition, then the HP / SP gauges.
      def battle_status_row(b)
        hp = b.hp < 0 ? 0 : b.hp
        [[b.name, STATUS_NAME_X, 0], battle_state_segment(b),
         ["HP #{hp}/#{b.max_hp}", STATUS_HP_X, 0],
         ["MP #{b.mp}/#{b.max_mp}", STATUS_MP_X, 0]]
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
      # from EasyRPG's real `Window_BattleStatus::Refresh`/`RefreshGauge`
      # (the `!enemy && battle_type == BattleType_gauge` branch of each).
      # Borderless like RPG_RT's own gauge window (`Window#transparent=` --
      # EasyRPG's constructor sets `border_x = border_y = 0` and
      # `SetOpacity(0)` for this same case, "simulate a borderless window...
      # makes the implementation on scene-side easier"), and never gets a
      # cursor rect: `UpdateCursorRect` returns an empty rect unconditionally
      # for this battle_type, so no row is ever highlighted here, unlike the
      # text status window's acting-actor cursor. The ATB/wait gauge row
      # `RefreshGauge` also draws (`DrawGaugeSystem2(..., GetAtbGauge,
      # GetMaxAtbGauge, 2)`) is skipped -- this runtime has no ATB/wait-timer
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
        win = Window.new(0, BATTLE_PANEL_Y, BATTLE_STATUS_W, BATTLE_PANEL_H)
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
        draw_gauge_system2(c, system2, fill_x, y, hp, ally.max_hp, 0)
        draw_gauge_system2(c, system2, fill_x, y + 16, ally.mp, ally.max_mp, 1)
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
      # a cursor. RPG_RT does not put the actor's name in this window at all
      # (EasyRPG's `CreateBattleCommandWindow` builds it once from the four
      # command terms in that order): the acting actor is shown by the cursor
      # `#refresh_battle_status` puts on their row in the status window instead
      # (EasyRPG's `status_window->SetIndex(actor_index)`). The Skill slot's own
      # label can still change per actor (`#skill_command_label`), the same way
      # EasyRPG's `RefreshCommandWindow` calls `SetItemText` on that one row
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

      # The Battle/Auto Battle/Escape options window -- the same panel and
      # rect the per-actor command window uses (only one of the two is ever
      # on screen at a time), just with `#battle_option_rows`' three entries
      # instead of the usual four.
      def draw_battle_options
        @ui[:cmd_win].dispose if @ui[:cmd_win]
        labels = battle_option_rows.map { |r| r[:label] }
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
      # Skill / Item / target / ally-target menus. A list longer than
      # `BATTLE_VISIBLE_ROWS` scrolls, keeping `sel` in view, the way
      # `Window_Selectable`'s own scrolling does for an oversized troop or
      # skill list.
      def battle_list_window(x, w, labels, sel, z)
        rows = BATTLE_VISIBLE_ROWS
        scroll = labels.length > rows ? [[sel - rows + 1, 0].max, labels.length - rows].min : 0
        win = Window.new(x, BATTLE_PANEL_Y, w, BATTLE_PANEL_H)
        win.z = z
        win.windowskin = windowskin
        inner_w = w - Window::BORDER * 2
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        labels.each_with_index do |label, i|
          next if i < scroll || i >= scroll + rows
          c.draw_text 0, (i - scroll) * BATTLE_LINE_H, inner_w, BATTLE_LINE_H, label
        end
        win.contents = c
        unless labels.empty?
          win.cursor_rect = Rect.new(0, (sel - scroll) * BATTLE_LINE_H, inner_w, BATTLE_LINE_H)
        end
        win
      end

      # The current actor's battle skills as "Name  cost", with a cursor. Full
      # width, same rect as the item menu — RPG_RT's skill and item windows
      # cover both the status and command windows while open (EasyRPG's
      # `skill_window` / `item_window`, `(0, screen_height - 80, MENU_WIDTH,
      # 80)`).
      def draw_battle_skill
        @ui[:skill_win].dispose if @ui[:skill_win]
        labels = @ui[:skills].map do |sid, cost|
          sk = @state.party.db_skill(sid)
          "#{sk ? sk.name : "Skill #{sid}"}  #{cost}"
        end
        @ui[:skill_win] = battle_list_window(0, SCREEN_W, labels, @ui[:skill_i], 325)
      end

      def close_battle_skill
        return unless @ui[:skill_win]
        @ui[:skill_win].dispose
        @ui[:skill_win] = nil
      end

      # The party's battle items as "Name  xN", with a cursor.
      def draw_battle_item
        @ui[:item_win].dispose if @ui[:item_win]
        labels = @ui[:items].map do |id, count|
          it = @state.party.db_item(id)
          "#{it ? it.name : "Item #{id}"}  x#{count}"
        end
        @ui[:item_win] = battle_list_window(0, SCREEN_W, labels, @ui[:item_i], 325)
      end

      def close_battle_item
        return unless @ui[:item_win]
        @ui[:item_win].dispose
        @ui[:item_win] = nil
      end

      # The living party members selectable as a heal target ("Name HP h/mh"),
      # with a cursor -- narrowed by #battle_ally_targets when a pending item's
      # actor_set excludes some of them. RPG_RT reuses the status window itself
      # for this (`status_window->SetChoiceMode`); this screen still draws a
      # separate window, but at the status window's own rect and footprint so
      # it reads the same way -- covering the party's HP display, leaving the
      # command window in view beside it.
      def draw_battle_ally_target
        @ui[:ally_win].dispose if @ui[:ally_win]
        labels = battle_ally_targets.map do |a|
          "#{a.name}  #{a.hp < 0 ? 0 : a.hp}/#{a.max_hp}"
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
      # is independent rather than an elsif chain -- RPG_RT plays its own cue
      # for each thing that happened to the same hit, not one sound standing in
      # for all of them: a killing blow plays the damage sound and then the
      # death cry, and an item that lands a hit plays the item's own cue
      # alongside the hit's (EasyRPG's Scene_Battle_Rpg2k fires
      # SFX_EnemyDamage / SFX_AllyDamage and, on top of a kill, SFX_EnemyKill,
      # as separate calls rather than one replacing another).
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

      # RPG_RT's battle message window (the per-action banner, the result
      # panel) is a fixed 320x80 strip at the bottom of the screen -- the same
      # rect as the status/command windows it visually replaces while it is up
      # (EasyRPG's `Window_BattleMessage`, `(0, screen_height - 80, MENU_WIDTH,
      # 80)`) -- not a panel sized to fit its text.
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

      # A text panel of `lines` at vertical position `y` and depth `z`, sized to
      # fit its content -- used for the battle-event page message window, which
      # this screen deliberately keeps off the bottom panel's rect (see
      # `BATTLE_EVENT_MSG_Y`) so a page talking mid-round does not fight the
      # action banner for the same row.
      def battle_text_window(lines, y, z)
        inner_w = SCREEN_W - 20 - Window::BORDER * 2
        inner_h = [lines.length, 1].max * BATTLE_LINE_H
        win = Window.new(10, y, SCREEN_W - 20, inner_h + Window::BORDER * 2)
        win.z = z
        win.windowskin = windowskin
        c = Bitmap.new(inner_w, inner_h)
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
      # no windowskin) — the way RPG_RT colours a state name. Fixed at the
      # bottom-left of the panel (`Window_BattleStatus`'s own rect), with a
      # cursor on `cursor_idx`'s row when the acting actor is one of these rows.
      def battle_status_window(rows, cursor_idx = nil)
        inner_w = BATTLE_STATUS_W - Window::BORDER * 2
        win = Window.new(0, BATTLE_PANEL_Y, BATTLE_STATUS_W, BATTLE_PANEL_H)
        win.z = 300
        win.windowskin = windowskin
        c = Bitmap.new(inner_w, BATTLE_PANEL_H - Window::BORDER * 2)
        c.font.color = Color.new(255, 255, 255, 255)
        rows.each_with_index do |segments, i|
          segments.each do |text, x, color|
            draw_system_text c, x, i * BATTLE_LINE_H, inner_w - x,
                             BATTLE_LINE_H, text.to_s, windowskin, color
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
      # shake of just the animation's own target sprite, mirroring EasyRPG's
      # actual C++ source verbatim -- both `BattleAnimationBattle::
      # ShakeTargets` and `BattleAnimationBattler::ShakeTargets`
      # (src/battle_animation.cpp) shake every one of the animation's own
      # battler targets with `battler->ShakeOnce(str, spd, time)`, the exact
      # same triple `ProcessAnimationTiming` already fires for the screen
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
      # Game::Screen#update_shake's own step (see there for the EasyRPG
      # `Shake::NextPosition`/`Shake::Update` provenance), just keyed per
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

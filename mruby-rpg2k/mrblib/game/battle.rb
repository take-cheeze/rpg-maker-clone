# Game::Battle -- split into its own file (mruby-rpg2k/mrbgem.rake) so
# it, alongside scene/battle.rb and scene/battle_rpg2k3.rb, can be
# excluded from the wio build's own compiled bytecode: at 81,230 bytes
# on its own (docs/adr/0107's own real measurement), it is the single
# largest chunk of game.rb, for a feature (a live fight) most of a
# session never touches. See docs/adr/0107-wio-battle-bytecode-split.md.

module Game
  # A headless combat model driving both the live turn-based fight
  # (Scene::Battle holds one as its own `@ui[:battle]`) and, separately, an
  # out-of-battle skill/item cast resolved on Combatant snapshots so the
  # caller can compute an effect without mutating the real party. Escape
  # (#attempt_escape) and enemy-cast state infliction (#inflict_state, fed
  # from an enemy's own #choose_enemy_action skill pick the same way an
  # ally's does) are both implemented directly on this class, not a
  # still-to-come refinement — this stopped being a "deliberately simple
  # first cut" some time ago. The field-only skill/item formulas
  # (#skill_effect, #skill_defence_term and friends) still live on
  # Game::Party, reused by both the field menu and this class.
  class Battle
    # RPG2003 front/back row. A purely RPG2003 concept (RPG2000 never sets it):
    # the row changes a battler's hit and damage the way a reference
    # implementation's row-adjustment and normal-attack formulas
    # describe (ported from that source, NOT independently confirmed against
    # genuine RPG_RT under wine) -- a back-row defender is harder to hit and takes
    # reduced damage, a front-row actor deals more. See #row_adjusted? and ADR
    # 0053 (the placement field that decides a battler's row for a given
    # battle is the RPG2003 Battle Commands table, 0x1D, field 2).
    #
    # Aliases onto Game::Actor's own copy, not a second definition: this
    # engine's field-menu Row command (Party#toggle_actor_row) and the
    # status panel's row indicator both need these whether or not a fight
    # has ever started, so the real values live on Actor (always loaded);
    # every other combat formula below still reads the bare `ROW_FRONT`/
    # `ROW_BACK` names this alias keeps working.
    ROW_FRONT = Actor::ROW_FRONT
    ROW_BACK = Actor::ROW_BACK

    # A battler reduced to what the fight needs. Snapshotting Game::Actor /
    # Game::Enemy keeps the real party untouched by a resolved battle.
    # `action` is the ally's chosen attack target for the round (nil = none /
    # auto), `defending` halves damage taken that round, and `command` is a
    # queued Skill / Item action (see Battle#apply_command); these are
    # cleared each round. `skip` forfeits the turn outright (a failed escape).
    # Enemies leave them nil and attack a random party
    # member. `mp` / `max_mp` carry SP (skills spend it) and `spi` is the spirit
    # stat the skill formulas read as `int`.
    Combatant = Struct.new(:name, :atk, :def, :agi, :hp, :max_hp,
                           :action, :defending, :mp, :max_mp, :spi, :command,
                           :actor, :states, :state_turns, :crit_chance,
                           :prevents_crit, :attr_ranks, :atk_attrs, :skip,
                           :hit_rate, :state_ranks, :hidden, :battle_turn,
                           :actions, :charged, :enemy_id, :battler_name,
                           :battler_hue,
                           # Equipment-granted combat modifiers (ADR 0033):
                           # how many times a basic attack swings, whether it
                           # can be evaded, whether Defend halves twice, and
                           # whether skills cost half.
                           :strikes, :ignores_evasion, :strong_defence,
                           :half_sp_cost,
                           # Whether this battler's own gear makes a normal
                           # attack likelier to miss it (Actor#physical_evasion_up?,
                           # a flat -25 to the attacker's to_hit -- see
                           # Battle#to_hit). Enemy Combatants leave it nil/false;
                           # monsters equip nothing.
                           :evasion_up,
                           # A basic Attack read from the weapon's own
                           # attack_all? flag (confirmed by an actual wine
                           # capture to have no observable effect -- see
                           # Actor#attack_all?'s own citation) or jumped to the
                           # front of the round's turn order (preemptive?) --
                           # see #turn_order and #strike. Actor-only; an enemy
                           # Combatant leaves both nil/false, so it never
                           # qualifies for either.
                           :attack_all, :preemptive,
                           # The ranks #attr_ranks started the battle at --
                           # never itself written to, only read to cap how far
                           # an "attribute defence up/down" skill (see
                           # #skill_attr_shift) may move #attr_ranks in either
                           # direction. Since #attr_ranks is a fresh Hash per
                           # Combatant (Game::Actor#attribute_ranks builds one
                           # from the database row on every call, not a cached
                           # one) and #apply_to_party never writes it back to
                           # the actor, a shift is battle-scoped for free: it
                           # dies with the Combatant, no separate reset needed.
                           :attr_base_ranks,
                           # Per-battle ATK/DEF/SPI/AGI offsets a skill's own
                           # affect_attack/affect_defense/affect_spirit/
                           # affect_agility flags accumulate onto (see
                           # Battle#apply_stat_mods) -- a reference
                           # implementation's own per-battle stat modifiers,
                           # reset to 0
                           # by its battle-start reset there. This class
                           # needs no equivalent reset: exactly like
                           # #attr_ranks above, a fresh Combatant is built once
                           # per fight and never written back to the actor, so
                           # nil (read as 0 by #effective_atk and friends)
                           # every construction is the reset for free.
                           :atk_mod, :def_mod, :spi_mod, :agi_mod,
                           # The status conditions this battler's equipped
                           # weapon(s) carry into a basic Attack -- see
                           # Game::Actor#weapon_states, whose `{ inflict:,
                           # heal: }` shape this mirrors exactly. An enemy
                           # Combatant leaves it nil (read as empty by
                           # #atk_states -- monsters equip nothing in real
                           # RPG_RT either).
                           :atk_states,
                           # Whether this ally's actor is currently a member of
                           # the live Game::Party, kept in sync by
                           # Battle#sync_allies_from_party for a fight
                           # constructed with `party:` (mid-battle roster
                           # sync). nil/true means "yes" -- every Combatant
                           # built without going through that path (every
                           # existing fixture, and an enemy, which never has
                           # this field touched at all) is a member for free,
                           # matching the unconditional-membership behaviour
                           # this class had before the field existed. Distinct
                           # from #out_of_play?'s other two causes
                           # (dead?/hidden): a not-a-member Combatant has not
                           # left *the fight* the way a felled or fled battler
                           # has -- it is deliberately kept in @allies (not
                           # removed) so a later rejoin finds and reuses this
                           # exact object rather than rebuilding a fresh one
                           # and losing its accumulated battle-only state (see
                           # this Struct's own class comment).
                           :member,
                           # Whether this battler was under a "do nothing"
                           # restriction (asleep/paralysed) at the moment its
                           # action entered this round's queue (#refill_queue),
                           # snapshotted there and consulted -- not
                           # re-derived -- when the action is dequeued
                           # (#step/#step_action). See #apply_turn_states'
                           # own comment for why a live re-check at dequeue
                            # time is wrong: ported from a reference
                            # implementation's own action-preparation logic,
                            # NOT independently
                            # confirmed against genuine RPG_RT under wine --
                            # it locks a restricted
                            # battler's queued algorithm to `None` right when
                            # it is chosen or first
                            # afflicted mid-round,
                            # and nothing in the reference ever reverses that
                            # once the restriction later clears -- curing
                            # Sleep/Paralysis after the round's queue is built
                            # does not give the battler its turn back. nil
                            # (never queued this round yet) reads as "not
                            # locked", matching every existing fixture that
                            # calls #apply_turn_states directly without going
                            # through #refill_queue first.
                            :queued_no_act,
                            # The RPG2003 front/back row this battler stands
                            # in (see the `ROW_FRONT`/`ROW_BACK` constants
                            # above); nil defaults to the front row, the only
                            # row RPG2000 knows. The row changes how the fight
                            # treats the battler (#row_adjusted?): a back-row
                            # defender is harder to hit and takes less damage,
                            # a front-row actor deals more -- the row is an
                            # RPG2003-only concept, so this stays front for
                            # every 2000 fight.
                            :row,
                            # The RPG2003 active-time (gauge) charge for this
                            # battler (ADR 0053, Phase 2). 0..GAUGE_MAX; a
                            # battler whose gauge is full may act. Only the
                            # 2003 gauge presentation (battle_type 2) actually
                            # advances it -- RPG2000 (battle_type 0) and the
                            # 2003 traditional presentation (1) leave it at 0
                            # and run the turn-based machine instead.
                            :gauge,
                            # The ref of the battle command (into
                            # `db.battlecommands.commands`, 1..4 for the fixed
                            # four) this actor last chose in the command window,
                            # recorded by the scene (#select_battle_command) the
                            # way a reference implementation's own battle
                            # scene records the last chosen command (ported,
                            # NOT independently confirmed against genuine
                            # RPG_RT under wine). Read by the
                            # RPG2003 battle combo (#combo_hits) and, in time,
                            # the battle-page `command_actor` condition. nil
                            # until an actor picks a command (an enemy, or an
                            # auto-battling ally, never records one).
                            :last_battle_action,
                            # The per-turn state reminder line this battler's
                            # turn should open with, as of the most recent
                            # #apply_turn_states call -- the message text
                            # itself (already resolved against this
                            # battler's name), or nil when nothing qualifies.
                            # Ported from a reference implementation's own
                            # turn-begin processing, NOT independently
                            # confirmed against genuine RPG_RT under wine: it
                            # computes this fresh every turn from whichever
                            # single highest-`priority` state (ties to the
                            # higher id) the battler either still carries or
                            # just had auto-cured -- not accumulated across turns.
                            :turn_state_message,
                            # The database skill id this actor last chose from
                            # the Skill menu (or had an Auto-Battle pick queue
                            # on their behalf -- see #queue_single_auto_battle_skill/
                            # #queue_auto_battle_group_skill's own citation),
                            # so Scene::Battle#open_battle_skill can reopen the
                            # list with the cursor back on it next turn instead
                            # of always resetting to the top. Community デフォ戦
                            # bot/@2000_battle_bot trivia. nil (an actor who has
                            # never cast a skill this fight) reads as "top of
                            # the list" wherever this is consulted.
                            :last_skill_id,
                            # An enemy's plain basic-Attack target, locked in
                            # for the round by #refill_queue at queue-build
                            # time rather than re-rolled live when the action
                            # actually executes (#attack_target). Ported from
                            # a reference implementation's own
                            # CreateExecutionOrder/algorithm-init step, which
                            # resolves a basic attack's target once, the
                            # moment the round's execution order is built --
                            # NOT independently confirmed against genuine
                            # RPG_RT under wine, but the same "lock at queue
                            # time" shape #queued_no_act already ports for the
                            # do-nothing-restriction case. Only ever set for
                            # an enemy (an ally's own target instead comes
                            # from its `action` field, chosen at command time
                            # and always current); nil (never queued this
                            # round yet -- a fixture/test calling
                            # #attack_target directly without going through
                            # #refill_queue first) falls back to the old live
                            # roll, matching #queued_no_act's own documented
                            # default.
                            :queued_target) do
      def dead?; hp <= 0; end

      # The HP/MP ceiling a status panel should show for this combatant: the
      # larger of the live current value and the recomputed maximum (see
      # Game::Actor's identical helper, shared by the battle status windows).
      def display_max_hp; hp && hp > max_hp ? hp : max_hp; end
      def display_max_mp; mp && mp > max_mp ? mp : max_mp; end

      # Swings per basic attack: 2 with a 二刀流 weapon, 1 otherwise. Struct
      # members start nil, so the reader normalises.
      def strike_count; n = strikes; n && n > 1 ? n : 1; end
      # Whether this battler's gear halves what a skill costs (Party#skill_cost
      # asks whatever it is handed, actor or snapshot).
      def half_sp_cost?; half_sp_cost ? true : false; end
      # The weapon-granted state chances this battler's basic Attack carries,
      # normalised to `{ inflict: {}, heal: {} }` for a Combatant that never
      # had any set (an enemy, or an actor built before this field existed).
      def atk_states; self[:atk_states] || { inflict: {}, heal: {} }; end

      # RPG2003 counts turns per battler as well as per battle: this is how many
      # turns *this* battler has taken, which the troop pages' turn_enemy /
      # turn_actor conditions are written against. Mirrors a reference
      # implementation's own per-battler turn counter, which
      # increments as that battler's own turn begins (and resets to zero at
      # battle start).
      # Struct members start nil, so the reader normalises rather than every
      # construction site having to pass 0.
      def turns_taken; battle_turn || 0; end
      def next_battle_turn; self.battle_turn = turns_taken + 1; end
      # A troop member the editor placed but flagged invisible has not entered
      # the fight yet: it does not act, cannot be targeted and does not keep the
      # battle going. Show Hidden Monster (13150) clears the flag and brings it
      # in. Distinct from `dead?`, which is purely about HP. An ally whose
      # actor has left the live party (#member? false, mid-battle roster sync)
      # is out of play the same way -- not queued, not targetable -- without
      # being dropped from @allies the way dead?/hidden never are either.
      def out_of_play?; dead? || hidden || !member? ? true : false; end
      # See the `member` field's own comment: nil (never touched by
      # mid-battle roster sync, or synced back true on a rejoin) reads as "yes,
      # a member" -- only an explicit `false` (this actor's Combatant exists
      # but has left the live party) reads otherwise.
      def member?; member == false ? false : true; end
      # Spirit under the name Game::Party's skill formulas (#skill_effect,
      # #skill_cost) read on a caster.
      def int; spi; end
      # Whether `id` is currently afflicting this battler.
      def state?(id); (states || []).include?(id); end
      # The battler's row: nil (never set, the RPG2000 default) reads as the
      # front row; only RPG2003 ever sets the back row.
      def row; self[:row] || ROW_FRONT; end
      def back_row?; row == ROW_BACK; end
      # The battler's active-time gauge: nil (never advanced, the RPG2000 /
      # traditional-2003 default) reads as empty.
      def gauge; self[:gauge] || 0; end
      def gauge_full?; gauge >= GAUGE_MAX; end
    end

    # Seed the combatant's status set from the actor, so a member who walked into
    # the fight afflicted (a map Change Condition) is still afflicted in battle,
    # and a cure applied here can be written back. A bare fixture without #states
    # starts clean.
    def self.actor_states(a); a.respond_to?(:states) ? (a.states || []).dup : []; end

    # A battler's critical-hit chance in basis points (0 when it never crits, or
    # the source lacks the field).
    def self.crit_chance_of(b); b.respond_to?(:crit_chance) ? b.crit_chance : 0; end

    # Whether a battler's gear guards against critical hits.
    def self.prevents_crit_of(b); b.respond_to?(:prevents_critical?) && b.prevents_critical?; end

    # A battler's per-attribute defence ranks ({ attribute_id => rank 0..4 }), or
    # {} when the source (a bare fixture) doesn't model them.
    def self.attr_ranks_of(b); b.respond_to?(:attribute_ranks) ? b.attribute_ranks : {}; end

    # The elemental attribute ids a battler's basic attack carries (its equipped
    # weapon's attribute_set); [] for an enemy or an unarmed / fixture attacker.
    def self.atk_attrs_of(b); b.respond_to?(:weapon_attributes) ? b.weapon_attributes : []; end

    # The status conditions a battler's basic attack carries via its equipped
    # weapon(s) (`Game::Actor#weapon_states`); nil (read as empty by
    # Combatant#atk_states) for an enemy or an unarmed / fixture attacker.
    def self.atk_states_of(b); b.respond_to?(:weapon_states) ? b.weapon_states : nil; end

    # A battler's basic-attack base hit rate (percent), or 90 (the RPG2000
    # default) when the source (a bare fixture) doesn't model one.
    def self.hit_rate_of(b); b.respond_to?(:attack_hit_rate) ? b.attack_hit_rate : 90; end

    # A battler's per-state susceptibility ranks ({ state_id => rank 0..4 }), or
    # {} when the source (a bare fixture) doesn't model them.
    def self.state_ranks_of(b); b.respond_to?(:state_ranks) ? b.state_ranks : {}; end

    # A battler's basic-attack swing count (`Actor#strike_count`, which
    # folds in the plain `#dual_attack?` case too); 1 for an enemy or a bare
    # fixture that models neither.
    def self.strike_count_of(b)
      return b.strike_count if b.respond_to?(:strike_count)
      flag_of(b, :dual_attack?) ? 2 : 1
    end

    def self.from_actor(a)
      c = Combatant.new(a.name, a.atk, a.def, a.agi, a.hp, a.max_hp,
                    nil, false, a.mp, a.max_mp, a.int, nil, a, actor_states(a),
                    nil, crit_chance_of(a), prevents_crit_of(a),
                    attr_ranks_of(a), atk_attrs_of(a), nil, hit_rate_of(a),
                    state_ranks_of(a))
      c.strikes = strike_count_of(a)
      c.ignores_evasion = flag_of(a, :ignores_evasion?)
      c.attack_all = flag_of(a, :attack_all?)
      c.preemptive = flag_of(a, :preemptive?)
      c.strong_defence = flag_of(a, :strong_defence?)
      c.half_sp_cost = flag_of(a, :half_sp_cost?)
      c.evasion_up = flag_of(a, :physical_evasion_up?)
      c.attr_base_ranks = c.attr_ranks.dup
      c.atk_states = atk_states_of(a)
      # RPG2003 front/back row: seeded from the actor's own persisted
      # `#battle_row` (a fresh actor's own default -- RPG2000 never sets it,
      # so this stays front there too). Ported from a reference
      # implementation's own actor model, NOT independently confirmed
      # against genuine RPG_RT under wine: row is runtime/save state
      # (`data.row`, SaveActor field
      # 0x5B) that the in-battle Row command toggles, not something derived
      # from the Battle Commands placement table (0x1D field 2) or the
      # actor's manual `battle_x`/`battle_y` -- `GetOriginalPosition()` reads
      # those two independently of row, and `Calculate2k3BattlePosition`'s
      # `row_x_offset` only ever *reads* the already-set row back, for the
      # automatic-placement sprite's own on-screen X (still unmodelled here).
      c.row = a.respond_to?(:battle_row) ? a.battle_row : ROW_FRONT
      # RPG2003 active-time gauge: seeded from the actor's own persisted
      # #atb_gauge, the same way #row is -- see Actor#atb_gauge's own
      # citation for why RPG_RT carries this across fights instead of
      # starting every battle from empty.
      c.gauge = a.respond_to?(:atb_gauge) ? a.atb_gauge : 0
      c
    end

    # A boolean predicate on the source row, false for a fixture without it.
    def self.flag_of(b, name); b.respond_to?(name) && b.send(name) ? true : false; end

    # Enemies have no source actor (that field stays nil), so the post-battle
    # write-back skips them; they carry no status set into this simple sim.
    def self.from_enemy(e)
      c = Combatant.new(e.name, e.atk, e.def, e.agi, e.hp, e.max_hp,
                        nil, false, e.sp, e.max_sp, e.spi, nil, nil, [], nil,
                        crit_chance_of(e), prevents_crit_of(e),
                        attr_ranks_of(e), atk_attrs_of(e), nil, hit_rate_of(e),
                        state_ranks_of(e))
      # A member the troop flagged invisible starts out of play until a Show
      # Hidden Monster command brings it in (see Combatant#out_of_play?).
      c.hidden = e.respond_to?(:hidden) && e.hidden ? true : false
      # The 行動パターン the AI picks from each turn, and the database id it was
      # built from (which a transformation re-points at another enemy row).
      c.actions = e.respond_to?(:actions) ? (e.actions || []) : []
      c.enemy_id = e.respond_to?(:id) ? e.id : nil
      # The Monster/<name> graphic, carried so the battle screen can redraw a
      # combatant whose transformation swapped it.
      c.battler_name = e.respond_to?(:battler_name) ? e.battler_name : nil
      c.battler_hue = e.respond_to?(:battler_hue) ? (e.battler_hue || 0) : 0
      c.attr_base_ranks = c.attr_ranks.dup
      c
    end

    # RPG2000-style physical damage: half the attacker's attack less a quarter of
    # the defender's defence, floored at 0 -- not 1. Confirmed against genuine
    # RPG_RT under wine (2026-09-05): an atk-1 enemy's basic Attack against a
    # def-999 (the battle stat cap) target -- deeply negative pre-floor
    # (1/2 - 999/4 = -249) -- landed as a genuine zero-damage hit, printing
    # RPG_RT's own "...はダメージを受けていない!" (took no damage) line, distinct
    # from an ordinary miss's own "...は攻撃をかわした!" (dodged) line seen on
    # other rounds of the same fight.
    # A heavily-armoured target can shrug off a weak attacker's blow entirely
    # (a genuine "no damage" hit, not a guaranteed minimum scratch); `#deal_attack`
    # already builds an ordinary attack-shaped log entry regardless of the
    # resulting damage value, and `#battle_result_line` (`scene/battle.rb`) already
    # renders a 0 as the "undamaged" term line rather than a damage number, so
    # this needed no companion change beyond the floor itself.
    def self.attack_damage(atk, dfn)
      d = atk / 2 - dfn / 4
      d < 0 ? 0 : d
    end

    MAX_ROUNDS = 1000 # safety net against a stalemate (should never be reached)

    # RPG_RT's battle damage popup is a fixed-width widget, so every single hit
    # -- normal attack, dual-wield swing, attack-skill, self-destruct, and
    # per-turn state slip damage alike -- is hard-clamped before it is
    # subtracted from the target's HP, no matter how large the underlying ATK/
    # DEF/attribute math computes. A yado.tk-quirks build with no cap could
    # one-shot a target well past what the original engine could ever display
    # or apply in a single blow. The width itself is edition-gated (ported
    # from a reference implementation's source, NOT independently confirmed
    # against genuine RPG_RT under wine):
    # its max-damage constant is `999` on
    # RPG2000, `9999` on RPG2003 -- the same shape as `MAX_EFFECTIVE_HP_2K`/
    # `_2K3` and `EXP_MAX_2K`/`_2K3` above. That reference implementation's
    # own battle-algorithm
    # code clamps a Normal Attack/Skill/SelfDestruct
    # effect through this single constant symmetrically in *both* directions
    # (a
    # healing skill's own `effect` is just the negative-signed case of the
    # same clamp), so the same pair covers recovery too.
    DAMAGE_CAP_2K = 999
    DAMAGE_CAP_2K3 = 9999
    RECOVER_CAP_2K = DAMAGE_CAP_2K
    RECOVER_CAP_2K3 = DAMAGE_CAP_2K3

    # The effective damage-popup ceiling for this fight -- `DAMAGE_CAP_2K3` on
    # an RPG2003 database, `DAMAGE_CAP_2K` otherwise. Mirrors
    # `Game::Actor#max_hp_cap` exactly.
    def damage_cap
      @rpg2003 ? DAMAGE_CAP_2K3 : DAMAGE_CAP_2K
    end

    # Same as #damage_cap, for HP recovery -- a reference implementation
    # clamps both directions
    # through the one constant, so the two ceilings are identical per edition.
    def recover_cap
      @rpg2003 ? RECOVER_CAP_2K3 : RECOVER_CAP_2K
    end

    attr_reader :allies, :enemies, :rounds, :result, :log, :rng, :escape_chance

    # `states` is an optional state-definition lookup (`[id]` -> a row exposing
    # `restriction` / `hp_change_val` / `hp_change_max` / `sp_change_val` /
    # `sp_change_max`, e.g. the database's `situation` table). When given, a
    # battler's afflicted states take effect each turn (slip damage, skip if it
    # cannot act); omitted, states are inert as before.
    # `variance`, when true, applies RPG2000's +/- spread to each basic attack's
    # damage (a `var` of 4, per a reference implementation's variance-adjust
    # formula). `criticals`,
    # when true, lets a basic attack land a 3x critical at the attacker's
    # `crit_chance` (basis points). `accuracy`, when true, rolls each basic attack's
    # to-hit chance so it can miss (see #to_hit). All three are off by default so
    # a seeded fight is exactly reproducible; the live game turns them on.
    # `first_strike`, when true, gives the party a pre-emptive opening round: the
    # enemies are caught off guard and skip their turn in round 1 only.
    # `attributes` is an optional attribute-definition lookup (`[id]` -> a row
    # exposing `a_rate` .. `e_rate`, e.g. the database's `property` table) so
    # elemental damage reads each attribute's own rank rates; omitted, the
    # RPG2000 default table applies.
    # `ai` is an optional Game::EnemyAi giving the enemies' action patterns the
    # database and game state they need (skill / enemy tables, switches, the
    # party's average level). Without one an enemy can still run the basic
    # actions its pattern lists, but a skill or transformation it cannot resolve
    # falls back to a plain attack — which is exactly the old behaviour, so every
    # existing fixture keeps its results.
    # `party` is an optional live Game::Party reference (Scene::Map#open_battle
    # passes `@state.party`) that opts this fight into re-deriving @allies from
    # the *live* roster around every acting battler -- see
    # #sync_allies_from_party. Omitted (every existing fixture / spec battle
    # that builds `allies` once and hands it to .new directly), @allies is
    # exactly what the constructor was given and never changes membership on
    # its own, unchanged from before this parameter existed.
    def initialize(allies, enemies, rng = nil, states = nil, variance = false,
                   criticals = false, accuracy = false, first_strike = false,
                   attributes = nil, ai = nil, rpg2003: false, party: nil,
                   battle_type: 0)
      @allies = allies
      @enemies = enemies
      @rng = rng || Rng.new(0x2000)
      @states = states
      @variance = variance
      @criticals = criticals
      @accuracy = accuracy
      @first_strike = first_strike
      @attributes = attributes
      @ai = ai
      @rpg2003 = rpg2003 ? true : false
      @party = party
      # RPG2003 battle timing presentation (database Battle Setup chunk 0x1D
      # field 7): 0 traditional (RPG2000-style, turn-based), 1 alternative
      # (actor sprites, no ATB), 2 gauge (per-combatant active-time charge).
      # Only presentation 2 advances the active-time gauge (#advance_gauges);
      # the rest run the existing turn-based machine untouched. Seeded from the
      # database's battle setup when the battle is constructed (see
      # Scene::Battle), defaulting to 0 so every RPG2000 fight is turn-based.
      @battle_type = battle_type || 0
      @rounds = 0
      @result = nil
      @escaped = false # set once the party successfully flees (#attempt_escape)
      # Computed once, right here at battle start -- a reference
      # implementation's battle-start logic
      # computes the escape chance exactly once, before any turn runs, and
      # #attempt_escape only ever adds to that one fixed starting value on a
      # failure (that same logic's own `escape_chance += 10`); nothing
      # re-derives it from the agilities again later. Computing it lazily on
      # the first #attempt_escape call instead (as this used to) reads
      # whatever a state has done to someone's agility by that point in the
      # fight rather than what the roster carried when the fight began.
      @escape_chance = compute_escape_chance
      @force_flee = false  # a battle page granted the party a guaranteed escape
      # RPG2003 row safety net: if the fight would start with nobody in the
      # front row able to act or eventually recover (every front-row ally is
      # hidden, dead, or locked into a permanent do-nothing state), RPG_RT
      # snaps every ally to the front row rather than leaving survivors
      # stuck in the back -- a reference implementation's own actor-init logic
      # ("ROW ADJUSTMENT" comment): `force_front_row` starts true and is cleared
      # the moment any ally is found `!IsHidden() && CanActOrRecoverable()`
      # while in the front row; if the loop never clears it, every actor's
      # row is force-set to front. `#incapacitated?` is this codebase's own
      # `!(!hidden && CanActOrRecoverable)` (it already folds hidden/dead in
      # via `#out_of_play?`, plus the same permanent-restriction check).
      # The write is persistent the same way the in-battle Row command's own
      # write-back is (a reference implementation's own battle-row setter --
      # see Scene::Battle's
      # `:row` handler; not independently confirmed against genuine RPG_RT
      # under wine) -- RPG_RT does not undo it at battle end.
      if @rpg2003 && @allies.none? { |a| a.row == ROW_FRONT && !incapacitated?(a) }
        @allies.each do |a|
          a.row = ROW_FRONT
          a.actor.battle_row = ROW_FRONT if a.actor.respond_to?(:battle_row=)
        end
      end
      @log = []      # one entry per landed attack, in order (see #strike)
      @queue = []    # battlers still to act this round, in agility order
      @pending = []  # extra hits of an all-target action, drained one per #step
      # The battler whose turn is currently resolving (set by #step / #step_action
      # as each one is dequeued, and by #begin_gauge_turn for a gauge-fired
      # action). nil between turns. Exposed as #acting_battler for the per-battler
      # battle-page checks (#enemy_turn/#actor_turn/#actor_command's `source`).
      @acting = nil
    end

    # RPG2000 normal-attack damage variance on the 0-10 `var` scale.
    NORMAL_ATTACK_VARIANCE = 4

    # State `restriction` values (lcf::rpg::State::Restriction): the battler
    # cannot act (asleep / paralysed), is forced to attack a random enemy
    # (berserk / provoke), or attacks a random member of its own side (confused).
    RESTRICTION_DO_NOTHING   = 1
    RESTRICTION_ATTACK_ENEMY = 2
    RESTRICTION_ATTACK_ALLY  = 3

    # A state's own `type` field (situation table element 2): 0 (the schema
    # default) is battle-only, cleared at battle end; 1 also persists onto
    # the map. Matches liblcf's `Persistence` enum (`Persistence_ends` = 0,
    # `Persistence_persists` = 1) verified against its generated state.h --
    # a reference implementation's own end-of-battle state cleanup
    # strips exactly the `ends` states.
    STATE_PERSISTS_ON_MAP = 1

    # True once one side has been wiped out, or the party has fled — the battle
    # is decided. The two sides use genuinely different tests, not a shared
    # symmetric one: ported from a reference implementation's own win/loss
    # checks -- they
    # are "no enemy is active" for the
    # enemy side against `CanActOrRecoverable()` (`incapacitated?`'s own
    # source) per party member for the ally side -- the enemy-side check
    # bottoms
    # out in a battler-exists test (not hidden,
    # not dead, and in the party), a bare dead-or-hidden test with no
    # restriction/recovery check at all. The ally-side widening to "locked
    # into a permanent do-nothing state" exists purely to avoid a stall
    # where the player can never submit another command; the enemy side has
    # no such risk (the player can always keep attacking a
    # restricted-but-alive enemy), so a fully-Stoned enemy troop must still
    # be finished off with real damage, not treated as an instant win.
    #
    # Confirmed against genuine RPG_RT under wine (2026-09-05): Nepheshel's
    # real skill 87 (時の砂, inflicting real state 18, restriction 1 /
    # do-nothing) landed on a solo, full-HP enemy in an otherwise-empty
    # troop; the battle did not end there -- the enemy's own next turn
    # still came up (its state's own "Mrrorは止まっている!" reminder fired,
    # proving it was still in the fight rather than defeated), the command
    # menu returned normally afterward, and re-opening Attack still listed
    # the enemy at full HP as a live target. No Victory screen at any point
    # despite the enemy never taking a single point of damage.
    def finished?; @escaped || !alive?(@allies) || !enemy_active?(@enemies); end

    # Whether the party successfully escaped this fight.
    def escaped?; @escaped; end

    # -- battle-event context -------------------------------------------------
    #
    # The protocol the troop's battle-event pages run against: Game::BattlePage
    # tests their conditions through it and Game::Interpreter's battle commands
    # (Change Monster HP / MP / Condition, the battle Conditional Branch, ...)
    # act on it. Enemies are addressed by their 0-based index within the troop,
    # the way the editor numbers them.

    # Turns elapsed, counted from 0 before the first round has run — RPG2000's
    # battle turn number, which the pages' turn conditions are written against.
    def turn; @rounds; end

    # The battler whose turn is currently resolving -- set as each battler is
    # dequeued to act (#step / #step_action) or queued for a gauge-fired turn
    # (#begin_gauge_turn), nil between turns. The `source` the per-battler
    # battle-page checks (#enemy_turn / #actor_turn / #actor_command) gate on:
    # the scene passes this at a battler's action boundary, so a
    # turn_enemy / turn_actor / command_actor page tests the battler it is
    # checked for rather than anyone's counter.
    def acting_battler; @acting; end

    # The live combatant for troop member `index`, or nil when out of range.
    def enemy(index)
      return nil unless index.is_a?(Integer) && index >= 0
      @enemies[index]
    end

    # The live combatant for the party member whose database actor id is `id`
    # (nil when that actor is not in this fight).
    def ally_by_actor_id(id)
      @allies.find { |a| a.actor && a.actor.respond_to?(:id) && a.actor.id == id }
    end

    # Whether this fight is running under an RPG2003 database — `Game::Party`'s
    # own `#rpg2003?` reads the same underlying flag; exposed here too since
    # `BattlePage.active?` gates the RPG2003-only page conditions on the
    # battle context (`ctx`, always a `Battle`) rather than the party.
    def rpg2003?; @rpg2003; end

    # Turns taken by troop member `index` / by the party member whose database
    # actor id is `id` — the RPG2003 per-battler turn counters the pages'
    # turn_enemy / turn_actor conditions test (Combatant#turns_taken). nil for a
    # battler that is not in this fight, which fails the page rather than
    # answering a condition about someone who is not here.
    #
    # `source` is the battler a per-battler page check is running *for*
    # (the scene passes #acting_battler at a battler's action boundary): when
    # one is given, the named battler's counter only answers if the source *is*
    # that battler — ported from a reference implementation's own condition
    # check, NOT independently
    # confirmed against genuine RPG_RT under wine — so a page checked at one
    # battler's turn never fires off a *different* battler's counter. A
    # no-source round-boundary check stays ungated, matching that ported behavior.
    def enemy_turn(index, source = nil)
      foe = enemy(index)
      return nil unless foe
      return nil if source && !source.equal?(foe)
      foe.turns_taken
    end

    def actor_turn(id, source = nil)
      ally = ally_by_actor_id(id)
      return nil unless ally
      return nil if source && !source.equal?(ally)
      ally.turns_taken
    end

    # The party's exhaustion, 0 (untouched) to 100 (wiped out) — the RPG2003
    # `fatigue` page condition. Ported from a reference implementation's own
    # fatigue calculation,
    # NOT independently confirmed against genuine RPG_RT under wine: HP is
    # two thirds of the weight and SP one third, so a party at full HP with
    # no SP left still only reaches 33. An SP-less party divides by 1 rather
    # than 0, exactly as the ported source notes.
    #
    # Written in integer arithmetic (mruby has no rounding helper here) with
    # round-half-**to-even**, not round-half-up: a reference implementation's
    # own rounding helper calls the platform's rounding function, which under
    # the default IEEE
    # 754 rounding mode (`FE_TONEAREST`, which nothing in that source
    # changes) rounds an exact `.5` to the nearest *even* integer, not always
    # up (this rounding-mode detail is likewise ported, not independently
    # confirmed). A single ally at max_hp 16 / hp 3 with no SP (total_sp
    # forced to 1) computes exactly 12.5 before rounding -- the ported
    # behavior rounds that to 12 (even), this method used to round it to 13
    # (a prior version's comment incorrectly assumed C rounds `.5` up),
    # landing the `fatigue` page condition/enemy AI threshold one point apart
    # at that exact boundary (88 vs 87).
    def fatigue
      return 0 if @allies.empty?
      hp = 0; total_hp = 0; sp = 0; total_sp = 0
      @allies.each do |a|
        hp += a.hp
        total_hp += a.max_hp || 0
        sp += a.mp || 0
        total_sp += a.max_mp || 0
      end
      return 0 if total_hp <= 0
      total_sp = 1 if total_sp <= 0
      num = 100 * (2 * hp * total_sp + sp * total_hp)
      den = 3 * total_hp * total_sp
      100 - Game.round_half_even(num, den)
    end

    # The `command_actor` page condition: which battle command the *acting*
    # battler chose (Combatant#last_battle_action, recorded by the scene at
    # command selection). Port of a reference implementation's own
    # condition check, NOT independently confirmed against
    # genuine RPG_RT under wine: the condition only evaluates when handed a
    # `source` battler (`if (!source) return false;`), the source must *be* the
    # named actor (`if (source != actor) return false;`), and then the actor's
    # chosen command is compared. `source` is the battler a per-battler page
    # check runs for (the scene passes #acting_battler at a battler's action
    # boundary); a no-source round-boundary check — the only kind RPG2000's own
    # battle scene ever has — answers nil and the condition fails, matching
    # that ported behaviour.
    def actor_command(actor_id, source = nil)
      return nil unless source
      a = source.actor
      return nil unless a && a.respond_to?(:id) && a.id == actor_id
      source.last_battle_action
    end

    # Conditional Branch (Battle) test 4, "the currently-targeted troop
    # member is param1": the troop slot index of `source`'s own currently-
    # resolved single enemy target, or nil when there is no such single
    # target. Port of a reference implementation's own single-target
    # tracking (set right before a page's pre-action events
    # run), NOT independently confirmed against genuine RPG_RT under wine:
    # only computed when `source->GetType() == Type_Ally`, from that
    # action's own `GetOriginalSingleTarget()` -- the target chosen at
    # command time, before any forced-restriction (Berserk/Confuse)
    # override -- and only when that target is itself an enemy (`Type_
    # Enemy`); an all-target action or one aimed at an ally leaves
    # `targets_single_enemy` false. This port's own equivalent of "the
    # original single target": a basic Attack's plain `#action` field, or a
    # single-target Skill/Item's `#command[:target]` (nil for an all-target
    # `#command[:all]` action). `@enemies.find_index` compares by identity
    # (`#equal?`), not the Struct's own value equality, since two same-type
    # enemies sharing every stat would otherwise collide onto the wrong
    # index the way `#turn_order`'s own citation on this exact hazard
    # already documents. Only ever resolved for an ally `source` -- RPG_RT
    # itself only ever *sets* these fields for an acting ally; an
    # enemy-sourced page run instead inherits whatever the last acting ally
    # left behind (`// Enemy doesn't change the values...`), a real but
    # rarely-observable quirk left unmodelled here.
    def target_enemy_index(source)
      return nil unless source
      a = source.actor
      return nil unless a
      target = source.command ? (source.command[:all] ? nil : source.command[:target]) : source.action
      return nil unless target
      @enemies.find_index { |e| e.equal?(target) }
    end

    # Force Flee (1006), target 0: let the party leave whenever it next tries.
    # RPG_RT grants the escape rather than performing it, so the player still has
    # to pick Flee — #attempt_escape then always succeeds.
    def force_flee_party; @force_flee = true; end

    # Whether a Force Flee has granted the party its guaranteed escape.
    def force_flee?; @force_flee; end

    # Force Flee, target 2: troop member `index` runs from the fight. The
    # combatant is hidden, which takes it out of play (Combatant#out_of_play?)
    # without counting as a kill. Returns whether anyone actually left, so the
    # caller only plays the escape sound when one did.
    def flee_enemy(index)
      foe = enemy(index)
      return false if foe.nil? || foe.dead? || foe.hidden
      foe.hidden = true
      true
    end

    # Force Flee, target 1: every troop member still standing runs. Returns the
    # indices that left.
    def flee_all_enemies
      fled = []
      @enemies.each_index { |i| fled.push(i) if flee_enemy(i) }
      fled
    end

    # Terminate Battle (13410): abandon the fight outright. Unlike a victory or
    # defeat this has no outcome to process, so it is kept as its own flag the
    # scene polls rather than folded into #finished? / #result.
    def terminate; @terminated = true; end
    def terminated?; @terminated ? true : false; end

    # Persist the fight's outcome onto the real party: write each ally combatant's
    # final status set, HP and SP back to its source actor, so damage taken in
    # battle sticks, a status cured (or inflicted) in battle carries out, and a
    # combatant reduced to 0 comes out knocked out (戦闘不能). Combatants without a
    # source actor -- enemies, or bare test snapshots -- are skipped. States are
    # written before HP so `set_hp` gets the last word on the death state.
    #
    # A battle-only state (situation.type 0, the default -- see
    # STATE_PERSISTS_ON_MAP) never makes it into that write-back: a reference
    # implementation strips those at battle end before the
    # map ever sees them, so carrying one through here would let a status the
    # player could not have cured outside battle sit on the field party
    # indefinitely. A state whose row can't be found is dropped the same way
    # rather than guessed at, matching this file's usual dangling-reference
    # handling.
    def apply_to_party
      @allies.each do |c|
        next unless c.actor
        c.actor.states = surviving_states(c.states) if c.states && c.actor.respond_to?(:states=)
        c.actor.set_hp(c.hp)
        c.actor.mp = Game.clamp(c.mp, 0, c.actor.max_mp) if c.mp
        # A survivor's active-time gauge carries into the next fight; one who
        # ended this fight dead carries 0 instead, matching AddState's own
        # Knockout-zeroes-the-gauge rule -- see Actor#atb_gauge.
        c.actor.atb_gauge = c.hp > 0 ? c.gauge : 0 if c.actor.respond_to?(:atb_gauge=)
        # An Enable Combo (1007) armed for this fight never carries into the
        # next one -- see Actor#clear_battle_combo.
        c.actor.clear_battle_combo if c.actor.respond_to?(:clear_battle_combo)
      end
    end

    # Perform the next single action and return its log entry, or nil when the
    # battle is already decided (or has hit the round cap). Living battlers act
    # in agility order; a new round refills the queue.
    def step
      return @pending.shift unless @pending.empty?
      loop do
        return nil if finished?
        refill_queue if @queue.empty?
        return nil if @queue.empty? # hit MAX_ROUNDS
        b = @queue.shift
        @acting = b
        sync_allies_from_party if @party # see #step_action's own comment on why
        next if b.dead? || !b.member?
        # The battler's own turn starts here, whether or not it ends up able to
        # act — RPG_RT bumps the per-battler counter as the turn begins, not
        # once the action lands (a reference implementation's own next-turn
        # logic).
        b.next_battle_turn
        can_act = apply_turn_states(b)
        # A do-nothing restriction locked in when this round's queue was
        # built (or picked up live, above, from one inflicted since) always
        # wins over a cure that landed in between -- see the Combatant
        # `queued_no_act` field's own comment.
        can_act = false if b.queued_no_act
        next if b.dead? || !can_act
        entry = record_action(strike(b))
        next unless entry # attacker had no living target; try the next
        return entry
      end
    end

    # Log the result of a battler's action and return its first entry, buffering
    # the rest. A basic attack / single-target skill returns one entry; an
    # all-target skill returns an array — every entry is logged now (the effects
    # all landed at once) but surfaced one per #step so the screen animates them
    # in turn. nil (no living target) passes straight through.
    #
    # The acting battler's own #apply_turn_states-computed per-turn state
    # reminder (see Combatant#turn_state_message) rides on the *first* entry
    # only, matching RPG_RT showing it once at the very start of the turn,
    # not once per buffered hit.
    def record_action(result)
      return nil if result.nil?
      entries = result.is_a?(Array) ? result : [result]
      return nil if entries.empty?
      entries.first[:state_message] = @acting.turn_state_message if @acting
      entries.each { |e| @log << e }
      @pending.concat(entries[1..-1])
      entries.first
    end

    # Step the fight to completion and return :victory, :defeat or (if the party
    # fled via #attempt_escape) :escaped.
    def run
      step until finished? || @rounds > MAX_ROUNDS
      @result ||= alive?(@allies) ? :victory : :defeat
    end

    # Assign an ally's action for the coming round: attack `target`, or defend
    # (take half damage and not attack). Player-driven battles command each ally
    # before running the round; enemies choose their own action.
    def command_attack(ally, target)
      ally.action = target; ally.defending = false; ally.command = nil
    end

    def command_defend(ally)
      ally.action = nil; ally.defending = true; ally.command = nil
    end

    # Forfeit `ally`'s action for the round — it neither attacks nor gains a
    # defend's damage cut — used when a failed escape costs the party its turn
    # and for the RPG2003 **Special** battle command, whose turn resolves to
    # exactly this (a reference implementation's own do-nothing algorithm: the
    # actor spends its turn doing nothing, no message, no animation — see the
    # scene's `select_battle_command` `:special` arm). Cleared with the other
    # commands at #end_round.
    def command_skip(ally)
      ally.action = nil; ally.defending = false; ally.command = nil; ally.skip = true
    end

    # Whether `ally` may leave the front row right now: RPG2003 refuses to
    # empty the front row entirely (real RPG_RT buzzes and stays on the
    # command menu if the player tries), ported from a reference
    # implementation's own row-selection guard. That guard also folds in
    # a direction-flip check (a battler-mirroring mechanic this engine does
    # not model, and which no ordinary actor ever sets in the reference
    # either -- it always reads false there), so the surviving, always-true
    # part of the condition is exactly "at least one *other* ally is still in
    # front" -- moving from back to front never needs this check at all,
    # since it can only ever add to the front row. That guard's own headcount
    # loop walks every party actor unfiltered -- a KO'd or hidden
    # ally still counts toward keeping the front row non-empty, same as
    # `@allies` here; only #member?-false (left the live party) is excluded.
    def can_leave_front_row?(ally)
      allies.reject { |a| !a.member? }.count { |a| a != ally && !a.back_row? } >= 1
    end

    # The RPG2003 **Row** battle command: flip `ally` between front and back
    # row (ADR 0053's row mechanic), refusing a front-row ally's toggle that
    # would leave the front row empty (#can_leave_front_row?). Returns
    # whether the row actually changed, so the scene can play the reference's
    # Buzzer SE instead of committing a turn when it did not. A successful
    # toggle still costs the ally's turn -- a reference implementation's own
    # row-selection logic queues a do-nothing action the same way the Special
    # command does -- which is
    # the scene's job (`#command_skip`) once this returns true.
    def toggle_row(ally)
      return false if !ally.back_row? && !can_leave_front_row?(ally)
      ally.row = ally.back_row? ? ROW_FRONT : ROW_BACK
      true
    end

    # Average agility of every battler on `side` (a reference implementation's
    # own average-agility calculation, an int-truncating sum / count), 1 for
    # an empty side (its own `battlers.empty() ? 1 : ...` fallback, so a
    # division downstream never sees a zero party). **A fallen battler still
    # counts**: that calculation sums over every member rather
    # than only the not-dead-or-hidden subset one might reach for
    # here -- there is no live/dead branch in it at all -- so a fight where two
    # of four party members are already down still divides by four and adds
    # their agility in, not the two survivors'. Each battler's own #effective_agi
    # already folds in any agi-affecting state (that same source's own
    # parameter adjustment),
    # which a death itself does not reset or exclude.
    def avg_agi(side)
      return 1 if side.empty?
      side.reduce(0) { |s, b| s + effective_agi(b) } / side.size
    end

    # The escape chance this fight started with, as a percentage (0..100)
    # (see the class's own `attr_reader` above) -- fixed at construction by
    # #compute_escape_chance and only ever bumped by +10 per failed
    # #attempt_escape from there, ported from a reference implementation's own
    # escape-chance init / retry logic, neither of which touches
    # the agilities again once the fight is under way.
    #
    # That reference implementation's own escape-chance init:
    # 150 - round(100 * enemyAgi / partyAgi),
    # clamped 0..100, so a nimbler party flees more often and a slower one
    # struggles; an agility-less party falls back to a coin toss (partyAgi is
    # never actually 0 here -- #avg_agi floors at 1 -- so this branch is a
    # defensive guard against a Ruby ZeroDivisionError rather than a case
    # InitEscapeChance itself has to handle). **The ratio is rounded to the
    # nearest percent, not truncated**: that calculation computes it in
    # `double` and finishes with a rounding helper ("RPG_RT /
    # Delphi compatible rounding"), unlike this same battle's own #to_hit
    # agility term, which RPG_RT computes in `float` and truncates on its
    # implicit int conversion -- the two nearby agility-ratio formulas round
    # differently in the reference itself, not just here.
    #
    # "Delphi compatible rounding" is banker's rounding -- ties go to the
    # nearest *even* integer, not always up (`std::lrint` under the default
    # IEEE 754 `FE_TONEAREST` mode; a reference implementation's own rounding
    # helper doc comment cites Delphi's own `Round()`, which is documented as
    # exactly this). A prior version of this method used Ruby's `Float#round`,
    # which rounds half *away from zero* -- the same rounding-mode gap
    # `Game::Battle#fatigue` had (see `Game.round_half_even`'s own comment) --
    # so an exact `.5` ratio (e.g. party average agility 200, enemy average
    # 101: `100*101/200 = 50.5` precisely) rounded up to 51 here instead of
    # that reference implementation's 50, landing the escape chance one point
    # off (99 vs 100).
    def compute_escape_chance
      pa = avg_agi(@allies)
      ea = avg_agi(@enemies)
      base = pa > 0 ? Game.round_half_even(100 * ea, pa) : 100
      Game.clamp(150 - base, 0, 100)
    end

    # Whether the fight is still within its opening first-strike ambush round --
    # the one window `#attempt_escape`'s own `preemptive` guarantee is meant for.
    # `@rounds` starts at 0 and is bumped to 1 by `#begin_round` (called once
    # every actor's command, including a possible Escape, is already chosen for
    # round 1), so it is still 0 for the whole of that opening command phase and
    # 1-or-higher for every round after -- the same "still round 1, before it's
    # actually begun" window a reference implementation's own `first_strike`
    # flag covers (ported from its source). The overall guarantee this feeds
    # -- a first-strike round's Escape command always succeeding -- is
    # confirmed via wine (2026-09-05): a scripted Enemy Encounter's own
    # Preemptive Attack flag made a round-1 Escape succeed outright even with
    # the party/enemy agility ratio (`#compute_escape_chance`) set up to
    # floor the ordinary roll's own base chance at a genuine 0; an identical
    # setup without that flag left the same Escape command failing every
    # time under that same 0%-chance floor (silently -- the command menu
    # just resets to its default selection, no message either way, so a
    # failed attempt is legible only by the fight still being on afterward,
    # not by any on-screen text). The exact round-1/round-2 *boundary* this
    # method draws (whether `@rounds` is still 0 for the whole of round 1's
    # command phase, not just its very first moment) was not separately
    # isolated by that capture -- only the overall preemptive-escape
    # guarantee itself was under test; its own post-round substate handling
    # clears it to `false` right before opening round 2's own command phase.
    def first_strike?
      @first_strike && @rounds.zero?
    end

    # Attempt to flee the fight. A `preemptive` first strike always succeeds, as
    # does an escape a Force Flee battle page has granted; otherwise a 0..99 roll
    # under #escape_chance wins. Success ends the battle as :escaped (#finished? /
    # #escaped?); a failure raises the next attempt's chance by 10 (per a
    # reference implementation)
    # and returns false, leaving the fight running so the enemies still take
    # their round.
    def attempt_escape(preemptive = false)
      return false if finished?
      if preemptive || @force_flee || @rng.random(100) < escape_chance
        @escaped = true
        @result = :escaped
        true
      else
        @escape_chance = escape_chance + 10
        false
      end
    end

    # `attacker`'s to-hit percentage against `target` for a basic attack: the
    # attacker's base hit rate (weapon / unarmed 90, a "miss" enemy 70), scaled
    # by the attacker's own state-based accuracy penalty, then adjusted by the
    # agility ratio — ported from a reference implementation's own
    # agility-adjustment formula, NOT
    # independently confirmed against genuine RPG_RT under wine, which
    # simplifies to `100 - (100 - base) * (srcAgi + tgtAgi) / (2 * srcAgi)` —
    # so a nimbler target dodges more. Clamped to 0..100. Only consulted when
    # the fight has accuracy enabled (see #initialize).
    #
    # An "Avoid Attacks" (RPG2003, state field 36 `avoid_attacks`) state does
    # NOT make its wielder dodge a basic attack unconditionally -- reverted,
    # confirmed wrong against a genuine RPG_RT.exe under wine (2026-09-05).
    # A reference implementation's own normal-attack-to-hit formula checks
    # whether the target evades all physical attacks first and returns 0
    # immediately, ahead of even the restricted-target "always hits" rule and
    # a 必中 attacker's own evasion-ignoring branch; this codebase used to
    # port that check the same way. Under wine, a target carrying a custom
    # state with `avoid_attacks` set and no other restriction still took a
    # steady, ordinary stream of hits from a plain enemy Attack across eight
    # rounds -- not the zero hits in eight (a few-in-a-billion coincidence at
    # a real ~90% base rate) the ported short-circuit predicts. The field is
    # parsed but genuine RPG_RT does not appear to wire it into the
    # normal-attack to-hit check at all, so the short-circuit was removed
    # rather than kept as a dead port of an apparently-fictional mechanic.
    # A target with a "do nothing" restriction (asleep / paralysed) is the
    # next term down and always gets hit -- that same ported formula's own
    # can-act check returning 100 immediately, ahead of every accuracy term
    # below it. Untouched by this fix; only the avoid_attacks short-circuit
    # ahead of it turned out to be fictional.
    # RPG2003 row accuracy: a back-row defender is harder to hit by a physical
    # attack. Ported from that same formula, also
    # NOT independently confirmed against genuine RPG_RT under wine: it
    # applies a flat 25 to the already agility-adjusted chance when the
    # *defender* is row-adjusted (`to_hit -= 25`), not the 50% multiplier a
    # pre-reference draft guessed here -- see #row_adjusted? for what
    # "row-adjusted" means and the ADR 0053 note that originally flagged the
    # multiplier as unconfirmed. The front/back row is an RPG2003-only
    # concept, so RPG2000 (which never sets a row) has no adjusted defender
    # and this term is a no-op there.
    ROW_HIT_PENALTY = 25

    # Port of a reference implementation's own row-adjustment check (NOT
    # independently confirmed against genuine RPG_RT under wine) for the only
    # battle condition this runtime models. RPG_RT 2003's row mechanic decides
    # whether a battler's row changes its hit / damage by the *battle condition*
    # (normal / initiative / back-attack / surround) and by the battler's role;
    # this engine models no battle conditions, so the normal (`none`) branch is
    # what holds: a battler standing on the "offense" row is row-adjusted.
    #
    # For an attacker (`offense` true) the offense row is the front: an actor
    # standing in the front row deals +25% damage, and an *enemy* attacker is
    # never row-adjusted -- a reference implementation's own check consults
    # only the actor row there. For a
    # defender (`offense` false) the offense row is the back: a back-row
    # defender is 25 harder to hit and takes -25% damage (allow_enemy true, but
    # an enemy defaulting to the front row is never adjusted). The `row` is
    # read through Combatant#row (nil defaults to the front row, the only row
    # RPG2000 knows).
    #
    # `@rpg2003` gated first: the front row is every RPG2000 ally's permanent
    # default (there is no Row command to ever leave it), so the `offense`
    # branch below is not the no-op its own row-never-changes reasoning
    # promises -- unlike the `defender` branch, which really is a no-op there
    # (row can never read ROW_BACK), `row == ROW_FRONT` is trivially true for
    # every ally, on every attack, in every RPG2000 fight. Without this gate a
    # plain RPG2000 basic attack silently took RPG2003's +25% front-row bonus
    # on every single swing -- confirmed against a real RPG2000 database
    # (Nepheshel): a level 1 actor's very first hit read 25% higher than
    # `Battle.attack_damage` alone accounts for.
    def row_adjusted?(battler, offense)
      return false unless @rpg2003
      row = battler.respond_to?(:row) ? battler.row : ROW_FRONT
      if offense
        ally?(battler) && row == ROW_FRONT
      else
        row == ROW_BACK
      end
    end

    # RPG2003 active-time (gauge) battle timing (ADR 0053, Phase 2). The gauge
    # is a 0..GAUGE_MAX charge each battler accumulates every frame; the moment
    # it is full the battler may act (see #ready_combatants). This is the
    # RPG2003 presentation-2 ("gauge") time system -- RPG2000 (battle_type 0)
    # and the 2003 traditional presentation (1) never advance it and keep
    # running the turn-based machine, so #advance_gauges is a no-op for them.
    #
    # GAUGE_MAX and the fill curve are ported from a reference implementation's
    # RPG_RT 2003 reimplementation, NOT independently confirmed against
    # genuine RPG_RT under wine, replacing the earlier placeholder constants
    # (100 max, one gauge point per AGI per frame) that were flagged TODO
    # against the then-inaccessible RPG_RT specification. The believed curve is
    # *relative*, not linear in AGI: every non-hidden battler's AGI is summed
    # (times 100), each battler's per-frame increment is
    # `GAUGE_MAX / (sum_agi / (agi + 1))`, and all the integer division is
    # truncating -- so a battler with double another's AGI fills nearly twice
    # as fast, and the whole field charges together (a bigger party shares a
    # slower common pace rather than each battler charging at its own absolute
    # rate). A do-nothing-restricted *ally* does not charge, and an
    # enemy always charges (a reference implementation's own can-act-or-is-enemy
    # check), and a dead /
    # hidden / not-a-member battler neither contributes to the sum nor charges.
    GAUGE_MAX = 300_000

    attr_accessor :battle_type

    # Advance every charging battler's gauge by `ticks` frames, gated on
    # battle_type (only the gauge presentation advances it). Ported verbatim
    # from a reference implementation's own gauge-update logic, NOT
    # independently confirmed against genuine RPG_RT under wine: the
    # sum over non-hidden battlers decides each one's share, so faster battlers
    # reach a full gauge sooner but nobody charges at an independent absolute
    # rate.
    def advance_gauges(ticks = 1)
      return unless @battle_type == 2
      visible = all_combatants.reject { |c| c.hidden }
      return if visible.empty?
      sum_agi = visible.reduce(0) { |s, c| s + effective_agi(c) } * 100
      all_combatants.each do |c|
        next if c.out_of_play?
        next if do_nothing_restricted?(c) && side_of(c) != :enemy
        add = GAUGE_MAX / (sum_agi / (effective_agi(c) + 1)) * ticks
        c.gauge = [c.gauge + add, GAUGE_MAX].min
      end
    end

    # Party-member FIFO of who became ready (full gauge, alive, actionable)
    # and is still waiting for a turn -- ported from a reference
    # implementation's own atb-order tracking, NOT independently confirmed
    # against
    # genuine RPG_RT under wine: it
    # walks only the party's own actors -- never the enemy troop
    # -- appending an id the frame it first becomes ready (gauge full, exists,
    # and can act) and erasing it the frame it turns
    # false, and always returns the front of that list: the
    # ally who has been waiting *longest*, not whichever has the highest gauge
    # value. That distinction only ever matters at a tie -- and every ready
    # gauge is always exactly GAUGE_MAX (#advance_gauges clamps it), so ties
    # among simultaneously-ready allies are the *only* case that ever reaches
    # here in real play. Diffed against the ready set on every call rather
    # than hooked into a specific point in the frame loop, so it stays correct
    # regardless of how many times (or how sparsely) #ready_combatants itself
    # is polled.
    def update_ally_ready_order
      @ally_ready_order ||= []
      (@allies || []).each do |a|
        ready = !a.out_of_play? && a.gauge_full?
        already = @ally_ready_order.include?(a)
        if ready && !already
          @ally_ready_order.push(a)
        elsif !ready && already
          @ally_ready_order.delete(a)
        end
      end
    end

    # The combatants whose gauge is full, so the active-time turn picker can
    # pull the next one off the front. Sorted by descending gauge first (in
    # real play every ready gauge is clamped to the identical GAUGE_MAX, so
    # this is always a full tie -- a manually-inflated gauge, past what
    # #advance_gauges would ever produce, is the only way to actually rank
    # here); ties are broken by side (allies before enemies, matching
    # #all_combatants' own ordering) and then, among allies specifically, by
    # #update_ally_ready_order's FIFO -- whoever has been ready longest, not
    # whoever sits earlier in the party roster (see there for why: this is
    # the one part of the tie-break RPG_RT actually specifies). Enemies keep
    # their existing troop-order tie-break; only the ally half of this was
    # ever wrong. Empty for a turn-based battle.
    def ready_combatants
      update_ally_ready_order
      all_combatants.reject(&:out_of_play?).select(&:gauge_full?).sort_by do |c|
        if side_of(c) == :ally
          [-c.gauge, 0, @ally_ready_order.index(c) || 0]
        else
          [-c.gauge, 1, (@enemies || []).index(c) || 0]
        end
      end
    end

    # Every combatant in the fight (allies then enemies), for gauge bookkeeping.
    def all_combatants
      (@allies || []) + (@enemies || [])
    end

    # Reset a combatant's gauge to empty after it has taken its active-time
    # turn, so it must refill from zero before acting again (RPG_RT 2003's
    # gauge behaviour). The per-frame Scene::Battle loop calls this from the
    # turn picker; exposed here so the gauge cycle is unit-testable without
    # the 2003 boot path (Phase 3).
    def reset_gauge(c)
      c.gauge = 0
    end

    # The active-time turn picker: return the next ready combatant (highest
    # gauge; see #ready_combatants) and reset its gauge so the loop can advance
    # and refill it. Returns nil when nobody is ready. A turn-based battle
    # (battle_type != 2) never has a ready combatant, so this is nil there too.
    def pop_ready
      c = ready_combatants.first
      return nil unless c
      reset_gauge(c)
      c
    end

    # Begin `b`'s active-time turn: its gauge fired, so it acts on its own
    # schedule rather than as one slot of an agility-ordered round. This queues
    # `b` as the sole battler of the coming action the way #begin_round queues a
    # whole round, so the existing per-action machinery (#step_action / #strike /
    # the @pending multi-hit buffer / #end_round) runs unchanged for it -- the
    # scene's per-frame picker (RPG2k3::Scene::Battle#drive_battle_atb) calls
    # this once per ready combatant instead of #begin_round once per round.
    #
    # The battler's gauge is reset here (it must refill before acting again),
    # and its own per-battler turn counter is bumped -- RPG2003's
    # turn_enemy / turn_actor page-condition count, the same #next_battle_turn
    # #step bumps when the *round* machine runs one -- so a page's per-battler
    # turn conditions tick in a gauge battle too. A "do nothing" restriction is
    # locked in for the turn the same way #refill_queue locks it at the start of
    # a round. Deliberately does NOT touch @rounds: a gauge battle has no
    # RPG2000-style rounds, so the global turn number (#turn) stays 0 for it and
    # the pages read the per-battler counters instead.
    def begin_gauge_turn(b)
      @pending = []
      @acting = b
      b.next_battle_turn
      b.queued_no_act = do_nothing_restricted?(b)
      reset_gauge(b)
      @queue = [b]
    end

    def to_hit(attacker, target)
      return 100 if do_nothing_restricted?(target)
      # Modify hit chance for each state the *source* has (`#hit_modifier`,
      # e.g. Blind) before the agility term -- a reference implementation
      # folds this in first
      # (multiplying the base hit rate by the state-based modifier) and only
      # then computes the agility adjustment off the already-reduced value,
      # not the raw weapon hit rate. Applying it last instead (multiplying
      # the finished, agility-adjusted percentage) skews the result whenever
      # attacker and target have unequal agility, since the AGI term is not
      # linear in its input.
      base = (attacker.hit_rate || 90) * hit_modifier(attacker) / 100
      # 必中: a weapon flagged `ignore_evasion` skips the agility term entirely —
      # RPG_RT's `CalcNormalAttackToHit` returns before it applies evasion for
      # such a weapon. The attacker's own statuses still spoil its aim (baked
      # into `base` above), since what the flag ignores is the *target's*
      # evasion, not the wielder's blind.
      if attacker.ignores_evasion
        Game.clamp(base, 0, 100)
      else
        src = effective_agi(attacker)
        src = 1 if src < 1
        tgt = effective_agi(target)
        agi_adjusted = 100 - (100 - base) * (src + tgt) / (2 * src)
        # 物理回避率アップ: a shield/armour/helmet/accessory flagged
        # `raise_evasion` (Actor#physical_evasion_up?) subtracts a further
        # flat 25 from the already agi-adjusted chance, right where
        # a reference implementation's own formula applies it -- after the
        # AGI term, and never reached at all by a 必中 attacker (the branch
        # above already returned). Confirmed by an actual wine capture
        # (2026-09-05): with attacker/target agility equal (so the AGI term
        # above cancels to exactly `base`) and a base of 70 (an enemy's own
        # `miss` flag), an armour-equipped leader took roughly half the total
        # damage over an equal number of rounds once `raise_evasion` was set
        # on that armour, versus an otherwise-identical control fixture with
        # the flag off -- consistent with a substantial flat hit-chance
        # reduction, not merely independently ported from a reference
        # implementation's source.
        agi_adjusted -= 25 if target.evasion_up
        # RPG2003 row: a back-row defender is harder to hit (a flat 25, after
        # the AGI term -- a reference implementation's own formula
        # `to_hit -= 25`).
        agi_adjusted -= ROW_HIT_PENALTY if row_adjusted?(target, false)
        Game.clamp(agi_adjusted, 0, 100)
      end
    end

    # "Reflect Magic" (RPG2003 state field 37, `reflect_magic`) does NOT make
    # a Skill cast at its wielder bounce back onto the caster -- removed,
    # confirmed wrong against a genuine RPG_RT.exe under wine (2026-09-05):
    # a party member carrying a freshly-authored reflect_magic-flagged state
    # kept taking an enemy's own single-target Skill damage directly, across
    # two separately-landed casts, never once redirecting it back onto the
    # caster. This codebase used to port a reference implementation's own
    # has-reflect-state check (`reflects_magic?`, scanning every inflicted
    # state via `#state_flag`) and a `reflects_skill?` gate (valid target,
    # opposing side, a real Skill not an Item) consumed by `#apply_command`/
    # `#apply_command_all` to retarget the hit onto the caster -- all three
    # removed outright rather than kept as a dead port of an apparently-
    # fictional mechanic, the same way this session's earlier
    # `evades_all_physical?`/`avoid_attacks` reversal was handled. See
    # `#apply_command`'s own citation for where the redirect used to live.

    # How much the attacker's own statuses cut its accuracy: the **lowest**
    # `reduce_hit_ratio` among the states afflicting it, not the product of
    # them -- ported from a reference implementation's own state-based
    # hit-chance modifier, NOT independently confirmed against
    # genuine RPG_RT under wine (it takes a running minimum). 100 means
    # unhindered.
    #
    # Nothing read this field before, which made 盲目 / Blind — a status whose
    # entire purpose is to make its victim miss — a status that did nothing at
    # all. Nine of Nepheshel's 25 states carry a reduced ratio (Blind halves it,
    # the poisons take 15% off) and two of mtf-meido-action's ten do, its Blind
    # cutting accuracy to a fifth.
    def hit_modifier(b)
      m = 100
      (b.states || []).each do |sid|
        r = state_hit_ratio(state_def(sid))
        m = r if r < m
      end
      m
    end

    # A state's `reduce_hit_ratio`, defaulting to 100 (no reduction) for an
    # unknown state or a fixture row without the field. Distinct from
    # #state_field, whose 0 default would read a missing field as "always miss".
    def state_hit_ratio(d)
      return 100 unless d.respond_to?(:reduce_hit_ratio)
      v = d.reduce_hit_ratio
      v.nil? ? 100 : v
    end

    # -- stat-affecting states (halve/double ATK/DEF/SPI/AGI) ----------------
    #
    # A state can carry an `affect_type` (0 halve / 1 double / 2 no change,
    # the schema's own default) alongside four independent flags naming which
    # stat(s) it touches (`affect_attack` / `affect_defense` / `affect_spirit`
    # / `affect_agility`). Ported from a reference implementation's own
    # per-stat adjustment,
    # **now including its `mod` term too** (`Combatant#atk_mod` and friends,
    # the battle-only ATK/DEF/SPI/AGI offset a *skill's* own same-named
    # affect_attack/affect_defense/affect_spirit/affect_agility flags
    # accumulate onto -- see #apply_stat_mods -- distinct from an
    # attribute-defence shift skill, which moves #attr_ranks instead of a raw
    # stat).
    #
    # #deal_attack / #enemy_autodestruct (basic-attack and self-destruct
    # damage), #to_hit / #avg_agi (accuracy and escape chance) and #turn_order
    # all read the adjusted value here. A battle **Skill**'s power formula
    # (`Game::Party#skill_effect` / `#skill_defence_term`) reads it too, but
    # through its own copy of this same logic (`Game::Party#stat_mode` and
    # friends) rather than this one, since a skill's caster/target is
    # sometimes a bare `Game::Actor` with no `Battle` -- and no `@states` --
    # behind it at all (field/menu skill use); that copy has no `mod` term
    # either, since a bare `Game::Actor` has no `Combatant#atk_mod` to read --
    # matching #skill_attr_shift's own battle-only scope.

    # :half, :double or :normal for `stat_flag` (:affect_attack and friends)
    # on `b` right now. A battler carrying both a halving and a doubling state
    # for the same stat cancels out to :normal, exactly as AdjustParam's own
    # `dbl != half` guard reads -- so Berserk (double ATK) and Weaken (halve
    # ATK) on the same battler net out to its ordinary attack.
    def stat_mode(b, stat_flag)
      half = false; dbl = false
      (b.states || []).each do |sid|
        d = state_def(sid)
        next unless d && state_flag(d, stat_flag)
        case d.respond_to?(:affect_type) ? d.affect_type : 2
        when 0 then half = true
        when 1 then dbl = true
        end
      end
      return :double if dbl && !half
      return :half if half && !dbl
      :normal
    end

    # `value` halved (floored at 1, matching every other halving path in this
    # class) or doubled per `mode`, unchanged for :normal.
    def adjust_stat(value, mode)
      case mode
      when :double then value * 2
      when :half then [value / 2, 1].max
      else value
      end
    end

    # RPG_RT's own ceiling on a *modified* ATK/DEF/SPI/AGI (a reference
    # implementation's own max-stat-battle-value, 9999 by default) -- looser
    # than the 1..999 a raw
    # base stat is clamped to (`Actor#change_param`'s own cap), so a stacked
    # buff has room to climb well past what the base stat alone could reach.
    MAX_STAT_BATTLE_VALUE = 9999

    # `b`'s base stat plus its own #atk_mod/#def_mod/#spi_mod/#agi_mod offset
    # (see #apply_stat_mods), clamped to 1..#MAX_STAT_BATTLE_VALUE the same
    # way a reference implementation's own per-stat adjustment does before
    # states get a say.
    def modified_stat(base, mod)
      Game.clamp(base + (mod || 0), 1, MAX_STAT_BATTLE_VALUE)
    end

    def effective_atk(b)
      adjust_stat(modified_stat(b.atk, b.atk_mod), stat_mode(b, :affect_attack))
    end

    def effective_def(b)
      adjust_stat(modified_stat(b.def, b.def_mod), stat_mode(b, :affect_defense))
    end

    def effective_spi(b)
      adjust_stat(modified_stat(b.spi, b.spi_mod), stat_mode(b, :affect_spirit))
    end

    def effective_agi(b)
      adjust_stat(modified_stat(b.agi, b.agi_mod), stat_mode(b, :affect_agility))
    end

    # The Combatant field (Combatant#atk_mod and friends) each ability-value
    # key names.
    STAT_MOD_FIELD = { atk: :atk_mod, def: :def_mod, spi: :spi_mod, agi: :agi_mod }.freeze

    # Apply `amount` -- the exact same final signed effect a skill hit just
    # applied to HP/SP (post elemental-attribute scaling, variance, and the
    # damage/recovery cap; see the call sites in #apply_skill_hit) -- to
    # `target`'s per-battle ATK/DEF/SPI/AGI modifier, for each key in `keys`
    # (`cmd[:stat_mod_keys]`, see Game::Party#skill_stat_mod_keys). Ported
    # from a reference implementation's own per-stat modifier-change check
    # and its DEF/SPI/AGI
    # siblings: the *running total* (existing modifier + this delta) is
    # clamped to -(base/2)..+base, where `base` is the target's own raw,
    # unmodified stat -- an asymmetric band that lets a buff double a stat but
    # never lets a debuff zero it out entirely. `-(base / 2)` deliberately
    # divides the positive `base` *before* negating, matching C++'s own
    # truncating `-base / 2` (which rounds toward zero, i.e. **up**, for the
    # negative result) rather than Ruby's `-base / 2`, which would floor
    # toward -infinity instead and round the floor *down* one further for an
    # odd base -- the viprpg-dev wiki's "a special skill's ability-value
    # decrease rounds up on ÷2" (contrasted there with a status effect's own
    # halving, #adjust_stat's `value / 2`, which rounds down -- both stats
    # being positive there, "toward zero" and "down" coincide, so no similar
    # care is needed in that method). Returns the `{atk:, def:, spi:, agi:}`
    # deltas actually applied -- possibly smaller than `amount` once clamped,
    # or absent for a stat already pinned at its cap -- for the log entry.
    def apply_stat_mods(target, keys, amount)
      return {} unless keys && !keys.empty? && amount != 0
      applied = {}
      keys.each do |key|
        field = STAT_MOD_FIELD[key]
        next unless field
        base = target.respond_to?(key) ? (target.send(key) || 0) : 0
        cur = target.send(field) || 0
        new_mod = Game.clamp(cur + amount, -(base / 2), base)
        d = new_mod - cur
        next if d == 0
        target.send("#{field}=", new_mod)
        applied[key] = d
      end
      applied
    end

    # Queue a single-target Skill for `ally`: cast on `target` (an enemy for an
    # attack skill, an ally / the caster for a recovery skill), spending `cost`
    # SP and applying the signed HP / SP deltas (negative HP = damage, positive =
    # recovery) computed by Game::Party#battle_skill_command. Resolved in agility
    # order by #apply_command when the round runs. `attack:` is
    # #battle_skill_command's own explicit attack-vs-recovery flag, carried
    # through so #apply_skill_hit does not have to re-derive it from the sign
    # of `hp` alone -- which is ambiguous exactly at a 0-damage hit. Left `nil`
    # (rather than defaulted `false`) when the caller does not pass it, so
    # #apply_skill_hit still falls back to the sign of `hp` for a command built
    # by hand with a negative `hp` and no explicit `attack:`.
    #
    # `item_id:` is for a skill invoked by a special/use_skill battle item
    # rather than chosen from the caster's own list (see #battle_skill_command's
    # `free:`, which such a caller pairs this with) -- carried through to the
    # produced log entry exactly like #command_item's own field, for
    # #drive_battle_animate's bag consumption.
    def command_skill(ally, target, name:, cost:, hp: 0, mp: 0, inflict: nil,
                      chance: 100, variance: 0, attributes: nil, skill_id: nil,
                      absorb: false, attr_shift: nil, attr_ids: nil,
                      stat_mod_keys: nil, stat_effect: 0, cured: nil, attack: nil,
                      physical_rate: 0, item_id: nil, switch_id: nil)
      ally.command = { kind: :skill, target: target, name: name,
                       skill_id: skill_id, item_id: item_id, absorb: absorb, attack: attack,
                       cost: cost, hp: hp, mp: mp,
                       inflict: inflict || [], chance: chance, variance: variance,
                       attributes: attributes || [],
                       attr_shift: attr_shift, attr_ids: attr_ids || [],
                       stat_mod_keys: stat_mod_keys || [], stat_effect: stat_effect,
                       cured: cured || [],
                       # #apply_skill_hit's own #shake_off_states call (a
                       # physical skill can shake a status loose the same way a
                       # basic attack does) reads this -- see
                       # #battle_skill_command's own `physical_rate` comment.
                       # Was silently dropped here entirely until this field
                       # existed: #shake_off_states always rolled against 0,
                       # so no skill's physical-rate cure ever fired.
                       physical_rate: physical_rate || 0,
                       # A **switch** skill's own switch, the same ride-along
                       # `#command_item`'s identical field is for a switch item
                       # -- `#apply_skill_hit`'s recovery branch already reads
                       # `cmd[:switch_id]` onto the produced log entry, and
                       # `Scene::Battle#drive_battle_animate` flips it there.
                       switch_id: switch_id }
      ally.action = nil; ally.defending = false
    end

    # Queue an all-target Skill for `ally` (scope 1 all enemies / 4 all allies):
    # `targets` is a list of per-target `{ target:, hp:, mp: }` effects (the same
    # signed HP / SP deltas #command_skill takes, one per target, since attack
    # damage varies with each target's defence). The SP `cost` is spent once when
    # the action resolves; the shared `inflict` / `chance` / `variance` /
    # `attributes` / `attr_shift` / `attr_ids` apply to every target -- unlike
    # damage, which attribute (or none) a skill affects and which way is a
    # property of the skill itself, not of who it lands on. #apply_command
    # produces one log entry per living target, drained one at a time by
    # #step_action.
    #
    # `item_id:` mirrors #command_skill's own identical field, for the same
    # item-invoked-skill case's bag consumption -- #apply_command_all already
    # keeps it on the volley's first produced entry only, the same
    # single-consumption rule #command_item_all's own `item_id:` follows.
    def command_skill_all(ally, targets, name:, cost:, inflict: nil, chance: 100,
                          variance: 0, attributes: nil, skill_id: nil,
                          absorb: false, attr_shift: nil, attr_ids: nil,
                          stat_mod_keys: nil, stat_effect: 0, cured: nil, attack: nil,
                          physical_rate: 0, item_id: nil)
      ally.command = { kind: :skill, all: true, targets: targets, name: name,
                       skill_id: skill_id, item_id: item_id, absorb: absorb, attack: attack, cost: cost,
                       inflict: inflict || [], chance: chance,
                       variance: variance, attributes: attributes || [],
                       attr_shift: attr_shift, attr_ids: attr_ids || [],
                       stat_mod_keys: stat_mod_keys || [], stat_effect: stat_effect,
                       cured: cured || [],
                       # See #command_skill's identical field for what this
                       # feeds and why it has to ride along here too.
                       physical_rate: physical_rate || 0 }
      ally.action = nil; ally.defending = false
    end

    # Queue a single-target Item for `ally` on `target`: restore the HP / SP and
    # cure the status conditions from Game::Party#battle_item_command. `item_id`
    # rides along on the log entry so the scene consumes one from the bag when the
    # action lands. `switch_id` is the same ride-along for a switch item (type
    # 10, no real target -- the scene passes `ally` itself as `target` for one,
    # see Scene::Map#apply_pending_switch_item): the scene flips it when the
    # action lands too, the same moment the bag is finally debited.
    def command_item(ally, target, item_id:, name:, hp: 0, mp: 0, cured: nil, switch_id: nil)
      ally.command = { kind: :item, target: target, item_id: item_id,
                       name: name, hp: hp, mp: mp, cured: cured || [], switch_id: switch_id }
      ally.action = nil; ally.defending = false
    end

    # Queue an all-ally Item for `ally` (an item scope 1, the whole party):
    # `targets` is a list of per-member `{ target:, hp:, mp: }` recoveries. The
    # shared `cured` states apply to each. One item is consumed for the volley
    # (only the first produced entry carries `item_id`, so the scene's per-entry
    # bag deduction fires once).
    def command_item_all(ally, targets, item_id:, name:, cured: nil)
      ally.command = { kind: :item, all: true, item_id: item_id, targets: targets,
                       name: name, cured: cured || [] }
      ally.action = nil; ally.defending = false
    end

    # Execute one full round — living battlers act in agility order, allies using
    # their assigned action, enemies attacking a random party member — and return
    # the round's log entries. Ally commands are cleared afterwards for the next
    # round. `finished?` / `result` report the outcome once a side is wiped.
    def run_round
      begin_round
      entries = []
      while (entry = step_action)
        entries << entry
      end
      end_round
      entries
    end

    # Prime the agility-ordered queue for a fresh round so #step_action can walk
    # it one action at a time — the on-screen battle animates a round action by
    # action rather than applying it all at once (#run_round is just this three-
    # step sequence run to completion). Counts towards the MAX_ROUNDS cap.
    def begin_round
      @pending = []
      refill_queue
    end

    # Perform the next single action of the round primed by #begin_round and
    # return its log entry, skipping battlers that are dead or (allies) defending.
    # Returns nil once the round's queue is exhausted or the battle is decided —
    # the caller then clears commands with #end_round and either shows the result
    # or asks for the next round. Unlike #step it never starts a new round.
    #
    # `sync_allies_from_party` (mid-battle roster sync) runs again right here,
    # not only once at #refill_queue -- ported from a reference
    # implementation's own pre-action substate, which rechecks whether the
    # battler still exists (not hidden, not dead, still in the party)
    # immediately before running *each* queued
    # action and discards the ones that fail, NOT independently
    # confirmed against genuine RPG_RT under wine -- adopted over this
    # codebase's own prior community-trivia writeup, which claimed the
    # opposite ("swap out then back in still lets
    # the queued command execute"). It does not: a party member who leaves
    # *after* their action was queued this round but *before* their turn comes
    # up loses that turn, exactly like a battler who dies first already did
    # here (`next if b.dead?`, unchanged) -- only a turn that has already
    # resolved is unaffected, since nothing here ever reaches back into `@log`.
    def step_action
      return @pending.shift unless @pending.empty? # drain a buffered all-target hit
      loop do
        return nil if finished? || @queue.empty?
        b = @queue.shift
        @acting = b
        sync_allies_from_party if @party
        next if b.dead? || !b.member?
        # Afflicted states act at the start of the battler's turn: slip damage
        # (which cannot itself knock it out -- see apply_turn_states) and, if it
        # cannot act (asleep / paralysed), its turn is skipped.
        can_act = apply_turn_states(b)
        # ...unless a do-nothing restriction was already locked in when this
        # round's queue was built -- see #step's own comment and the
        # Combatant `queued_no_act` field's.
        can_act = false if b.queued_no_act
        next if b.dead? || !can_act
        entry = record_action(strike(b))
        next unless entry
        return entry
      end
    end

    # Whether the entry #step_action just returned was the last buffered hit
    # of its battler's action (a dual-wield swing or an all-target Skill/Item
    # both queue several) -- true once nothing more of that battler's action
    # remains to drain. The battle screen uses this to know when a *whole
    # battler's turn* has finished, not just one hit of it, since a battle
    # page is checked once per acting battler (see Scene::Map#run_battle_events),
    # not once per hit.
    def pending_empty?; @pending.empty?; end

    # Close a round begun with #begin_round: clear each ally's chosen action (so
    # the next round starts fresh) and settle the result once a side is wiped.
    def end_round
      @allies.each do |a|
        a.action = nil; a.defending = false; a.command = nil; a.skip = false
      end
      @result = alive?(@allies) ? :victory : :defeat if finished? && !@escaped
    end

    # Whether one of `b`'s statuses seals skill row `sk`. RPG2000 gives a state
    # two independent seals, each with a threshold: `restrict_skill` bars any
    # skill whose `physical_rate` reaches `restrict_skill_level`, and
    # `restrict_magic` bars any whose `magical_rate` reaches
    # `restrict_magic_level` (a reference implementation's own skill-usability
    # check). A threshold
    # of 1, which is what both test beds use, therefore seals everything with any
    # magic in it while leaving a purely physical skill alone.
    #
    # This is what 封印 / Silence are *for*, and nothing consulted either field —
    # Nepheshel seals magic with 恐怖 and 封印, mtf-meido-action with Silence, and
    # all three left the victim casting freely.
    def skill_sealed?(b, sk)
      return false unless sk
      (b.states || []).each do |sid|
        d = state_def(sid)
        next unless d
        return true if state_flag(d, :restrict_skill) &&
                       (sk.physical_rate || 0) >= state_field(d, :restrict_skill_level)
        return true if state_flag(d, :restrict_magic) &&
                       (sk.magical_rate || 0) >= state_field(d, :restrict_magic_level)
      end
      false
    end

    # Whether `b` cannot be handed a manual command this round at all: a
    # currently-active "do nothing" restriction (asleep/paralysed) discards
    # whatever gets queued for it regardless, once the round actually runs
    # (#apply_turn_states skips the whole turn outright), and a forced
    # attack-ally/attack-enemy restriction (confused/berserk,
    # #battler_restriction) overrides whatever gets queued with a random
    # forced target regardless (#strike). Ported from a reference
    # implementation's own next-actor selection logic (a can-act check
    # together with a significant-restriction check), NOT independently
    # confirmed against genuine RPG_RT under wine: it skips the
    # Fight/Skill/Defend/Item prompt entirely for exactly these two cases
    # rather than asking the player to pick a command that can never take
    # effect. The caller is expected to auto-advance past such an ally with
    # nothing written to its command/action fields -- the same no-command
    # default an unrestricted ally with no explicit choice already falls
    # back to correctly (a random living foe via #attack_target).
    def command_restricted?(b)
      return true if battler_restriction(b) != 0
      do_nothing_restricted?(b)
    end

    private

    # Whether `b` currently carries a "do nothing" restriction (asleep /
    # paralysed) -- a reference implementation's own can-act check, which
    # scans exactly this
    # one restriction value and nothing else (not death, not a forced-target
    # restriction). Shared by #command_restricted? (half of its own check)
    # and #to_hit (a restricted target always gets hit).
    def do_nothing_restricted?(b)
      (b.states || []).any? { |id| state_field(state_def(id), :restriction) == RESTRICTION_DO_NOTHING }
    end
    # Called from Game::Interpreter#battle_actor_condition (the battle-page
    # Conditional Branch's "can use battle command" actor test, a reference
    # implementation's own can-act check) -- exposed the same way
    # #choose_auto_battle_command
    # is, well outside this otherwise-private section.
    public :do_nothing_restricted?

    # The state definition for `id` from the lookup, or nil (no lookup / unknown).
    def state_def(id); @states ? @states[id] : nil; end

    # `ids` filtered down to the ones that outlive battle -- see
    # STATE_PERSISTS_ON_MAP and #apply_to_party's own comment.
    def surviving_states(ids)
      (ids || []).select { |id| state_field(state_def(id), :type) == STATE_PERSISTS_ON_MAP }
    end

    # Which side a combatant is on. Only a party member carries the live
    # Game::Actor it was snapshotted from, so that is the test. Recorded on a log
    # entry because a state's message is worded differently for an actor and an
    # enemy, and the entry only carries the target's *name*.
    def ally?(battler)
      battler.respond_to?(:actor) && !battler.actor.nil?
    end

    # A field off a state row, tolerating a fixture that omits it.
    def state_field(d, name); d.respond_to?(name) ? (d.send(name) || 0) : 0; end

    # Apply `b`'s afflicted states at the start of its turn: first roll each state
    # for auto-recovery (once it has held longer than its `hold_turn`, an
    # `auto_release_prob`% roll cures it), then, for the states that remain, slip
    # HP/SP damage (fixed val + a percentage of the max, per a reference
    # implementation's own condition-apply logic) and report whether the
    # battler may act (a "do nothing"
    # restriction skips its turn). Returns true if `b` may act.
    #
    # The HP half **cannot knock `b` out**: a reference implementation's own
    # condition-apply logic
    # calls its HP-change routine non-lethally, floored at 1 regardless of
    # how large the computed slip is, the same non-lethal rule the map-side
    # field-poison drain already follows (Party#apply_map_step_damage) -- only a
    # direct attack or skill can actually end a battler's turn in death. A state
    # flagged `hp_change_type`/`sp_change_type` **gain** (Game::States::
    # CHANGE_TYPE_GAIN, a "regen"-style state) heals instead of draining, and
    # **nothing** (CHANGE_TYPE_NOTHING) does neither despite a possibly-nonzero
    # configured amount; the schema default (0, every pre-2003 database's only
    # meaning for this RPG2003 field) is **lose**, matching this method's prior,
    # unconditional-loss behaviour exactly.
    def apply_turn_states(b)
      can_act = true
      b.state_turns ||= {}
      healed = []
      (b.states || []).dup.each do |id|
        d = state_def(id)
        next unless d
        b.state_turns[id] = (b.state_turns[id] || 0) + 1
        if recovers_from_state?(b, id, d)
          b.states = b.states - [id]
          b.state_turns.delete(id)
          healed << id
          next
        end
        # Not clamped to #damage_cap: ported from a reference implementation's
        # own source, NOT independently
        # confirmed against genuine RPG_RT under wine --
        # its non-lethal HP-change call carries the
        # computed slip straight through with no popup-cap clamp at all. The
        # popup hard-cap exists at exactly three call
        # sites in that reference implementation, all in its battle-algorithm
        # code's
        # Normal/Skill/SelfDestruct algorithms (see #do_simulated_attack's
        # own citation of this) -- this condition-apply routine is not one of
        # them. A
        # prior version of this method capped the HP slip here anyway, on an
        # uncited assumption that the popup limit "applies to slip damage
        # too"; it does not, and the SP slip two lines down was never capped
        # to begin with, which should have been a hint.
        hp = state_field(d, :hp_change_val) + b.max_hp * state_field(d, :hp_change_max) / 100
        b.hp = slip_stat(b.hp, b.max_hp, hp, state_field(d, :hp_change_type), 1) if hp > 0
        if b.max_mp && b.mp
          sp = state_field(d, :sp_change_val) + b.max_mp * state_field(d, :sp_change_max) / 100
          b.mp = slip_stat(b.mp, b.max_mp, sp, state_field(d, :sp_change_type), 0) if sp > 0
        end
        can_act = false if state_field(d, :restriction) == RESTRICTION_DO_NOTHING
      end
      b.turn_state_message = turn_state_message(b, healed)
      can_act
    end

    # `b`'s per-turn state reminder line, freshly computed for this call --
    # ported from a reference implementation's own turn-begin inline
    # scan, NOT independently confirmed against genuine RPG_RT under wine,
    # and not `States.significant`/that reference implementation's
    # own separate significant-state selection (which special-cases
    # Knockout and never considers a just-healed state) -- these
    # are two genuinely different functions in that reference implementation's
    # own source, not two
    # names for the same algorithm. Walks every id either just healed this
    # turn or still held afterward in ascending order, keeping whichever has
    # the highest `priority` (`>=`, so a tie goes to the later, higher id).
    # A healed state's line always shows, even blank; a still-held one only
    # shows if its own `message_affected` is non-blank -- matching RPG_RT's
    # own asymmetric rule exactly, not guessed at.
    def turn_state_message(b, healed)
      best_id = nil
      best_healed = false
      best_priority = -1
      (healed | (b.states || [])).sort.each do |id|
        d = state_def(id)
        next unless d
        priority = state_field(d, :priority)
        next if priority < best_priority
        best_id = id
        best_healed = healed.include?(id)
        best_priority = priority
      end
      return nil unless best_id
      if best_healed
        States.recovery_message(best_id, @states, b.name) || ''
      else
        States.affected_message(best_id, @states, b.name)
      end
    end

    # One state's per-turn slip applied to a single stat (`cur` against `max`):
    # `type` selects direction (see Game::States::CHANGE_TYPE_LOSE/GAIN/NOTHING
    # above the apply_turn_states doc), `floor` is the lowest the stat may land
    # at on a loss -- 1 for HP (state slip damage alone can never knock a
    # battler out) and 0 for SP (running out of SP is never fatal, so it keeps
    # its prior unfloored clamp).
    def slip_stat(cur, max, amount, type, floor)
      case type
      when States::CHANGE_TYPE_GAIN then [cur + amount, max].min
      when States::CHANGE_TYPE_NOTHING then cur
      else [cur - amount, floor].max
      end
    end

    # Whether `b` shakes off state `id` this turn: only once it has held for more
    # than the state's `hold_turn`, then an `auto_release_prob`% roll (0 = never
    # auto-releases). Ported from a reference implementation's own
    # battle-state-heal logic,
    # NOT independently confirmed against genuine RPG_RT under wine: it
    # checks the held-turn count against `hold_turn`, then always rolls the
    # auto-release chance -- its short-circuit only applies to
    # the `hold_turn` test, and the chance roll itself
    # always draws, whatever the probability is. A prior
    # version of this method checked `prob <= 0` *before* the `hold_turn` test
    # and returned early, skipping the RNG draw outright once a state's counter
    # passed `hold_turn` -- for any state configured with `auto_release_prob ==
    # 0` (a common "must be cured" ailment), that silently dropped one draw per
    # turn from the shared stream for the rest of the fight, permanently
    # desyncing this build's RNG sequence from a real seeded RPG_RT run.
    # `@rng.random(100) < 0` is always false, so the observable outcome at 0%
    # is unchanged -- only the draw itself is now consumed, same as RPG_RT.
    def recovers_from_state?(b, id, d)
      return false unless b.state_turns[id] > state_field(d, :hold_turn)
      @rng.random(100) < state_field(d, :auto_release_prob)
    end

    # Whether `b` counts as out of the fight *for the ally side's own
    # win/loss test only* (#alive?/#finished?'s `@allies` half): dead or
    # hidden (#out_of_play?), or locked into a "do nothing" restriction by a
    # state with zero chance of ever shaking itself off. Ported from
    # a reference implementation's own can-act-or-recoverable and
    # party-wipe checks, NOT independently confirmed against genuine RPG_RT
    # under wine: "party
    # wipe" for game-over purposes means every member is both unable to act
    # *and* does not recover naturally, not literally "every member's HP is
    # 0" -- why a fully-Stoned party loses instantly even though nobody was
    # ever damaged. A do-nothing state that *can* still clear itself
    # (Sleep, Paralysis with a nonzero auto_release_prob) does not count: the
    # fight keeps running, the same way #recovers_from_state? would
    # eventually stand that battler back up on its own. This widening exists
    # purely to avoid a stall where the player can never submit another
    # command -- a reference implementation's own win-check (the enemy side's
    # own test, see #enemy_active?) has no equivalent, and must not reuse this
    # method: the player can always keep attacking a
    # restricted-but-alive enemy, so a fully-Stoned enemy troop stays in the
    # fight until it is actually reduced to 0 HP or removed.
    def incapacitated?(b)
      return true if b.out_of_play?
      (b.states || []).any? do |id|
        d = state_def(id)
        d && state_field(d, :restriction) == RESTRICTION_DO_NOTHING &&
          state_field(d, :auto_release_prob) <= 0
      end
    end

    def alive?(side); side.any? { |b| !incapacitated?(b) }; end

    # Whether the enemy side still has anyone in the fight -- RPG_RT's own
    # win-check (see #finished?'s citation) only tests
    # dead-or-hidden (`Exists()`), never a restriction/recovery state, so a
    # live-but-permanently-restricted enemy troop (e.g. fully Stoned) does
    # not end the battle on its own; unlike #alive?, this does not fold in
    # #incapacitated?'s do-nothing-restriction check.
    def enemy_active?(side); side.any? { |b| !b.out_of_play? }; end

    def refill_queue
      @rounds += 1
      return if @rounds > MAX_ROUNDS
      # Mid-battle roster sync: who is queueable *this* round is decided right
      # here, once, before #turn_order runs -- see #sync_allies_from_party.
      # Ported from a reference implementation's own equivalent queue, NOT
      # independently confirmed against genuine RPG_RT under wine: the same
      # way its next-actor selection walks
      # the *current* party/enemy troop once per round,
      # ahead of `CreateExecutionOrder`'s sort -- a member not present in the
      # party at that moment is not in `battle_actions` and does not act this
      # round, even if they swap in moments later. (#step_action re-syncs
      # again before every single action for the other half of the rule --
      # see its own comment.)
      sync_allies_from_party if @party
      @queue = turn_order
      # A pre-emptive first strike catches the enemies off guard: they skip the
      # opening round, so only the party acts in round 1.
      @queue = @queue.reject { |b| side_of(b) == :enemy } if @first_strike && @rounds == 1
      # Lock in "cannot act" for the round right here, ported from a
      # reference implementation's own next-actor selection logic (a can-act
      # check queuing a do-nothing algorithm on the spot), NOT independently
      # confirmed against
      # genuine RPG_RT under wine -- see the Combatant `queued_no_act`
      # field's own comment. #apply_turn_states still runs live at dequeue
      # for slip damage/auto-recovery and to catch a battler newly afflicted
      # *after* this point but before its own turn (mirrors
      # a reference implementation's own live state-add override); this flag only ever adds
      # to that, it never lets a battler restricted here act again once its
      # state clears before its turn comes up.
      @queue.each { |b| b.queued_no_act = do_nothing_restricted?(b) }
      # Lock this round's plain basic-Attack target for every enemy right
      # here too, alongside `queued_no_act` above -- see `queued_target`'s
      # own field comment and #attack_target. A forced attack-ally/
      # attack-enemy restriction (berserk/confusion) still rolls its own
      # target live via #restricted_target, unaffected by this: this trivia
      # item and its fix are about an *unforced* basic Attack only.
      @queue.each do |b|
        b.queued_target = random_living(@allies) if side_of(b) == :enemy
      end
    end

    # Re-derive @allies from the live Game::Party (`party:` on #initialize) --
    # see #refill_queue and #step_action, the two call sites, and the
    # Combatant `member` field's own comment for what this flag means.
    #
    # A live party member with no Combatant here yet (never present in this
    # fight before) gets a fresh one via .from_actor and joins @allies --
    # a reference implementation has no separate battle roster to preserve
    # at all (its own live read of battlers goes straight off the
    # persistent actor data), so a genuinely new participant starting with
    # no accumulated battle-only modifiers (atk_mod/attr_ranks/states/...)
    # matches that live-read semantics exactly. A live member who already has
    # a Combatant (they left *this* fight earlier and are rejoining) reuses
    # that exact object instead -- rebuilding it would silently reset
    # whatever battle-only state it had accumulated, which is precisely what
    # this class's own ephemeral-snapshot design (see the Combatant class
    # comment) exists to avoid ever happening to a member who never left.
    #
    # A Combatant whose actor is no longer live is kept in @allies (so a later
    # rejoin still finds it, and #apply_to_party still writes its final state
    # back to the actor at battle end) but flagged not-a-member, which
    # #out_of_play? now folds in alongside dead?/hidden -- every existing
    # #turn_order/#side_targets/#alive?/etc. site that already filters
    # out_of_play? stops queueing or targeting it for free, with no call site
    # of its own to update.
    def sync_allies_from_party
      live_ids = {}
      @party.actors.each { |a| live_ids[a.id] = true }
      @allies.each { |c| c.member = false if c.actor && !live_ids[c.actor.id] }
      @party.actors.each do |a|
        existing = @allies.find { |c| c.actor && c.actor.id == a.id }
        if existing
          existing.member = true
          # A mid-battle Change Equipment event command (#equip_item_from_bag)
          # writes straight to the persistent Actor, but this Combatant's own
          # atk/def/spi/agi are otherwise a one-shot snapshot taken once at
          # #from_actor, battle start -- refreshed here from the live actor
          # every time this already-recurring resync runs (every round via
          # #refill_queue, every action via #step_action) so gear changed
          # mid-fight actually changes this fight's own damage/hit-rate math
          # from that point on, not just the next one. Community デフォ戦bot
          # trivia's own "-200 up!" display glitch is one narrower symptom of
          # this same stale-snapshot gap; every stat-mod clamp computed
          # against atk/def/spi/agi for the rest of the fight was stale too,
          # not just the number shown once. HP/MP are deliberately left
          # alone: they are this Combatant's own live battle state (current
          # HP, current MP), not a re-derivable stat, and overwriting them
          # here would erase mid-fight damage the moment this resync next runs.
          existing.atk = a.atk
          existing.def = a.def
          existing.spi = a.int
          existing.agi = a.agi
        else
          @allies.push(self.class.from_actor(a))
        end
      end
    end

    # Battlers ordered by a per-round randomised Agility roll (highest first)
    # -- except a battler whose round is about to be a basic Attack with a
    # `preemptive` weapon equipped sorts before everyone else (ported from
    # a reference implementation's own
    # execution-order construction, adding 9999 to such
    # a battler's computed order, which in practice always outruns ordinary
    # agility). NOT independently confirmed against genuine RPG_RT under
    # wine, but per that same function it does not
    # sort by raw Agility at all -- each battler rolls `agi +
    # Rand(0, agi/4 + 3)` fresh at the start of the round (computed once per
    # battler *before* sorting, exactly like here, with that reference
    # implementation's own comment
    # claiming this is "because of the strict
    # weak ordering property", not re-rolled per
    # comparison), so two battlers with equal Agility do not act in a fixed
    # order round after round -- either may go first, independently each
    # round. The previous version sorted purely by `effective_agi` with no
    # randomisation at all, making an agility tie between an ally and an
    # enemy resolve the same way in literally every round of literally every
    # battle, a divergence from this ported roll on any encounter with
    # matched Agility (a common case for a balanced fight).
    #
    # That reference implementation's own comparator has no documented rule
    # for what happens when
    # the *rolled* orders still tie (a `std::sort` over unspecified relative
    # order); this port keeps its own deterministic fallback for that now-rare
    # case -- an ally before an enemy, then the lower actor id, then troop
    # (definition) order -- purely so the same input reproduces the same
    # output for testing, not because it's meant to mirror any specific
    # undocumented C++ sort behaviour.
    def turn_order
      # [battler, rolled_order] pairs, not a Hash keyed by battler --
      # Combatant is a Struct, whose #hash/#eql? compare field *values*, so
      # two battlers that happen to share identical stats (a common case for
      # same-type enemies) would collide as one Hash key instead of two.
      rolled = (@allies + @enemies).reject(&:out_of_play?).map do |b|
        agi = effective_agi(b)
        roll = agi + @rng.random(agi / 4 + 4)
        roll += 9999 if preemptive_boost?(b)
        [b, roll]
      end
      rolled.each_with_index
            .sort_by { |(b, roll), i| [-roll, b.actor ? 0 : 1, b.actor ? b.actor.id : i] }
            .map { |(b, _roll), _i| b }
    end

    # Whether `b`'s action this round earns the `preemptive` weapon's
    # turn-order jump: only a basic Attack qualifies (a Skill, Item or Defend
    # with the same weapon equipped keeps its ordinary agility slot, matching
    # `CreateExecutionOrder`'s own `Type::Normal` guard).
    #
    # A forced attack-enemy restriction (berserk) does NOT earn the boost --
    # confirmed against genuine RPG_RT under wine (2026-09-05): a solo actor
    # with agi forced to 1, a preemptive weapon equipped, and a custom
    # berserk state (`RESTRICTION_ATTACK_ENEMY`, granted straight through
    # `#add_state` so no accuracy roll gates it) went *second* against a
    # single enemy with agi 30 (the enemy schema's own field 9 -- a
    # mislabeled fixture in this cycle's own capture wrote 250 to field 8,
    # spirit, not agility, so the real gap tested was only 1 vs 30) -- the
    # enemy's own attack message was already complete before the leader's
    # forced attack ever started, the reverse of what an unconditional +9999
    # turn-order bonus predicts against *any* ordinary agi gap this small.
    # This directly reverses this method's own
    # prior conclusion (see git history for the superseded comment and its
    # citation): a reference implementation's source was read as building an
    # identical basic-attack algorithm for both attack-ally (confusion) and
    # attack-enemy (berserk) restrictions with no restriction dependency in
    # the execution-order bonus at all, which was taken to debunk an uncited
    # fan-wiki claim that berserk specifically drops the bonus -- that
    # fan-wiki claim was right, at least for berserk.
    #
    # A forced attack-ally restriction (confusion) still counts, per that
    # same fan-wiki claim -- NOT independently confirmed against genuine
    # RPG_RT under wine either way, since this cycle's capture only put the
    # leader in the attack-*enemy* restriction. `preemptive` is actor-only
    # (see Combatant), so an enemy never qualifies either way.
    def preemptive_boost?(b)
      return false unless b.preemptive
      r = battler_restriction(b)
      return false if r == RESTRICTION_ATTACK_ENEMY
      return true if r == RESTRICTION_ATTACK_ALLY
      b.command.nil? && !b.defending && !b.skip
    end

    # `b` attacks its target, returning a log entry (or nil when it defends or
    # has no living target). A defending target takes half damage (min 1). An
    # ally with a queued Skill / Item command resolves that instead.
    def strike(b)
      # A battler that forfeited its turn (a failed escape) does nothing.
      return nil if b.skip
      # A "forced action" restriction (berserk / confused) overrides the chosen
      # command / defend with a basic attack on a forced target -- still an
      # ordinary basic Attack under the hood otherwise, so dual-wield's extra
      # swing and 必中's evasion-skip both still apply (デフォ戦botまとめ:
      # forced restrictions "override target selection but still honour
      # 'hits twice'/'ignores evasion'"), via the same #swing an unforced
      # Attack uses rather than a bare #deal_attack.
      r = battler_restriction(b)
      if r == RESTRICTION_ATTACK_ENEMY || r == RESTRICTION_ATTACK_ALLY
        target = restricted_target(b, r)
        return nil unless target
        # Both forced restrictions force a single target with an attack_all
        # weapon in hand, same as an unforced Attack now that #strike's own
        # unforced branch is confirmed single-target too -- confirmed against
        # genuine RPG_RT.exe under wine (Nepheshel). Berserk (attack-enemy): a
        # Berserk leader
        # wielding ジュエルロッド (item 82, attack_all) against two Slimes
        # logged exactly one "リトの攻撃!"/"スライムに11のダメージを与えた!"
        # pair, never a second target's own hit/evade line, across a
        # 0.15s-resolution capture of the whole action (nothing to miss a
        # second message in). Confusion (attack-ally): the same weapon,
        # confused instead of berserk, against a two- and a three-member
        # party, logged exactly one target line every time regardless of
        # whether the forced target was another ally or the attacker itself
        # -- never a second line for a second party member in the same
        # swing. A prior cycle had "corrected" this to spread for both
        # restrictions per a reference implementation's own source reading
        # -- that reading is now known wrong for both halves: the weapon's
        # own attack_all flag is ignored once #restricted_target has forced
        # a single target, the same #swing an unforced single-target Attack
        # uses.
        pay_weapon_sp_cost(b)
        hits = combo_hits(b, :attack)
        return swing(b, target, hits)
      end
      # A combo multiplies a skill's hits (SP paid once), never an item's --
      # #combo_hits resolves the chosen command's type, and an Item command
      # reads 1.
      return apply_command(b, combo_hits(b, :skill)) if b.command
      return nil if side_of(b) == :ally && b.defending # defending = no attack
      # An enemy with a 行動パターン chooses from it rather than always swinging,
      # even while charged -- charge only forces the *swing count* of an
      # Attack-type pick (plain Attack or Dual Attack) down to a single
      # blow, it does not bypass the pattern draw itself. Confirmed against
      # genuine RPG_RT under wine (2026-09-05), two separate findings:
      #
      # A charged enemy still runs a non-Attack pattern pick normally -- a
      # synthetic enemy whose only turn-2+ action was Defend (no Attack
      # action in its pattern at all past the charging turn) showed
      # "Duelistは身を守っている!" (Duelist is defending!) on its charged
      # turn, not a forced attack. This directly contradicts this method's
      # own prior citation ("a charged enemy can never end up Defending,
      # casting a Skill, self-destructing, or gathering another Charge; it
      # is guaranteed exactly one doubled swing"), which was only ever a
      # reading of a reference implementation's source, never itself
      # checked against genuine RPG_RT. Skill, self-destruct, escape and a
      # fresh Charge are not independently re-confirmed by this same
      # capture, but share no special-casing with Defend in either this
      # method or that debunked citation, so they are assumed to behave
      # the same (run normally) rather than guessed at differently.
      #
      # A charged enemy's own Dual Attack pattern pick DOES still collapse
      # to a single swing, though: a separate fixture whose only turn-2+
      # action was BASIC_DUAL_ATTACK (charged turn 2, uncharged from turn 3
      # on) logged exactly one landed hit's worth of damage on the charged
      # turn against two landed hits on the later uncharged turns, across
      # two independent trials -- consistent with genuine RPG_RT capping an
      # Attack-type pattern pick's own swing count at one while charged,
      # not with both swings landing doubled the way a naive "charge just
      # sets a flag `enemy_basic_action` reads twice" port would predict.
      # See `EnemyAction::BASIC_DUAL_ATTACK`'s own citation in
      # #enemy_basic_action.
      if side_of(b) == :enemy
        # A guard raised last turn expires as this one begins (the allies' is
        # cleared by #end_round; an enemy acts on its own schedule).
        b.defending = false
        act = choose_enemy_action(b)
        attack_type_pick = act && act.basic? &&
                           [EnemyAction::BASIC_ATTACK, EnemyAction::BASIC_DUAL_ATTACK]
                             .include?(act.basic)
        act = nil if b.charged && attack_type_pick
        return perform_enemy_action(b, act) if act
      end
      target = attack_target(b)
      return nil unless target
      pay_weapon_sp_cost(b)
      hits = combo_hits(b, :attack)
      # attack_all does NOT spread an unforced Attack across the whole side
      # either -- confirmed by an actual wine capture (2026-09-05, see
      # Actor#attack_all?'s own citation): the same probe weapon (item 82,
      # ジュエルロッド) against a two-enemy troop, manually aimed at whichever
      # troop slot the fixture put first, logged exactly one target's own
      # damage line every round across two independently-built fixtures (one
      # with the troop's member order swapped), never a second line for the
      # other enemy -- and swapping which enemy occupied the first slot
      # moved which one got hit, ruling out a fixed name/identity coincidence.
      swing(b, target, hits)
    end

    # Spend `b`'s own weapon SP cost for the basic Attack it is about to make
    # -- a reference implementation's own basic-attack start-up logic (see
    # `Actor#weapon_sp_cost`'s own doc
    # comment), called exactly once per action from both of `#strike`'s
    # attack-dispatch points, before the swing count (dual-wield, combo) is
    # even resolved. A no-op for an enemy attacker (`b.actor` is nil --
    # that reference implementation's own weapon-sp-cost calculation
    # defaults to 0 for an enemy) or a bare fixture Combatant with no
    # `#actor` link
    # at all.
    def pay_weapon_sp_cost(b)
      actor = b.respond_to?(:actor) ? b.actor : nil
      actor.change_mp(-actor.weapon_sp_cost) if actor && actor.respond_to?(:weapon_sp_cost)
    end

    # -- RPG2003 battle combo (Enable Combo / 1007) -----------------------------
    #
    # A combo armed by Enable Combo (event 1007) multiplies the hits of the
    # battle command it names. Port of a reference implementation's own
    # combo-processing logic
    # (NOT independently confirmed against genuine RPG_RT under wine): the
    # armed `{ command_id:, multiple: }`
    # (Game::Actor#battle_combo) applies only when `command_id` is the command
    # the actor actually chose this turn (Combatant#last_battle_action,
    # recorded by the scene at command selection), and only to attack / skill /
    # subskill commands, with that reference implementation's own comment
    # claiming "RPG_RT doesn't
    # allow combo for item or other
    # actions other than attack and skills". Like that reference
    # implementation, the
    # combo is not decremented by a use: it stays armed (until battle end or
    # another Enable Combo overwrites it), so every matching use of the command
    # during the fight hits `multiple` times.
    #
    # The fixed-four command ids (1 attack, 2 skill, 3 defense, 4 item) are
    # a reference implementation's own default battle commands; a customized
    # actor's ids are refs
    # into `db.battlecommands.commands`, whose rows this resolves through the
    # actor the same way the scene's command menu does.
    DEFAULT_BATTLE_COMMAND_TYPES = {
      1 => Game::Actor::BATTLE_COMMAND_ATTACK,
      2 => Game::Actor::BATTLE_COMMAND_SKILL,
      3 => Game::Actor::BATTLE_COMMAND_DEFENSE,
      4 => Game::Actor::BATTLE_COMMAND_ITEM
    }.freeze

    # The RPG2003 battle-command type for `cmd_id` on battler `b`: the actor's
    # own customized list's row when it has one, else the fixed-four default
    # table (a 2000 actor, or one whose list does not reach this id).
    def battle_command_type(b, cmd_id)
      actor = b.respond_to?(:actor) ? b.actor : nil
      row = actor && actor.respond_to?(:battle_command_row) ? actor.battle_command_row(cmd_id) : nil
      return row.type if row && row.respond_to?(:type)
      DEFAULT_BATTLE_COMMAND_TYPES[cmd_id]
    end

    # The combo hit multiplier for `b`'s current `kind` (:attack or :skill)
    # of action, or 1 when no matching combo is armed -- see the section
    # comment above for the exact matching rules. Enemies and auto-battling
    # allies never record a `last_battle_action`, so they never combo.
    def combo_hits(b, kind)
      actor = b.respond_to?(:actor) ? b.actor : nil
      return 1 unless actor && actor.respond_to?(:battle_combo)
      combo = actor.battle_combo
      multiple = combo && combo[:multiple]
      return 1 unless multiple && multiple > 1
      return 1 unless combo[:command_id] && combo[:command_id] == b.last_battle_action
      case kind
      when :attack
        battle_command_type(b, combo[:command_id]) == Game::Actor::BATTLE_COMMAND_ATTACK ? multiple : 1
      when :skill
        type = battle_command_type(b, combo[:command_id])
        type == Game::Actor::BATTLE_COMMAND_SKILL || type == Game::Actor::BATTLE_COMMAND_SUBSKILL ? multiple : 1
      else
        1
      end
    end

    # -- enemy AI (行動パターン) ------------------------------------------------

    # Pick the action `b` takes this turn from its pattern, or nil to fall back
    # to a plain attack (no pattern, or nothing currently valid).
    #
    # Port of a reference implementation's own rating-based algorithm: collect
    # the ratings of the
    # actions whose condition holds, find the highest, then drop every action
    # more than 10 below it (`rating - max + 10`, floored at 0) and pick from
    # what remains at random, weighted by the adjusted rating. So a boss's
    # rating-50 attack and rating-48 spell both stay in the mix, while a
    # rating-40 desperation move is excluded until the moves above it stop being
    # valid — which is how an RPG2000 enemy's behaviour shifts as a fight goes on.
    def choose_enemy_action(b)
      list = b.actions
      return nil if list.nil? || list.empty?
      prios = []
      max_prio = 0
      list.each do |a|
        r = enemy_action_valid?(b, a) ? a.rating : 0
        r = 0 if r < 0
        prios << r
        max_prio = r if r > max_prio
      end
      return nil if max_prio <= 0
      prios = prios.map do |pr|
        v = pr > 0 ? pr - max_prio + 10 : 0
        v = 0 if v < 0
        v
      end
      # A skill action's weight above is computed purely from its rating and
      # #enemy_action_valid?; a high-rating but currently-ineffective skill
      # (a self-heal at full HP, a cure with nothing to cure) still crowds out
      # the *other* candidates via max_prio exactly as if it were still in the
      # running -- a reference implementation's own two-pass structure
      # (ported from its
      # source, NOT independently confirmed against genuine RPG_RT under
      # wine) does not
      # recompute the weights above either. Only the ineffective skill's own
      # draw is zeroed out, in this separate pass, once weights are settled.
      list.each_with_index do |a, i|
        next unless prios[i] > 0 && a.skill?
        sk = @ai && @ai.skill(a.skill_id)
        prios[i] = 0 if sk && !@ai.skill_helps_troop?(sk, b, @enemies)
      end
      total = prios.reduce(0) { |sum, v| sum + v }
      return nil if total <= 0
      which = @rng.random(total)
      chosen = nil
      list.each_with_index do |a, i|
        chosen = a
        which -= prios[i]
        break if which < 0
      end
      chosen
    end

    # Whether action `a`'s condition currently holds for enemy `b`. The condition
    # types and their arithmetic are a reference implementation's own
    # action-validity check; the ranges
    # are inclusive on both ends.
    def enemy_action_valid?(b, a)
      return false if a.skill? && !enemy_skill_ready?(b, a)
      case a.condition_type
      when EnemyAction::COND_ALWAYS
        true
      when EnemyAction::COND_SWITCH
        @ai ? @ai.switch?(a.switch_id) : false
      when EnemyAction::COND_TURN
        # Same argument order as the battle pages' turn condition: the base is
        # condition_param2 and the multiple condition_param1 (see
        # BattlePage.check_turns, which documents why it reads backwards).
        BattlePage.check_turns(turn, a.condition_param2, a.condition_param1)
      when EnemyAction::COND_ACTORS
        # "Enemies" in the editor's own condition list -- how many of this
        # monster's own troop-mates are still standing, not the player
        # party's headcount. Ported from a reference implementation's own
        # action-validity check, NOT
        # independently confirmed against genuine RPG_RT under wine: it reads
        # the enemy troop's own active-battler count here,
        # never the player party.
        n = @enemies.reject(&:out_of_play?).size
        n >= a.condition_param1 && n <= a.condition_param2
      when EnemyAction::COND_HP
        within_percent?(b.hp, b.max_hp, a)
      when EnemyAction::COND_SP
        within_percent?(b.mp, b.max_mp, a)
      when EnemyAction::COND_PARTY_LVL
        return false unless @ai
        lvl = @ai.party_level
        lvl >= a.condition_param1 && lvl <= a.condition_param2
      when EnemyAction::COND_FATIGUE
        f = fatigue
        f >= a.condition_param1 && f <= a.condition_param2
      else
        # An out-of-range condition_type (past COND_FATIGUE, the highest of
        # the eight recognised types) reads as unconditionally eligible, not
        # excluded -- ported from a reference implementation's own source,
        # NOT independently
        # confirmed against genuine RPG_RT under wine: its own condition-type
        # switch
        # ends with an unconditional true, applying
        # identically on RPG2000 and RPG2003 (no version gate anywhere in
        # the function). This is the mirror image of the "unset/unknown
        # stays conservative" shape this method's own COND_ACTORS/skill-type
        # fixes correctly use elsewhere -- this one specific fallthrough
        # goes the other way in this ported behavior.
        true
      end
    end

    # Whether `cur` as a percentage of `max` falls inside the action's range.
    def within_percent?(cur, max, a)
      return false if max.nil? || max <= 0
      pct = (cur || 0) * 100 / max
      pct >= a.condition_param1 && pct <= a.condition_param2
    end

    # Whether `b` can actually cast the skill action `a`: the skill exists, is
    # a legal in-battle action at all (not Escape/Teleport, and not a Switch
    # skill whose battle-occasion flag is off -- see #skill_battle_usable?),
    # and it can pay the SP. An enemy that cannot afford its spell -- or whose
    # pattern names an illegal action entirely -- falls through to its other
    # actions, the way RPG_RT never lets either kind enter the weighted draw.
    def enemy_skill_ready?(b, a)
      return false unless @ai
      sk = @ai.skill(a.skill_id)
      return false unless sk
      return false unless @ai.skill_battle_usable?(sk)
      return false if skill_sealed?(b, sk) # silenced: this entry cannot fire
      cmd = @ai.skill_command(sk, b, nil)
      return false unless cmd
      cost = cmd[:cost] || 0
      cost <= 0 || (b.mp || 0) >= cost
    end

    # Run the action `b` chose and return its log entry (or entries). Any switch
    # the action flips is applied once it has run.
    #
    # `b.charged` is snapshotted and cleared right here, before dispatching to
    # any action kind -- ported from a reference implementation's own
    # algorithm-start logic, NOT independently confirmed against genuine
    # RPG_RT under wine: it clears the charged flag unconditionally,
    # for every algorithm (Skill, SelfDestruct, Defend, Transform, Normal,
    # all of them) -- not
    # only in the Normal (plain-attack) algorithm this codebase previously
    # cleared it from inside. A charge is spent (or simply wasted) by
    # whatever this enemy does next, attack or not; it never survives to a
    # later turn. The snapshot rides along as the `charged:` a plain-attack
    # branch below hands to #deal_attack explicitly, since by the time any of
    # them would run, `b.charged` here has already been cleared.
    def perform_enemy_action(b, act)
      charged = b.charged ? true : false
      b.charged = false
      entry = if act.skill?
                enemy_skill_action(b, act, charged)
              elsif act.transform?
                enemy_transform_action(b, act, charged)
              else
                enemy_basic_action(b, act, charged)
              end
      apply_action_switches(act)
      entry
    end

    # An action may switch a game switch on and/or off once it has run — how an
    # enemy's move signals a troop's battle-event pages.
    def apply_action_switches(act)
      return unless @ai
      @ai.set_switch(act.switch_on_id, true) if act.switch_on
      @ai.set_switch(act.switch_off_id, false) if act.switch_off
    end

    # The basic actions (kind 0). Attack and dual attack go through the ordinary
    # attack path (so accuracy, criticals, elements and variance all apply);
    # the rest have no damage of their own and read as a plain note on the log.
    # `charged` is #perform_enemy_action's already-snapshotted-and-cleared
    # `b.charged` -- handed to #deal_attack explicitly rather than read off
    # `b` again here, since it is already gone by this point either way.
    def enemy_basic_action(b, act, charged)
      case act.basic
      when EnemyAction::BASIC_DUAL_ATTACK
        target = attack_target(b)
        return nil unless target
        # 二段攻撃 (BASIC_DUAL_ATTACK) really does swing twice at the same
        # target, each its own separately-rolled damage line -- confirmed by
        # an actual wine capture (2026-09-05): a synthetic enemy whose only
        # action was BASIC_DUAL_ATTACK logged two distinct "Duelistの攻撃!"
        # message screens in a single round (52 then 41 damage, each its own
        # confirm-gated box, not one combined line), never a single hit.
        # Ported from a reference implementation's own dual attack. `charged`
        # is always false/nil here now: #strike collapses a charged enemy's
        # own Dual Attack pattern pick to a single swing through the
        # plain-Attack fallback before this method is ever reached with it
        # (confirmed against genuine RPG_RT under wine, 2026-09-05 -- see
        # #strike's own citation), so the "does charge double both swings or
        # only the first" question this comment used to raise for this
        # branch cannot come up: this branch itself is never called while
        # charged at all.
        first = deal_attack(b, target, 0, charged: charged)
        # The second swing only lands if the first did not fell the target.
        return [first] if target.dead?
        second = deal_attack(b, target, 1, charged: charged)
        # The enemy-attack SE plays once per action (at its very start), not
        # once per swing -- ported from a reference implementation's own
        # action-usage processing,
        # NOT independently confirmed against genuine RPG_RT under wine: it
        # fetches the start SE only before the first execution, a repeat
        # re-enters
        # at execution directly. Clearing the second swing's `attacker_ally`
        # keeps #play_battle_action_se from re-triggering it.
        second[:attacker_ally] = nil
        [first, second]
      when EnemyAction::BASIC_DEFEND
        b.defending = true
        { attacker: b.name, defend: true }
      when EnemyAction::BASIC_OBSERVE
        { attacker: b.name, observe: true }
      when EnemyAction::BASIC_CHARGE
        # The next attack this enemy lands does double damage (ported from
        # a reference implementation's charge flag, spent in #deal_attack;
        # confirmed against genuine RPG_RT under wine, 2026-09-05 -- a
        # synthetic enemy whose turn-1 action was Charge only and turn-2+
        # action a plain Attack only landed turn 2's hit for double the
        # ordinary ~100-power probe's damage, 200 rather than ~80-120) --
        # any stale charge
        # already spent by #perform_enemy_action above starts fresh here
        # regardless.
        b.charged = true
        { attacker: b.name, charge: true }
      when EnemyAction::BASIC_AUTODESTRUCT
        enemy_autodestruct(b)
      when EnemyAction::BASIC_ESCAPE
        # The enemy runs: out of play without counting as a kill, exactly as a
        # battle page's Force Flee removes one.
        b.hidden = true
        { attacker: b.name, fled: true }
      when EnemyAction::BASIC_NOTHING
        { attacker: b.name, nothing: true }
      else
        target = attack_target(b)
        target ? deal_attack(b, target, 0, charged: charged) : nil
      end
    end

    # Self-destruction (basic 5): the enemy blows itself up, hitting every living
    # party member for `atk - def/2` (ported from a reference implementation's
    # self-destruct effect calculation, floored at 0 and spread by the usual
    # variance, NOT independently confirmed against genuine RPG_RT under wine).
    # Defending halves the blow -- confirmed against genuine RPG_RT under wine
    # (2026-09-05): a defending target took roughly half of an undefended
    # target's own damage from an otherwise identical self-destruct. 強力防御
    # (Strong Defence) does NOT halve it again here, though, contradicting a
    # prior revision of this comment/code that claimed it shared the ordinary
    # defend-adjustment's own double-halving verbatim: a Strong-Defence-
    # flagged, defending target's own damage across two separately-run,
    # otherwise-identical captures (97 and 98 -- not the ~48-49 a second
    # halving predicts) landed in the same range as an ordinary defending
    # target with the flag left off. Reverted; this finding does NOT extend
    # to the sibling `strong_defence` read in `#apply_skill_hit` (a skill's
    # own HP effect), which a separate wine capture confirms DOES quarter
    # correctly -- see that method's own citation. `#deal_attack`'s own read
    # (the ordinary-attack path) is likewise confirmed real -- see its own
    # citation. These are three separate call sites in genuine RPG_RT, not a
    # shared routine, and self-destruct is the one outlier of the three;
    # it simply does not consult the flag at all here. It
    # does not kill the caster itself, though: that reference implementation's
    # self-destruct handling applies the damage against the *target* only,
    # never the source, and reacts to the caster with nothing but a hidden
    # flag (plus an explode-animation timer) -- no HP
    # write at all. So the caster is hidden, exactly like a page's Force Flee
    # or its own basic Escape action, not killed -- this part is independently
    # confirmed by the community デフォ戦bot trivia that a self-destructed
    # enemy drops no EXP / gold / items, that its HP reads unchanged (not 0)
    # if a battle event variable-assigns it, and that "Enemy Appears" (Show
    # Hidden Monster) brings it right back with whatever HP it already had.
    #
    # A solo self-destructing enemy still ends the fight in Victory despite
    # never actually being reduced to 0 HP -- confirmed against genuine
    # RPG_RT under wine (2026-09-05): a synthetic enemy whose only action
    # was BASIC_AUTODESTRUCT (atk forced to 0, so its own blast dealt no
    # damage at all) showed its own self-destruct message, then the
    # "戦いに勝った!" (Won the battle!) Victory line and a clean return to
    # the map, with no player action ever needed. Consistent with
    # `Game::Battle#finished?`/`#enemy_active?` treating a hidden battler
    # the same as a dead one (see that method's own citation) -- this cycle
    # just confirms self-destruct's own hidden-not-killed handling actually
    # reaches that check in a real fight, not merely in isolation.
    def enemy_autodestruct(b)
      targets = @allies.reject(&:out_of_play?)
      entries = Array.new(targets.size) do |i|
        t = targets[i]
        dmg = effective_atk(b) - effective_def(t) / 2
        dmg = 0 if dmg < 0
        dmg = varied(dmg, NORMAL_ATTACK_VARIANCE) if @variance && dmg > 0
        # No floor on the halving -- a bare `dmg /= 2`, with no `std::max` at
        # all (see #deal_attack_with_current_weapon's own citation of
        # `AdjustDamageForDefend`, ported from its source and NOT
        # independently confirmed against genuine RPG_RT under wine for the
        # ordinary-attack path, though confirmed for this self-destruct path
        # specifically -- see this method's own citation above). No second
        # halving for Strong Defence here: reverted after a genuine wine
        # capture falsified it (this method's own citation above).
        dmg /= 2 if t.defending && dmg > 0
        cap = damage_cap
        dmg = cap if dmg > cap
        t.hp -= dmg
        apply_knockout_reset(t)
        # A survivor's physical-release states shake off here too -- ported
        # from a reference implementation's self-destruct handling, NOT
        # independently confirmed against genuine RPG_RT under wine: it calls the identical
        # `BattlePhysicalStateHeal(100, ...)` a basic attack does
        # (#deal_attack's own #shake_off_states call), not a
        # self-destruct-specific omission.
        woke = t.dead? ? [] : shake_off_states(t, 100)
        entry = { attacker: b.name, target: t.name, damage: dmg, critical: false,
                  autodestruct: true, target_hp: t.hp < 0 ? 0 : t.hp, defeated: t.dead?,
                  target_ally: ally?(t) }
        # Ported from a reference implementation's own self-destruct start-SE
        # handling, NOT independently confirmed against genuine RPG_RT under
        # wine: the explosion SE plays unconditionally, once per action, the
        # instant it starts -- not once per target hit, and not gated on
        # whether the blast actually kills anyone (that reference
        # implementation's own battle-action dispatch fetches the start SE a
        # single time, before any target's own damage is even resolved). This multi-target
        # action buffers one entry per
        # target through the same one-at-a-time drain a dual-wield swing
        # does, so only the first entry carries the trigger -- the identical
        # "SE plays once per action, not once per repeat" idiom
        # #enemy_basic_action's own dual-attack arm already uses (see its
        # own comment on clearing `attacker_ally` on the second swing).
        # `:autodestruct_se` is its own separate flag rather than reusing
        # `:autodestruct` itself, since that one still has to ride on every
        # entry for its own per-target "blows itself up on" log line.
        entry[:autodestruct_se] = true if i.zero?
        entry[:woke] = woke unless woke.empty?
        entry
      end
      # Hidden, not killed -- see the method comment above.
      b.hidden = true
      entries.empty? ? { attacker: b.name, autodestruct: true, autodestruct_se: true } : entries
    end

    # A skill action (kind 1): cast through the same command pipeline the party
    # uses, so an enemy's attack spell scales, rolls its accuracy and inflicts its
    # states exactly like a hero's — which is what finally lets an enemy poison or
    # sleep the party. A skill whose scope names the caster's own side heals /
    # buffs a fellow monster instead.
    def enemy_skill_action(b, act, charged)
      sk = @ai && @ai.skill(act.skill_id)
      return enemy_fallback_attack(b, charged) unless sk
      targets = enemy_skill_targets(b, sk)
      return enemy_fallback_attack(b, charged) if targets.empty?
      cmd = @ai.skill_command(sk, b, targets.first)
      return enemy_fallback_attack(b, charged) unless cmd
      b.command = skill_command_hash(sk, cmd, targets.first)
      b.command[:skill_id] = act.skill_id
      if targets.size > 1
        # An all-target skill carries one effect per target, since attack damage
        # is computed against each target's own defence.
        per = targets.map do |t|
          c = @ai.skill_command(sk, b, t)
          c ? { target: t, hp: c[:hp] || 0, mp: c[:mp] || 0 } : nil
        end.compact
        return enemy_fallback_attack(b, charged) if per.empty?
        b.command[:all] = true
        b.command[:targets] = per
        b.command[:target] = nil
      end
      entry = apply_command(b)
      b.command = nil
      entry
    end

    # Wrap the party's cast numbers in the command hash #apply_command consumes.
    #
    # Carries `attr_shift`/`attr_ids`/`stat_mod_keys`/`stat_effect`/
    # `physical_rate` through too -- #queue_auto_battle_group_skill already
    # threads all five from this same `@ai.skill_command` result into
    # #command_skill_all by hand; this single-target wrap (an enemy's own
    # skill action and a player ally's single-target auto-battle skill) had
    # silently dropped every one of them since #apply_command reads them by
    # key with an absent-key default (`cmd[:attr_shift]` nil, `cmd[:stat_
    # mod_keys]`/`cmd[:physical_rate]` empty/0), so an attribute-rank shift, a
    # stat buff/debuff and a physical skill's shake-off-states roll never
    # once fired through either path.
    def skill_command_hash(sk, cmd, target)
      { kind: :skill, target: target, name: skill_name_of(sk),
        absorb: cmd[:absorb] ? true : false, attack: cmd[:attack] ? true : false,
        cost: cmd[:cost] || 0, hp: cmd[:hp] || 0, mp: cmd[:mp] || 0,
        inflict: cmd[:inflict] || [], chance: cmd[:chance] || 100,
        variance: cmd[:variance] || 0, attributes: cmd[:attributes] || [],
        cured: cmd[:cured] || [],
        attr_shift: cmd[:attr_shift], attr_ids: cmd[:attr_ids] || [],
        stat_mod_keys: cmd[:stat_mod_keys] || [], stat_effect: cmd[:stat_effect] || 0,
        physical_rate: cmd[:physical_rate] || 0 }
    end

    def skill_name_of(sk)
      sk.respond_to?(:name) ? sk.name.to_s : ''
    end

    # Who an enemy's skill hits, read from the caster's side of the field: a
    # scope aimed at "enemies" (0 single / 1 all) means the party, and one aimed
    # at "allies" (2 the caster / 3 single / 4 all) means the troop.
    def enemy_skill_targets(b, sk)
      scope = sk.respond_to?(:scope) ? sk.scope.to_i : 0
      case scope
      when 1 then @allies.reject(&:out_of_play?)
      when 2 then [b]
      when 3
        own = @enemies.reject(&:out_of_play?)
        own.empty? ? [] : [own[@rng.random(own.size)]]
      when 4 then @enemies.reject(&:out_of_play?)
      else
        foes = @allies.reject(&:out_of_play?)
        foes.empty? ? [] : [foes[@rng.random(foes.size)]]
      end
    end

    # A transformation (kind 2): the monster becomes another database enemy,
    # taking on its name, stats and battle graphic (and its action pattern)
    # while keeping its place in the fight. Current HP / SP carry over
    # completely unchanged, *not* reclamped to the new maxima -- ported from
    # a reference implementation, NOT independently confirmed against genuine
    # RPG_RT under wine: it only ever repoints the
    # `enemy` database row and refreshes the sprite; it never touches `hp`/
    # `sp` at all (those are set to the max only once, in the constructor, on
    # the enemy's very first spawn). `Transform`'s own battle-algorithm
    # (a reference implementation's own transform-effect handler) never calls
    # `SetAffectedHp`/
    # `SetAffectedSp` either, so the generic post-effect `ApplyHpEffect`/
    # `ApplySpEffect` pass skip it outright (`GetAffectedHp() == 0` is a
    # no-op). A boss can therefore legitimately carry HP above a later,
    # lower-max "true form" until something else changes it -- a classic
    # "damage carries across a transformation" design this build's own
    # clamp made impossible by silently full-healing every downward
    # transform.
    def enemy_transform_action(b, act, charged)
      into = @ai && @ai.enemy(act.enemy_id)
      return enemy_fallback_attack(b, charged) unless into
      b.name = into.name
      b.atk = into.atk; b.def = into.def; b.agi = into.agi; b.spi = into.spi
      b.max_hp = into.max_hp; b.max_mp = into.max_sp
      b.crit_chance = Battle.crit_chance_of(into)
      b.attr_ranks = Battle.attr_ranks_of(into)
      # #apply_attr_shift caps a later attribute-defence shift to +-1 of
      # `attr_base_ranks`, snapshotted once at spawn (Combatant.from_actor/
      # from_enemy) since this port represents the shift as an absolute rank
      # rather than a reference implementation's own persistent delta
      # (added onto a *live* base attribute rate that reads straight off the
      # currently-transformed `enemy` row), ported from that source and NOT
      # independently confirmed against genuine RPG_RT under wine). A
      # transform changes what "the base" is, exactly the event a snapshot
      # needs to be told about; left stale, a later shift is capped against
      # the pre-transform monster's own resistance instead of this one's.
      b.attr_base_ranks = b.attr_ranks.dup
      b.state_ranks = Battle.state_ranks_of(into)
      b.hit_rate = Battle.hit_rate_of(into)
      b.actions = into.actions
      b.enemy_id = act.enemy_id
      b.battler_name = into.battler_name
      b.battler_hue = into.battler_hue
      { attacker: b.name, transform: true, target: into.name }
    end

    # A skill / transformation that could not be resolved (no database to hand)
    # degrades to a plain attack rather than costing the enemy its turn.
    # `charged` (already snapshotted by #perform_enemy_action) rides along
    # into the substituted attack, same as an ordinary chosen one.
    def enemy_fallback_attack(b, charged)
      target = attack_target(b)
      target ? deal_attack(b, target, 0, charged: charged) : nil
    end

    # -- forced AI (強制AI) ---------------------------------------------------
    #
    # Queues a command on an ally `b` flagged `Game::Actor#force_ai?`
    # automatically, the way a player's own menu choice would, instead of
    # ever opening the ordinary Attack/Skill/Defend/Item command window --
    # called from `Scene::Map`'s command-selection loop in place of drawing
    # that menu (see the fuller writeup and `docs/TODO.md`'s own entry). A
    # faithful port of a reference implementation's default RPG_RT-compatible
    # auto-battle algorithm, ported from that implementation, NOT
    # independently confirmed against genuine RPG_RT under wine:
    # it always allows any weapon and considers skills, with
    # attack variance off, skill variance on, and known bugs emulated --
    # what that implementation believes is the one real, un-patched RPG_RT
    # behavior; its other two named
    # algorithms, an attack-only mode and an "improved" mode, are its own optional,
    # non-default customizations and are not modelled here). The ranking
    # mirrors a reference implementation's own normal-attack /
    # skill auto-battle target-ranking functions with variance disabled --
    # the normal-attack ranking function computes
    # its own `base_effect` via
    # the *identical* function the real attack execution
    # calls in that implementation
    # -- so this ranking pass
    # and the damage a thrown attack actually deals share the same RPG2003
    # row modifiers (#row_adjusted?) and state-adjusted ATK/DEF
    # (#effective_atk/#effective_def) by construction, not merely as an
    # equivalent approximation. `#auto_battle_attack_target_rank` layers
    # both in for exactly that reason (see its own citation).
    def choose_auto_battle_command(b)
      best_skill = nil
      best_sid = nil
      best_skill_rank = 0.0
      skills = b.actor && b.actor.respond_to?(:skills) ? b.actor.skills : []
      skills.each do |sid|
        sk = @ai && @ai.skill(sid)
        next unless sk
        r = auto_battle_skill_rank(b, sk, sid)
        if r > best_skill_rank
          best_skill_rank = r
          best_skill = sk
          best_sid = sid
        end
      end
      attack_rank = auto_battle_attack_rank(b)
      if best_skill && attack_rank < best_skill_rank
        queue_auto_battle_skill(b, best_skill, best_sid)
      else
        queue_auto_battle_attack(b)
      end
    end
    # Called from Scene::Map's own command-selection loop (see #command_
    # restricted?, this method's sibling in that same caller), well outside
    # this otherwise-private section -- exposed the same way #camera_position
    # is over in Scene::Map itself.
    public :choose_auto_battle_command

    # Ported from a reference implementation, not independently confirmed
    # against genuine RPG_RT under wine: `sk` (known by `b`, database id
    # `sid`) is out of the running entirely (0.0) unless it is an ordinary
    # HP/SP/state skill (`Game::Party.normal_skill?` — a Teleport/Escape/
    # Switch skill is never auto-cast) that `b` can actually afford and is
    # not sealed from casting (`EnemyAi#skill_ready?`, a reference
    # implementation's own skill-usable gate). Otherwise its rank is the max (single-
    # target scope) or sum (all-target scope) of every possible target's own
    # rank, plus one final random jitter draw (a reference implementation's
    # own random-number call, applied once per *skill* here, not per target)
    # so two skills
    # that would otherwise tie do not always resolve the same way twice.
    def auto_battle_skill_rank(b, sk, sid)
      return 0.0 unless Game::Party.normal_skill?(sk)
      return 0.0 unless @ai && b.actor && @ai.skill_ready?(b.actor, sid)
      rank =
        case sk.scope
        when 3 then @allies.reduce(0.0) { |m, t| [m, auto_battle_heal_rank(b, sk, t)].max }
        when 4 then @allies.reduce(0.0) { |s, t| s + auto_battle_heal_rank(b, sk, t) }
        when 0 then @enemies.reduce(0.0) { |m, t| [m, auto_battle_damage_rank(b, sk, t)].max }
        when 1 then @enemies.reduce(0.0) { |s, t| s + auto_battle_damage_rank(b, sk, t) }
        when 2 then auto_battle_heal_rank(b, sk, b)
        else 0.0
        end
      rank += @rng.random(100) / 100.0 if rank > 0.0
      rank
    end

    # Ported from a reference implementation, NOT
    # independently confirmed against genuine RPG_RT under wine: how good
    # `sk` (an enemy-scope skill, cast by `b`) would be against a single
    # `target`, reusing
    # `EnemyAi#skill_command` -> `Game::Party#battle_skill_command`'s own
    # already-computed `hp` (already `-(base - target's defence, floored at
    # 0)`, the identical figure a reference implementation's own
    # skill-effect calculation builds before its own
    # attribute-multiplier/variance steps) rather than re-deriving it, so
    # this can never drift from what the skill would actually deal if cast
    # for real. 0.0 for a dead/hidden target, or a fully-resisted swing (the
    # `min(dmg, tgt_hp)` term never letting an overkill inflate the rank past
    # what the target could actually lose) — 1.5 exactly at a guaranteed kill
    # (`rank == 1.0`), then a flat SP-cost penalty (the *raw*, half-SP-cost-
    # gear-ignoring cost — `#auto_battle_raw_cost`, matching `Calc
    # SkillCostAutoBattle`'s own "ignores half sp cost modifier" comment) and
    # a `*1.5+0.5` bonus reserved for the very first still-living enemy in
    # troop order specifically (never any other member, matching the site
    # exactly — this is what nudges a Forced-AI actor toward finishing off
    # the front-most target rather than spreading damage around).
    def auto_battle_damage_rank(b, sk, target)
      return 0.0 unless target && !target.out_of_play?
      cmd = @ai && @ai.skill_command(sk, b, target)
      return 0.0 unless cmd
      dmg = -(cmd[:hp] || 0)
      dmg = apply_attr_multiplier(dmg, cmd[:attributes], target)
      dmg = varied(dmg, sk.respond_to?(:variance) ? (sk.variance || 0) : 0)
      tgt_hp = target.hp
      return 0.0 if tgt_hp <= 0
      rank = [dmg, tgt_hp].min.to_f / tgt_hp
      rank = 1.5 if rank == 1.0
      src_max_sp = b.max_mp || 0
      if src_max_sp > 0
        rank -= auto_battle_raw_cost(sk, b).to_f / src_max_sp / 4.0
        rank = 0.0 if rank < 0
      end
      first = @enemies.find { |e| !e.out_of_play? }
      rank = rank * 1.5 + 0.5 if first && first.equal?(target)
      rank
    end

    # Ported from a reference implementation, not independently confirmed
    # against genuine RPG_RT under wine: how good `sk` (an ally/
    # self-scope skill, cast by `b`) would be for a single `target`. A living
    # target ranks the raw heal reused from `#skill_command` (positive `hp`,
    # no target-defence term) against how much headroom it actually has left
    # (`min(base, max_hp - hp) / max_hp` — healing a nearly-full ally for a
    # lot ranks the same as topping off a nearly-empty one for a little), less
    # the same raw-SP-cost penalty `#auto_battle_damage_rank` charges. A
    # downed target (`hp <= 0`) instead checks whether `sk` could revive it
    # at all — its own `state_effects` list naming Knockout (state id 1,
    # `Game::Actor::DEATH_STATE`) as the very first entry — and, if so, ranks
    # it by the skill's own `power` field alone, deliberately **not**
    # checking `reverse_state_effect` first (`emulate_bugs: true`
    # reproduces an RPG_RT bug documented in a reference implementation
    # (ported from that source, not independently confirmed against genuine
    # RPG_RT under wine):
    # "RPG_RT does not check the reverse_state_effect flag to skip skills
    # which would kill party members" — a Berserk-on-self skill flagged to
    # *inflict* Knockout via the reverse flag still reads as a viable revive
    # here, exactly like real RPG_RT).
    def auto_battle_heal_rank(b, sk, target)
      if target.hp > 0
        return 0.0 unless sk.respond_to?(:affect_hp) && sk.affect_hp
        cmd = @ai && @ai.skill_command(sk, b, target)
        return 0.0 unless cmd
        base = cmd[:hp] || 0
        return 0.0 if base <= 0
        base = apply_attr_multiplier(base, cmd[:attributes], target)
        base = varied(base, sk.respond_to?(:variance) ? (sk.variance || 0) : 0)
        tgt_max_hp = target.max_hp || 0
        return 0.0 if tgt_max_hp <= 0
        max_effect = [base, tgt_max_hp - target.hp].min
        rank = max_effect.to_f / tgt_max_hp
        src_max_sp = b.max_mp || 0
        if src_max_sp > 0
          rank -= auto_battle_raw_cost(sk, b).to_f / src_max_sp / 8.0
          rank = 0.0 if rank < 0
        end
        rank
      else
        ids = sk.respond_to?(:state_effects) ? sk.state_effects : nil
        return 0.0 unless ids && ids[0] && ids[0] != 0
        (sk.respond_to?(:power) ? (sk.power || 0) : 0) / 1000.0 + 1.0
      end
    end

    # `sk`'s SP cost with `caster`'s own half-SP-cost gear deliberately
    # ignored -- ported from a reference implementation, not independently
    # confirmed against genuine RPG_RT under wine: under the equivalent of
    # `emulate_bugs: true`, half-SP-cost gear is ignored for the
    # ranking-only cost term `#auto_battle_damage_rank`/`#auto_battle_heal_
    # rank` both charge -- distinct from `Game::Party#skill_cost`, which
    # *does* apply the discount and is what `EnemyAi#skill_command`'s own
    # `cost:` (the amount actually spent once the action is queued) already
    # reuses unchanged.
    def auto_battle_raw_cost(sk, caster)
      # The percent-cost branch is RPG2003-only, exactly like
      # Game::Party#skill_cost's own `rpg2003? && sk.sp_type == 1` gate --
      # ported from the same edition check a reference implementation applies,
      # not independently confirmed against genuine RPG_RT under wine.
      # Without it, a stray nonzero `sp_type` byte on an RPG2000 database (the
      # field's schema default is 0, but the RPG2000 editor never controls it,
      # so a hand-edited row can carry anything) would route through the
      # percent formula here even though the actual charge (#skill_cost) never
      # would, inflating the ranking-only cost term this feeds.
      if @rpg2003 && sk.respond_to?(:sp_type) && sk.sp_type == 1
        (caster.max_mp || 0) * (sk.respond_to?(:sp_percent) ? (sk.sp_percent || 0) : 0) / 100
      else
        sk.respond_to?(:sp_cost) ? (sk.sp_cost || 0) : 0
      end
    end

    # Ported from a reference implementation's normal-attack auto-battle
    # target-ranking function, with variance disabled (RpgRtCompat's own
    # `attack_variance` flag) -- the base swing
    # (`Battle.attack_damage`, the same `atk/2 - def/4` formula #deal_attack
    # itself hits with) is never spread by variance here. Ported from
    # that reference implementation's source, NOT independently confirmed
    # against genuine RPG_RT
    # under wine: the ranking function
    # computes its own `base_effect` by calling
    # the *identical*
    # function the real attack execution
    # calls to resolve the swing in that engine --
    # so the ranking pass reads the same state-adjusted ATK/DEF
    # (ported here as #effective_atk/
    # #effective_def) and the same RPG2003 attacker/defender row adjustment
    # (ported here as
    # #row_adjusted?) the attack applies in that implementation, in the
    # same order (attacker
    # row -> weapon-Attribute multiplier -> defender row) -- not merely an
    # equivalent approximation, but literally the same calculation call. A
    # prior version of this comment (and of `#choose_auto_battle_command`'s
    # own, see its citation) claimed the opposite -- that this ranking pass
    # deliberately omits row modifiers to avoid "double
    # counting" them against the real attack -- an unverified, plausible-
    # sounding inference rather than something read off this function's own
    # source; the two calculations are not independent at all (still NOT
    # independently confirmed against genuine RPG_RT under wine).
    # `emulate_bugs:
    # true` skips the dual-wield swing-count multiplier entirely -- a bug
    # that reference implementation documents as matching RPG_RT, "Dual Attack is ignored" for ranking
    # purposes, even though the swing itself still lands twice once actually
    # thrown (see `Combatant#strike_count`, untouched by this). The
    # `*1.5+0.5` first-enemy bonus and the final jitter-plus-`*1.5`
    # reshaping both mirror `#auto_battle_damage_rank`'s and this function's
    # own C++ counterpart exactly -- note the jitter step here runs
    # unconditionally whenever `target` exists and this rank is positive,
    # stacking with (not replacing) the first-enemy bonus above it, matching
    # the source's own two independent `rank = rank*1.5+...` lines rather
    # than folding them into one.
    def auto_battle_attack_target_rank(b, target)
      return 0.0 unless target && !target.out_of_play?
      dmg = Battle.attack_damage(effective_atk(b), effective_def(target))
      dmg = 125 * dmg / 100 if row_adjusted?(b, true)
      dmg = apply_attr_multiplier(dmg, b.atk_attrs, target)
      dmg = 75 * dmg / 100 if row_adjusted?(target, false)
      tgt_hp = target.hp
      return 0.0 if tgt_hp <= 0
      rank = [dmg, tgt_hp].min.to_f / tgt_hp
      rank = 1.5 if rank == 1.0
      first = @enemies.find { |e| !e.out_of_play? }
      rank = rank * 1.5 + 0.5 if first && first.equal?(target)
      rank > 0.0 ? @rng.random(100) / 100.0 + rank * 1.5 : rank
    end

    # Ported from a reference implementation's normal-attack auto-battle
    # ranking function, not independently confirmed against genuine RPG_RT
    # under wine: under `emulate_bugs: true`
    # this always takes the *max* over every living enemy's own target rank,
    # never the sum -- the same "Dual Attack ignored" family of RPG_RT
    # quirks `#auto_battle_attack_target_rank` already documents (an
    # `attack_all` weapon has no separate bonus to miss here: confirmed by
    # an actual wine capture that the flag does not spread a basic Attack at
    # all, see Actor#attack_all?'s own citation).
    def auto_battle_attack_rank(b)
      @enemies.reduce(0.0) { |m, t| [m, auto_battle_attack_target_rank(b, t)].max }
    end

    # Queues `sk` (database id `sid`) on `b`, re-deriving its actual target(s)
    # by scope exactly the way the field/battle menus already do (#command_
    # skill / #command_skill_all, `Scene::Map#apply_pending_skill`/`#apply_
    # pending_skill_all`'s own shape, reused here instead of duplicated) --
    # a single-target scope (0 enemy / 3 ally) re-ranks every candidate
    # target fresh (a second, independent set of variance/jitter draws from
    # the ones #auto_battle_skill_rank already spent deciding *whether* to
    # cast this skill at all, matching a reference implementation's own
    # second, separate target-selection loop, not independently confirmed
    # against genuine RPG_RT under wine) and falls back to
    # `#command_skip` -- the same "acts, but does nothing" outcome
    # a reference implementation's own no-op battle algorithm produces -- on
    # the vanishingly rare chance
    # every candidate ranks at or below zero. Self/all-target scopes need no
    # such search.
    def queue_auto_battle_skill(b, sk, sid)
      case sk.scope
      when 1 # all enemies
        queue_auto_battle_group_skill(b, sk, sid, @enemies.reject(&:out_of_play?))
      when 4 # all allies
        queue_auto_battle_group_skill(b, sk, sid, @allies.reject(&:dead?))
      when 0 # single enemy
        best = auto_battle_best_target(@enemies) { |t| auto_battle_damage_rank(b, sk, t) }
        best ? queue_single_auto_battle_skill(b, sk, sid, best) : command_skip(b)
      when 3 # single ally
        best = auto_battle_best_target(@allies) { |t| auto_battle_heal_rank(b, sk, t) }
        best ? queue_single_auto_battle_skill(b, sk, sid, best) : command_skip(b)
      when 2 # self
        queue_single_auto_battle_skill(b, sk, sid, b)
      else
        command_skip(b)
      end
    end

    # The member of `targets` with the strictly-highest block-yielded rank, or
    # nil when none scores above 0.0 -- `SelectAutoBattleAction`'s own
    # `best_target_rank` starts at exactly 0.0 too, so a rank that only ever
    # reaches 0.0 (every candidate already resisting/full/out of reach) never
    # wins by matching it.
    def auto_battle_best_target(targets)
      best = nil
      best_rank = 0.0
      targets.each do |t|
        r = yield t
        if r > best_rank
          best_rank = r
          best = t
        end
      end
      best
    end

    def queue_single_auto_battle_skill(b, sk, sid, target)
      cmd = @ai.skill_command(sk, b, target)
      return command_skip(b) unless cmd
      b.command = skill_command_hash(sk, cmd, target)
      b.command[:skill_id] = sid
      b.last_skill_id = sid
    end

    def queue_auto_battle_group_skill(b, sk, sid, targets)
      return command_skip(b) if targets.empty?
      meta = @ai.skill_command(sk, b, targets.first)
      return command_skip(b) unless meta
      effects = targets.map do |t|
        c = @ai.skill_command(sk, b, t)
        c ? { target: t, hp: c[:hp] || 0, mp: c[:mp] || 0 } : nil
      end.compact
      b.last_skill_id = sid
      command_skill_all(b, effects, name: skill_name_of(sk), skill_id: sid,
                        absorb: meta[:absorb] ? true : false, attack: meta[:attack],
                        cost: meta[:cost], inflict: meta[:inflict], chance: meta[:chance],
                        variance: meta[:variance] || 0, attributes: meta[:attributes],
                        attr_shift: meta[:attr_shift], attr_ids: meta[:attr_ids],
                        stat_mod_keys: meta[:stat_mod_keys], stat_effect: meta[:stat_effect] || 0,
                        cured: meta[:cured], physical_rate: meta[:physical_rate] || 0)
    end

    # An `attack_all` weapon does not change auto-battle targeting either
    # (see Actor#attack_all?'s own citation: confirmed by an actual wine
    # capture that the flag does not spread a basic Attack at all) -- the
    # single best-ranked living enemy is targeted explicitly, same as any
    # other weapon, or the actor's turn is forfeited outright
    # (`#command_skip`) on the same vanishingly rare all-zero chance
    # `#queue_auto_battle_skill`'s own fallback covers.
    def queue_auto_battle_attack(b)
      best = auto_battle_best_target(@enemies) { |t| auto_battle_attack_target_rank(b, t) }
      best ? command_attack(b, best) : command_skip(b)
    end

    # `b` lands a basic attack on `target`: the base damage (scaled by the
    # target's elemental resistance, optionally spread by variance), tripled on a
    # critical hit, then halved (min 1) if the target defends. A target immune to
    # the weapon's element (0% rate) takes no damage. The crit note rides on the
    # log entry.
    # One basic attack, which a 二刀流 weapon (or a two-weapon actor -- see
    # `Actor#strike_count`, which can total more than two swings once one of
    # the two equipped weapons is itself 二刀流) makes land more than once
    # (ported from a reference implementation's summed repeat count, not
    # independently confirmed against genuine RPG_RT under wine).
    # Returns a single log entry for the ordinary one-swing case and an array
    # for every other count, so the log reads the same as the enemy's own
    # dual-attack action — whose "a later swing only lands if an earlier one
    # did not fell the target" rule this follows too. Each swing index is
    # handed to `#deal_attack`, which resolves a two-weapon actor's specific
    # governing weapon for that swing (`Actor#swing_weapon_data`) rather than
    # reusing the same merged hit/attribute/state/crit data for every swing.
    def swing(b, target, hits = 1)
      entries = []
      # A combo multiplies the whole swing count: each base swing round runs
      # `hits` times (so a two-weapon actor's weapon rotation repeats intact),
      # and a swing that fells the target stops the whole attack, matching the
      # single-round rule below and a reference implementation's repeat loop
      # (not independently confirmed against genuine RPG_RT under wine).
      hits.times do
        b.strike_count.times do |i|
          entries << deal_attack(b, target, i)
          break if target.dead?
        end
        break if target.dead?
      end
      entries.size == 1 ? entries.first : entries
    end

    # `swing_index` (0-based) is which swing of the current basic Attack this
    # is. For a two-weapon actor (`Actor#swing_weapon_data`), it resolves
    # which of the two equipped weapons governs *this* swing and temporarily
    # substitutes that weapon's own hit rate / elemental attributes / weapon
    # states / crit chance for `b`'s ordinary merged Combatant fields --
    # Ported from a reference implementation, not independently confirmed
    # against genuine RPG_RT under wine: each swing resolves to exactly one
    # weapon's own data, never a merge across both. Restored before returning either way, so
    # a later swing (or an unrelated read of `b`) sees the ordinary merged
    # values again. Every other Combatant (an enemy, or an actor with at
    # most one equipped weapon) has no override to make, so this is a no-op
    # for them -- the merged fields already correctly describe their one
    # weapon.
    # `charged:` lets a caller that has already resolved whether this attack
    # is charged (#perform_enemy_action, which must snapshot-and-clear
    # `b.charged` before dispatching to any action kind -- see its own
    # comment) hand the value in explicitly, rather than have this method
    # read (and clear) `b.charged` itself. nil -- every other caller,
    # including an ally's own #swing, which never sets `b.charged` at all --
    # keeps the old self-contained behaviour.
    def deal_attack(b, target, swing_index = 0, charged: nil)
      wdata = b.respond_to?(:actor) && b.actor.respond_to?(:swing_weapon_data) ? b.actor.swing_weapon_data(swing_index) : nil
      saved = wdata ? [b.hit_rate, b.atk_attrs, b.atk_states, b.crit_chance] : nil
      if wdata
        b.hit_rate = wdata[:hit_rate]
        b.atk_attrs = wdata[:atk_attrs]
        b.atk_states = wdata[:atk_states]
        b.crit_chance = wdata[:crit_chance]
      end
      deal_attack_with_current_weapon(b, target, charged: charged)
    ensure
      b.hit_rate, b.atk_attrs, b.atk_states, b.crit_chance = saved if saved
    end

    def deal_attack_with_current_weapon(b, target, charged: nil)
      # `attacker_ally` (unlike `target_ally`, which every hit already carries)
      # only appears on a plain Attack's own entry -- it is how
      # Scene::Map#play_battle_action_se tells a normal swing apart from a
      # skill/item hit and gates SFX_ENEMY_ATTACK to an enemy's own Attack.
      # A plain attack's own battle animation -- the attacking actor's current
      # gear (Actor#attack_animation_id), or nil for an enemy (b.actor is nil;
      # see #attack_animation_id's own doc comment for why enemies have none
      # to read) or a bare fixture Combatant with no #actor field at all. The
      # animation plays on a miss too -- the swing itself always happens, only
      # its damage is what a miss zeroes -- so this is computed once and
      # attached to both branches below.
      anim = b.respond_to?(:actor) && b.actor.respond_to?(:attack_animation_id) ? b.actor.attack_animation_id : nil
      # Where it plays: over the targeted enemy's sprite, the same
      # `@enemies.index(target)` lookup #apply_command already attaches to a
      # skill/item entry -- nil when the target is a party member (RPG2000
      # draws no ally sprite; #battle_animation_pixel's screen-centre
      # fallback covers that case exactly as it does for a skill/item).
      target_index = @enemies.index(target)
      # When accuracy is on, roll the attacker's to-hit chance: a miss deals no
      # damage and reads as `missed` on the log entry.
      if @accuracy && !hits?(b, target)
        return { attacker: b.name, target: target.name, damage: 0, missed: true,
                 critical: false, target_hp: target.hp < 0 ? 0 : target.hp,
                 defeated: false, target_ally: ally?(target), attacker_ally: ally?(b),
                 attack_animation_id: anim, target_index: target_index }
      end
      dmg = Battle.attack_damage(effective_atk(b), effective_def(target))
      # RPG2003 row: an actor attacking from the offense (front) row deals
      # +25% damage -- a reference implementation's attacker row adjustment,
      # applied *before* the weapon's elemental scaling (the reference's own
      # order). An enemy attacker is never row-adjusted. The front row is the
      # only row RPG2000 knows, so this is a no-op there.
      dmg = 125 * dmg / 100 if row_adjusted?(b, true)
      # An elemental weapon scales its damage by the target's resistance before
      # variance / criticals (ported from a reference implementation's
      # attribute multiplier step).
      dmg = apply_attr_multiplier(dmg, b.atk_attrs, target)
      # RPG2003 row: a back-row defender takes -25% damage -- the reference's
      # defender adjustment, applied *after* the elemental scaling, again in
      # CalcNormalAttackEffect's own order.
      dmg = 75 * dmg / 100 if row_adjusted?(target, false)
      # No critical on a same-side hit (e.g. a confused ally striking an ally) or
      # against a target whose gear prevents criticals, matching a reference
      # implementation (not independently confirmed against genuine RPG_RT
      # under wine).
      crit = critical?(b) && side_of(b) != side_of(target) && !target.prevents_crit
      # A charged-up attack (the enemy's Charge basic action) hits twice as hard,
      # but a critical takes precedence over it — a reference implementation
      # applies one or the other, never both. `charged` (the parameter) already
      # carries the resolved answer when the caller passed one; otherwise fall
      # back to reading (and spending) `b.charged` directly, matching the old
      # self-contained behaviour.
      if charged.nil?
        charged = b.charged ? true : false
        b.charged = false if charged
      end
      if crit
        dmg *= 3
      elsif charged
        dmg *= 2
      end
      # Variance is the *last* term before the popup cap -- a reference
      # implementation applies the critical/charge multiplier and only
      # then spreads by variance, not the other way round. Since
      # #varied's own spread (`var*base/10`) scales with its input, rolling it
      # on the pre-crit base and tripling the *result* afterward (a prior
      # version's order) both narrows the spread relative to the final damage
      # and collapses it onto only the multiples of 3 (or 2) the pre-crit
      # value's own noise happened to land on, instead of the wider, finer-
      # grained spread a variance roll against the *actual* (already tripled/
      # doubled) damage produces.
      dmg = varied(dmg, NORMAL_ATTACK_VARIANCE) if @variance && dmg > 0
      # Defending halves the blow, and 強力防御 halves it again — a quarter, not a
      # half. Confirmed against genuine RPG_RT under wine (2026-09-05): an
      # ordinary defending target and an otherwise-identical Strong-Defence-
      # flagged defending target, hit by the same enemy's plain Attack
      # (identical atk/def on both sides), took roughly a 2.5x-different
      # amount of damage (56 vs 22) -- consistent with a genuine second
      # halving, not the "changes nothing" result the structurally
      # identical-looking `strong_defence` read in `#enemy_autodestruct` (a
      # self-destruct's own damage) turned out to give in this same
      # session's own testing (see that method's own citation) -- these are
      # separate call sites in genuine RPG_RT and do not all behave the same
      # way. Seven of
      # Nepheshel's 50 actors have
      # it, including its hero. Neither halving carries a floor of its own --
      # `AdjustDamageForDefend` is a bare `dmg /= 2` (twice,
      # for strong defence) with no `std::max` of any kind, unlike the base
      # formula's own `std::max(0, atk/2 - def/4)` floor (already correctly
      # ported as `Battle.attack_damage`'s `d < 0 ? 0 : d`) -- a defending,
      # let alone a strong-defending, target can and does take a genuine 0
      # from a weak hit that would otherwise have landed for 1.
      if target.defending && dmg > 0
        dmg /= 2
        dmg /= 2 if target.strong_defence
      end
      # RPG_RT's damage popup tops out at a fixed width -- a crit/charge blow
      # that would compute past it still only ever takes #damage_cap.
      cap = damage_cap
      dmg = cap if dmg > cap
      target.hp -= dmg
      apply_knockout_reset(target)
      if target.dead?
        woke = []
        inflicted = []
        cured = []
      else
        woke = shake_off_states(target, 100)
        # A weapon's own state_set/state_chance (二刀流 or otherwise) --
        # ported from a reference implementation's weapon-block handling, NOT
        # independently confirmed against genuine RPG_RT under wine, skipped
        # like the rest of this section once the blow already felled the target.
        inflicted, cured = roll_weapon_states(b, target)
      end
      entry = { attacker: b.name, target: target.name, damage: dmg, critical: crit,
                charged: charged, target_hp: target.hp < 0 ? 0 : target.hp,
                defeated: target.dead?, target_ally: ally?(target),
                attacker_ally: ally?(b), attack_animation_id: anim,
                target_index: target_index }
      entry[:woke] = woke unless woke.empty?
      entry[:inflicted] = inflicted unless inflicted.empty?
      entry[:cured] = cured unless cured.empty?
      entry
    end

    # Statuses a physical hit knocks its target out of, scaled by `rate`
    # (0..100): each state carrying a `release_by_attack` percentage rolls
    # against `release_by_attack * rate / 100`, and a hit that lands wakes the
    # sleeper. Returns the ids removed, so the log can report them. Only
    # called when the target lived through the blow.
    #
    # Ported from a reference implementation's physical-state-heal handling,
    # NOT independently confirmed against genuine RPG_RT under wine -- and a
    # wine capture this session actively contradicts this formula for an
    # *enemy* target: a custom state forced to release_by_attack=100 (which
    # this formula computes as chance=100, an unconditional release) stayed
    # on a passive enemy through two separate landed basic Attacks in a row
    # (each its own confirmed "N damage" log line, no accompanying "woke"
    # line either time, and the state's own affected-message reminder
    # still fired on the enemy's intervening turn, confirming it was still
    # afflicted). Whether this is an ally-vs-enemy asymmetry genuine RPG_RT
    # applies (this codebase's own #shake_off_states, #enemy_autodestruct
    # and #apply_skill_hit call sites make no such distinction), a quirk of
    # this specific state's own fields (restriction 1 -- do-nothing -- same
    # as an ordinary sleep/paralysis state), or something else entirely is
    # NOT settled by this one capture; left for a dedicated follow-up rather
    # than guessed at, since the correct replacement formula isn't known yet
    # either. See docs/TODO.md.
    #
    # It is shared by three call sites, not just a basic attack as a prior
    # version of this comment claimed: `Normal::vExecute` (a basic attack,
    # always the full `physical_rate` 100 -- #deal_attack's own call),
    # `SelfDestruct::vExecute` (also a flat 100 -- #enemy_autodestruct's own
    # call), and `Skill::vExecute` (`skill.physical_rate * 10`, an attack
    # skill's own 0-10 field scaled to a percent -- #apply_skill_hit's own
    # call, 0 for a purely magical skill, which is the same as never rolling
    # at all).
    #
    # Without this, "asleep" meant asleep until the state's own timer expired, no
    # matter how hard it was hit: Nepheshel's 睡眠 wakes on 80% of blows and its
    # 混乱 clears on 30%; mtf-meido-action's Sleep is 50% and Provoke / Confuse
    # 25%.
    #
    # The roll itself is gated only on `release_by_damage > 0` (the `base > 0`
    # check below), matching a reference implementation's own physical-state-
    # heal handling (ported from its source, NOT independently confirmed
    # against genuine RPG_RT under wine): once inside that outer gate it
    # rolls a `release_chance` in 100 chance unconditionally, with no
    # further `release_chance > 0` check -- `release_chance` itself (this
    # method's own `chance`, `release_by_damage * rate / 100`) can still round
    # down to 0 when `rate` is small, and this ported behavior still burns a
    # roll for it (it
    # just never passes). A `chance > 0` short-circuit here used to skip that
    # roll entirely, leaving this build's shared RNG stream one draw ahead of
    # the ported target's from that point on for the rest of the seeded run.
    def shake_off_states(target, rate)
      woke = []
      return woke if rate <= 0
      (target.states || []).dup.each do |sid|
        d = state_def(sid)
        base = d ? state_field(d, :release_by_attack) : 0
        next unless base > 0
        chance = base * rate / 100
        next unless @rng.random(100) < chance
        target.states.delete(sid)
        (target.state_turns || {}).delete(sid) if target.state_turns
        woke.push(sid)
      end
      woke
    end

    # Whether `b`'s attack criticals: enabled for the fight, and a 0..99 roll
    # lands under `b`'s `crit_chance` -- ported from a reference
    # implementation's percent-chance roll, the exact form its
    # already-truncated whole percent is
    # rolled through (NOT independently confirmed against genuine RPG_RT
    # under wine). A chance at or above 100 always crits, which is what a
    # weapon carrying 100% means; a chance of exactly 0 (the common case for
    # any battler with no crit ability at all) never crits either, but this
    # ported behavior still rolls for it -- a reference implementation's own
    # battle-execute step rolls the same `crit_chance` percent chance with no
    # `crit_chance > 0` guard
    # (both the basic-attack and skill call
    # sites). A `chance > 0 &&` short-circuit here used to skip that roll
    # whenever it computed to exactly 0, leaving this build's shared RNG
    # stream one draw behind the ported target's for the rest of the seeded run --
    # every attacker with no crit ability at all (most enemies, and any actor
    # before equipping a crit-capable weapon) silently desynced it on their
    # very first landed hit.
    #
    # Drawn with #random, not #scaled: #scaled exists because a modulus of the
    # generator's prime period over-represents the low values a *large*-scale
    # threshold test (thousands/millions) sits in, which a plain 0..99 roll at
    # `n` = 100 is far too small to suffer from -- the same reasoning
    # `#random`'s own doc comment already gives for every other small-`n`
    # caller in this file.
    def critical?(b)
      return false unless @criticals
      @rng.random(100) < (b.crit_chance || 0)
    end

    # Whether `attacker`'s basic attack lands on `target`: a 0..99 roll under the
    # #to_hit chance.
    def hits?(attacker, target)
      @rng.random(100) < to_hit(attacker, target)
    end

    # Whether one particular effect of a Skill/Item command actually lands --
    # ported from a reference implementation's skill-execution handling, NOT
    # independently confirmed against genuine RPG_RT under wine: it gates each of
    # `affect_hp`/`affect_sp`/`affect_attack`/`affect_defense`/`affect_spirit`/
    # `affect_agility` behind its own, independent `to_hit` percent-chance
    # roll -- `to_hit` there being `skill.hit` for the overwhelming majority of
    # skills (a reference implementation's own skill-to-hit calculation only
    # runs the fuller, agility-adjusted
    # physical-style formula for an enemy-scope skill the editor flagged with
    # the "physical" failure message, `failure_message == 3` -- unmodelled
    # here; see docs/TODO.md). `#battle_skill_command`/`#battle_item_command`
    # already carry that flat rate as `cmd[:chance]`, defaulting to 100 (an
    # item has no `hit` field at all, and the ported medicine algorithm
    # never rolls one -- see `#item_recovery`'s callers), so this is a
    # deliberately thin wrapper: called fresh for every affected field, never
    # cached, matching each being its own roll rather than one shared verdict
    # for the whole skill. Unconditional (always true) when the fight has
    # accuracy off, matching #hits?'s own @accuracy gate for a basic attack --
    # a seeded fight stays reproducible by default, and the live game turns
    # this on (Scene::Map's own `Game::Battle.new(..., true, true, true, ...)`).
    def skill_effect_hits?(cmd)
      return true unless @accuracy
      @rng.random(100) < (cmd[:chance] || 100)
    end

    # Spread `base` by a `var` (0-10) amount: an adjustment of `var*base/10` (min
    # 1) is centred on the base with a random offset, floored at 1. Ported
    # from a reference implementation, not independently confirmed against
    # genuine RPG_RT under wine.
    def varied(base, var)
      return base unless var > 0 && base > 0
      adj = var * base / 10
      adj = 1 if adj < 1
      d = base + @rng.random(adj + 1) - adj / 2
      d < 1 ? 1 : d
    end

    # RPG2000's default attribute rate table (liblcf's RPG::Attribute defaults):
    # a defence rank of A..E (index 0..4) scales damage to 300 / 200 / 100 / 50 /
    # 0 percent. Used as the fallback when the fight carries no attribute table
    # (a bare fixture); a real database's per-attribute `a_rate` .. `e_rate`
    # override it (see #attr_rate).
    ATTR_RATE_PCT = [300, 200, 100, 50, 0].freeze

    # The percentage a defence `rank` (0..4) scales damage for attribute `aid`:
    # the attribute's own `a_rate` .. `e_rate` from the database `property` table
    # when known, else the RPG2000 default table.
    def attr_rate(aid, rank)
      row = @attributes ? @attributes[aid] : nil
      if row && row.respond_to?(:a_rate)
        r = [row.a_rate, row.b_rate, row.c_rate, row.d_rate, row.e_rate][rank]
        return r if r
      end
      ATTR_RATE_PCT[rank]
    end

    # Whether attribute `aid` is the database's weapon-type (property field 2,
    # value 0) rather than magic-type (1) -- the same reading
    # Game::Party#attribute_weapon_type? uses (for skill-usability gating),
    # duplicated here since Battle reaches the property table through its own
    # `@attributes` rather than a database reference shared with Party. An id
    # the table doesn't define reads as magic-type, the permissive default
    # #attribute_weapon_type? also falls back to.
    def attribute_physical?(aid)
      row = @attributes ? @attributes[aid] : nil
      row && row.respond_to?(:type) && row.type == 0 ? true : false
    end

    # Scale `dmg` by `attr_ids`'s rate against `target`'s per-attribute
    # defence ranks: ported from a reference implementation's attribute-
    # multiplier logic, NOT independently confirmed against genuine RPG_RT
    # under wine. Each
    # attribute is either weapon-type (physical) or magic-type; the
    # strongest (largest) rate *within* each type is kept, and an attack
    # carrying both types at once multiplies the two rates as two successive
    # percentage scalings of `dmg` -- not an average, and not just the
    # single strongest rate across every attribute regardless of type (a
    # 200%-physical, 50%-magical attack nets 100%, not 200%). Ported
    # truncation-order and all (`magical * (physical * dmg / 100) / 100`)
    # rather than precomputing a combined percentage first, since the two
    # can round differently -- a combined-percentage shortcut
    # ((weapon_best || 100) * (magic_best || 100) / 100, applied by the
    # caller as `dmg * combined / 100`) was tried and dropped in an earlier
    # revision of this method for exactly that reason. Unchanged for an
    # attribute-less attack; a rank the target doesn't list defaults to C
    # (100%). A database's own `a_rate`..`e_rate` fields are plain signed
    # ints with no validation (`#attr_rate`), so a negative rank rate is
    # real, reachable data (a deliberate "elemental absorb" trick), not
    # exclusive to RPG2003 -- `ApplyAttributeMultiplier`'s own
    # edition-gated limit (ported from a reference implementation's source,
    # NOT independently confirmed against genuine RPG_RT
    # under wine) treats the two editions
    # differently: RPG2000 drops a side whose best rate is negative from
    # consideration entirely (the attack passes through unscaled by that
    # side, never healing), while RPG2003 lets a negative side scale the
    # damage directly when it is the only one present, and falls to
    # `dmg * [physical, magical].max / 100` (the milder of the two rather
    # than multiplying) once either side is negative and both are present.
    def apply_attr_multiplier(dmg, attr_ids, target)
      return dmg if attr_ids.nil? || attr_ids.empty?
      ranks = target.attr_ranks || {}
      physical = nil
      magical = nil
      attr_ids.each do |aid|
        rank = ranks[aid] || 2
        rank = 0 if rank < 0
        rank = 4 if rank > 4
        pct = attr_rate(aid, rank)
        if attribute_physical?(aid)
          physical = pct if physical.nil? || pct > physical
        else
          magical = pct if magical.nil? || pct > magical
        end
      end
      p_ok = above_attr_limit?(physical)
      m_ok = above_attr_limit?(magical)
      if p_ok && m_ok
        if physical >= 0 && magical >= 0
          magical * (physical * dmg / 100) / 100
        else
          dmg * [physical, magical].max / 100
        end
      elsif p_ok
        physical * dmg / 100
      elsif m_ok
        magical * dmg / 100
      else
        dmg
      end
    end

    # Whether a bucket-max rate `v` (nil when that type matched nothing at
    # all) clears `ApplyAttributeMultiplier`'s own edition-gated floor: any
    # real value on RPG2003 (mirroring its `INT_MIN` limit), non-negative
    # only on RPG2000 (its `-1` limit) -- see #apply_attr_multiplier above.
    def above_attr_limit?(v)
      return false if v.nil?
      @rpg2003 || v >= 0
    end

    # The most disruptive "forced action" restriction among `b`'s states (0 = act
    # normally). This is *not* a numeric max over the restriction constants --
    # ported from a reference implementation's significant-restriction logic, NOT
    # independently confirmed against genuine RPG_RT under wine: it walks every
    # afflicted state and tracks a fixed priority hierarchy, do_nothing >
    # attack_enemy (berserk) > attack_ally (confusion) > normal, with
    # asymmetric upgrade rules: attack_enemy overrides attack_ally or normal,
    # but attack_ally only ever overrides normal (never attack_enemy), and
    # do_nothing short-circuits immediately regardless of what else is
    # present. Matches デフォ戦bot's own trivia: berserk beats confusion when
    # both are active simultaneously, even though RESTRICTION_ATTACK_ALLY is
    # numerically the larger constant.
    def battler_restriction(b)
      r = 0
      (b.states || []).each do |id|
        v = state_field(state_def(id), :restriction)
        case v
        when RESTRICTION_DO_NOTHING
          return RESTRICTION_DO_NOTHING
        when RESTRICTION_ATTACK_ENEMY
          r = RESTRICTION_ATTACK_ENEMY if r == 0 || r == RESTRICTION_ATTACK_ALLY
        when RESTRICTION_ATTACK_ALLY
          r = RESTRICTION_ATTACK_ALLY if r == 0
        end
      end
      r
    end

    # A state's boolean field, false for an unknown state or a fixture row that
    # does not model it.
    def state_flag(d, name)
      d.respond_to?(name) ? (d.send(name) ? true : false) : false
    end

    # A random living target for a forced attack: an enemy (attack-enemy) or a
    # member of the battler's own side including itself (attack-ally / confusion).
    def restricted_target(b, r)
      own = side_of(b) == :ally ? @allies : @enemies
      pool = r == RESTRICTION_ATTACK_ALLY ? own : (side_of(b) == :ally ? @enemies : @allies)
      random_living(pool)
    end

    # The living target `b` attacks: an ally uses its chosen target while it
    # lives, otherwise a random living foe. An enemy instead uses the party
    # member #refill_queue already locked onto it when this round's queue was
    # built (`b.queued_target`) -- fizzling (nil, no swing) if that member has
    # since fallen or left, rather than silently retargeting whoever remains,
    # the same fizzle rule an ally's own locked Skill/Item target already gets
    # (#apply_command's `target.dead? && !command_targets_dead_ok?`). See
    # `queued_target`'s own field comment for the reference-implementation
    # citation and the "never went through #refill_queue" fallback.
    def attack_target(b)
      if side_of(b) == :ally
        return b.action if b.action && !b.action.dead?
        return random_living(@enemies)
      end
      return random_living(@allies) if b.queued_target.nil?
      b.queued_target.out_of_play? ? nil : b.queued_target
    end

    # A uniformly random living (not #out_of_play?) member of `pool`, or nil
    # when none remain -- the shared random-target roll #attack_target and
    # #restricted_target each already made independently before this helper
    # existed.
    def random_living(pool)
      living = pool.reject(&:out_of_play?)
      living.empty? ? nil : living[@rng.random(living.size)]
    end

    def side_of(b); @allies.any? { |a| a.equal?(b) } ? :ally : :enemy; end

    # Whether a Skill/Item `cmd` may still target an already-downed battler --
    # ported from a reference implementation's own per-algorithm target-
    # validity override, NOT independently confirmed against genuine RPG_RT
    # under wine, re-checked
    # at resolution time
    # (`Scene_Battle_Rpg2k::ProcessBattleActionExecute`'s own `if (!action->
    # IsCurrentTargetValid()) { ...finish, no Execute()... }`, not just when
    # the target was originally picked): `Item::IsTargetValid` ignores the
    # target entirely (`return item.type == Type_medicine || item.type ==
    # Type_switch;` -- always valid, dead or alive), while the generic
    # default (`AlgorithmBase::IsTargetValid`, used by an ordinary attack)
    # is `target.Exists()` -- false the instant HP reaches 0.
    # `Skill::IsTargetValid` sits between the two: `if (target.IsDead())
    # return SkillTargetsAllies(skill) && !skill.state_effects.empty() &&
    # skill.state_effects[0];` -- only a Death-curing, ally-scoped skill may
    # still target a downed ally.
    def command_targets_dead_ok?(cmd)
      return true if cmd[:kind] == :item
      (cmd[:cured] || []).include?(Game::States::DEATH_ID)
    end

    # Resolve `b`'s queued Skill / Item command and return its log entry, or nil
    # when the chosen target has already fallen this round (the action fizzles —
    # no SP is spent and nothing animates). A skill first spends the caster's SP;
    # then a negative-HP command (an attack skill) subtracts HP and reads like an
    # attack (`skill:` names it), while a recovery command (heal skill / medicine)
    # restores HP / SP clamped to the target's maxima and reads as a `recover`.
    #
    # The `target.dead?` gate is what keeps an ordinary attack or a plain heal
    # from ever touching a downed (0 HP) combatant -- the in-battle mirror of
    # Game::Actor#change_hp's own `return @hp if dead?` guard on the field --
    # but #command_targets_dead_ok? carves out the same two exceptions real
    # RPG_RT's own `IsTargetValid` does: an Item command's target is always
    # valid (so a downed ally chosen for a revival medicine, already
    # selectable per #battle_ally_targets, actually resolves instead of
    # silently fizzling with the item never consumed), and a Skill command
    # whose own `cured` list includes Death may still land on one too.
    #
    # A single-target Skill whose target carries a Reflect-Magic-flagged
    # state does NOT bounce back onto `b` -- reverted, confirmed wrong
    # against a genuine RPG_RT.exe under wine (2026-09-05): a Reflect-Magic-
    # flagged party member kept taking an enemy's own single-target Skill
    # damage directly, across two separately-landed casts, never once
    # redirecting it back onto the caster. See #reflects_magic?'s own
    # removal note for the capture; the mechanic was never real to begin
    # with, matching this session's earlier `evades_all_physical?`/
    # `avoid_attacks` reversal.
    def apply_command(b, combo = 1)
      cmd = b.command
      return apply_command_all(b, cmd, combo) if cmd[:all]
      target = cmd[:target]
      return nil if target.nil?
      return nil if target.dead? && !command_targets_dead_ok?(cmd)
      b.mp = [b.mp - cmd[:cost], 0].max if cmd[:cost] && cmd[:cost] > 0
      # A combo'd skill repeats its effect `combo` times against the same
      # target, the SP spent once -- a reference implementation's repeat loop
      # over the algorithm (which also pays its cost once), not independently
      # confirmed against genuine RPG_RT under wine. Each repeat is its own
      # log entry (buffered by #record_action), and one that fells the target
      # stops the repeats, matching the swing rule.
      entries = []
      combo.times do
        entry = apply_skill_hit(b, target, cmd[:hp] || 0, cmd[:mp] || 0, cmd)
        entries << entry if entry
        break if target.dead?
      end
      entries.size == 1 ? entries.first : (entries.empty? ? nil : entries)
    end

    # An all-target Skill (scope 1 all enemies / 4 all allies): spend the SP once,
    # then apply the per-target effect to every living target, returning one log
    # entry per hit (which #step_action surfaces one at a time). Fizzles — nil, no
    # SP spent — when every listed target has already fallen this round. Same
    # per-target `dead?` filter as #apply_command (#command_targets_dead_ok?'s
    # same two exceptions apply here too -- a party-wide revival item/Full
    # Recovery-type skill genuinely does stand up every downed member of an
    # all-ally volley, not just the living ones).
    #
    # An all-target Skill's volley does NOT redirect onto `b`'s own side even
    # when an originally-selected target carries a Reflect-Magic-flagged
    # state -- reverted alongside the single-target path above; see
    # #reflects_magic?'s own removal note for the wine capture that
    # falsified the mechanic outright, in both shapes alike.
    def apply_command_all(b, cmd, combo = 1)
      live = (cmd[:targets] || []).select do |t|
        t[:target] && (!t[:target].dead? || command_targets_dead_ok?(cmd))
      end
      return nil if live.empty?
      b.mp = [b.mp - cmd[:cost], 0].max if cmd[:cost] && cmd[:cost] > 0
      # A combo'd all-target skill repeats the whole volley `combo` times (one
      # entry per hit, buffered by #record_action), the SP spent once -- the
      # same rule as #apply_command's single-target repeat.
      entries = []
      combo.times do
        live.each do |t|
          entries << apply_skill_hit(b, t[:target], t[:hp] || 0, t[:mp] || 0, cmd)
        end
      end
      # An all-ally item is consumed once for the whole volley: keep item_id on
      # the first hit only, so the scene's per-entry bag deduction fires once.
      entries.each_with_index { |e, i| e[:item_id] = nil unless i.zero? } if cmd[:item_id]
      entries
    end

    # Apply one skill / item effect from `b` to `target`: an attack (elemental
    # scaling, variance, then state infliction, reading as a `skill:` hit) or a
    # restore of HP / SP that also cures states (reading as a `recover`).
    # Returns the log entry. Shared by single- and all-target commands.
    #
    # Which branch runs is `cmd[:attack]` when the caller set it explicitly --
    # #battle_skill_command always does, so real skill/item play is unambiguous
    # -- falling back to the sign of `hp` (the old, only rule) when it did not.
    # The explicit flag matters because the sign alone is ambiguous exactly at
    # a 0-damage hit: an attack skill's damage can genuinely compute to 0
    # against a heavily-defended target (see #battle_skill_command's own
    # floor-at-0 fix), and `-0 == 0` reads the same as an ordinary non-negative
    # recovery amount.
    def apply_skill_hit(b, target, hp, mp, cmd)
      attack = cmd[:attack].nil? ? hp < 0 : cmd[:attack]
      if attack
        # The skill's one shared, un-gated effect magnitude: whichever of
        # hp/mp actually carries it (each already the correct *per-target*
        # figure -- #command_skill_all's own per-target hp/mp, defence term
        # included), falling back to `cmd[:stat_effect]` (#battle_skill_command's
        # enemy branch always sets it now, mirroring the ally branch's own
        # `stat_effect: base`) only when neither pool is affected at all -- a
        # stat-mod-only skill (Weaken and friends), which still needs a real
        # number to scale/roll below even though affect_hp/affect_sp leave
        # both `hp` and `mp` at 0. Ported from a reference implementation's
        # shared `effect` local, computed once regardless of which affect_*
        # flags actually read it (NOT independently confirmed against genuine
        # RPG_RT under wine).
        dmg = hp != 0 ? -hp : (mp != 0 ? -mp : (cmd[:stat_effect] || 0))
        # An elemental skill scales its damage by the target's resistance
        # first, then a critical hit, then
        # spreads by variance -- ported from a reference implementation's own
        # order exactly (attribute multiplier, then a `*= 3` critical
        # multiplier, then variance last), NOT independently
        # confirmed against genuine RPG_RT under wine.
        dmg = apply_attr_multiplier(dmg, cmd[:attributes], target)
        # A skill/spell crits at the caster's own basic-attack rate (weapon
        # bonus included) -- ported from a reference implementation's skill-
        # execution handling, NOT
        # independently confirmed against genuine RPG_RT under wine: it rolls
        # the same critical-hit-chance calculation, the
        # exact same rate `#deal_attack` already reads via `#critical?`, not a
        # separate magic-only chance. Previously nothing here ever rolled a
        # skill/spell critical at all -- every offensive skill's damage was
        # capped at its non-critical value on every single cast. Same
        # same-side / gear exclusions as a basic attack.
        crit = critical?(b) && side_of(b) != side_of(target) && !target.prevents_crit
        dmg *= 3 if crit
        # Spread the skill's damage by its own variance when the fight rolls it.
        dmg = varied(dmg, cmd[:variance]) if @variance && dmg > 0 && cmd[:variance] && cmd[:variance] > 0
        # Same hard-cap as a normal attack (#deal_attack), applied before
        # absorption so a drain skill can't smuggle a bigger hit past it either.
        cap = damage_cap
        dmg = cap if dmg > cap
        # The ATK/DEF/SPI/AGI modifier delta (see #apply_stat_mods) shares
        # this same post-attribute-scaling, post-variance, post-cap figure --
        # captured here, before 吸収 trims `dmg` further below, ported from
        # a reference implementation's own one shared `effect` local for every
        # one of hp/atk/def/spi/agi (NOT independently confirmed against
        # genuine RPG_RT under wine), which has no stat-absorbing counterpart
        # to HP's own (vanilla RPG2000/2003 never enables that
        # implementation's optional stat-absorbing extension).
        stat_amount = -dmg
        # Whether the blow actually lands -- ported from a reference
        # implementation's skill-execution handling, NOT independently
        # confirmed against genuine RPG_RT under wine: it gates `affect_hp`'s application
        # behind its own `to_hit` percent-chance roll, `to_hit` being
        # `cmd[:chance]` here (#skill_effect_hits?). Computed once and reused
        # for both the HP change and 吸収 below -- they are the same
        # `affect_hp` gate in that ported source, not two independent rolls.
        hits = skill_effect_hits?(cmd)
        # 吸収: the caster takes what the target loses, and can take no more than
        # the target has. Ported from a reference implementation, NOT
        # independently confirmed against genuine RPG_RT under wine: the
        # effect is clamped to the
        # target's current HP *before* applying it ("Only absorb the hp that
        # were left"), so a 200-damage drain on a 30 HP foe deals 30 and
        # returns 30 -- the drain is weaker against a nearly-dead target, not
        # merely capped in what it gives.
        absorbed = 0
        hp_dmg = 0
        hp_before = target.hp
        if hits && hp != 0
          hp_dmg = dmg
          # An offensive skill's HP effect is halved (quartered under 強力防御)
          # against a defending target, the same `AdjustDamageForDefend` a
          # basic attack already gets (`#deal_attack_with_current_weapon`
          # above) — ported from a reference implementation's skill-execution
          # handling. Confirmed against genuine RPG_RT under wine (2026-09-05):
          # a purely magical real skill cast at a defending, Strong-Defence
          # (強力防御)-flagged target dealt 11 damage, versus an identically
          # defending target with the flag off taking 24 (predicted base 48,
          # halved once to ~24, halved again to ~12) — the quartering is real
          # here, unlike the *structurally identical-looking* `strong_defence`
          # read this same session found NOT to apply to a self-destruct's own
          # damage (`#enemy_autodestruct`'s own citation): these are two
          # separate call sites in genuine RPG_RT, not a shared routine, and
          # they behave differently. The SP effect and the ATK/DEF/SPI/AGI
          # stat-mod branches read the same raw `effect` with no such
          # adjustment, so only `hp_dmg` gets this treatment here -- that half
          # of the claim remains unconfirmed.
          if target.defending && hp_dmg > 0
            hp_dmg /= 2
            hp_dmg /= 2 if target.strong_defence
          end
          if cmd[:absorb] && hp_dmg > 0
            hp_dmg = target.hp if hp_dmg > target.hp
            absorbed = hp_dmg
          end
          target.hp -= hp_dmg
          apply_knockout_reset(target)
        end
        b.hp = [b.hp + absorbed, b.max_hp].min if absorbed > 0
        # The same shared, un-gated `dmg` the HP branch above just used, applied
        # to the target's SP instead -- ported from a reference
        # implementation's skill-execution handling,
        # NOT independently confirmed against genuine RPG_RT under wine by
        # itself: it reads its one `effect` local raw here (no elemental/
        # absorb/defend-adjustment difference from the HP side), and rolls its
        # own fresh accuracy check independent of the HP roll
        # above, the same way the ally/recovery branch's own HP and SP each
        # roll separately. Skipped entirely once the HP hit above has just
        # killed the target -- that ported source's own early return once the
        # target's HP has already dropped to or below zero runs *before* the affect_sp
        # block, so a dual HP+SP attack skill that lands a killing blow never
        # also drains SP on the same swing -- this specific interaction is
        # independently confirmed against @2000_battle_bot/デフォ戦bot's own
        # trivia: "HPがゼロになった場合、MPは減らない".
        sp_dmg = 0
        mp_before = target.mp
        if mp != 0 && !target.dead? && target.mp && target.max_mp && skill_effect_hits?(cmd)
          sp_dmg = dmg
          target.mp = [target.mp - sp_dmg, 0].max
        end
        # A hit that landed (accuracy roll succeeded) but changed neither pool
        # it was aimed at -- an MP-only skill against a target already at 0
        # MP, the case genuine RPG_RT.exe under wine confirms (cycle #234,
        # Nepheshel): a real, non-enemy-immune state effect bundled onto
        # 恐怖の咆吼 (skill 19, affect_sp only, no affect_hp) against a Slime
        # (max_sp 0, so always a floor-clamped no-op MP change) logged
        # "スライムには効かなかった!" -- the skill's own failure sentence, not
        # a damage/state line -- with no state landing, exactly like a missed
        # hit. `hp != 0`/`mp != 0` is "this skill's affect_hp/affect_sp is
        # actually enabled", not merely "the target had some HP/MP" -- a
        # skill with neither flag set (a pure stat-mod/state skill) is
        # unaffected by this and keeps landing its effects normally.
        no_effect = hits && (hp != 0 || mp != 0) &&
                    (hp == 0 || target.hp == hp_before) &&
                    (mp == 0 || target.mp == mp_before)
        # An attack skill may inflict its states -- or, under the RPG2003
        # reverse_state_effect flip #battle_skill_command's own `heals_states`
        # already resolved, cure them instead -- and shift attribute defence
        # ranks, each rolled/applied only if the target lived through the
        # damage and the hit actually changed something. These roll
        # independently of the HP hit above (ported from a reference
        # implementation's own fresh accuracy roll for each `affect_*` gate,
        # NOT independently confirmed against genuine RPG_RT under wine), so
        # a skill's buff/state can still land on a swing whose damage missed,
        # or vice versa -- but not on a swing that landed and changed
        # nothing at all (wine-confirmed above).
        if target.dead? || no_effect
          inflicted = already = cured = shifted = woke = []
          stat_changed = {}
        else
          inflicted, already = roll_inflict(target, cmd)
          # Each cured state rolls its own independent `to_hit_states`
          # accuracy check, exactly like a stat mod/attribute shift's own
          # `skill_effect_hits?` gate just below -- see the comment on the
          # recovery branch's own `cured` line for the full citation.
          cured = (cmd[:cured] || []).select { |s| target.state?(s) && skill_effect_hits?(cmd) }
          cured.each { |s| cure_state(target, s) }
          shifted = apply_attr_shift(target, cmd)
          stat_keys = (cmd[:stat_mod_keys] || []).select { skill_effect_hits?(cmd) }
          stat_changed = apply_stat_mods(target, stat_keys, stat_amount)
          # A physical skill can shake a status loose the same way a basic
          # attack does -- ported from a reference implementation's own
          # equivalent of #shake_off_states,
          # scaled by the skill's `physical_rate` (0 for a purely magical
          # skill, which never rolls), NOT independently confirmed against
          # genuine RPG_RT under wine. Nested behind the *same* `hits` gate as
          # the HP change: that ported source's own physical-state-heal
          # call for a skill sits inside the identical hit-and-accuracy
          # block the damage application itself
          # is in, not a separate roll.
          woke = hits ? shake_off_states(target, cmd[:physical_rate] || 0) : []
        end
        { attacker: b.name, target: target.name, damage: hp_dmg, missed: !hits,
          no_effect: no_effect,
          critical: crit,
          target_hp: target.hp < 0 ? 0 : target.hp, defeated: target.dead?,
          inflicted: inflicted, already: already, cured: cured, woke: woke,
          attr_shifted: shifted, attr_shift_dir: cmd[:attr_shift],
          stat_changed: stat_changed,
          target_ally: ally?(target), skill: cmd[:name],
          # `cmd[:item_id]` mirrors the recovery branch's own identical field
          # just below -- an attack-flavoured skill invoked by a battle item
          # (a thrown bomb) needs it on the log entry exactly as much as a
          # medicine's own recovery does, for #drive_battle_animate's own
          # bag-consumption.
          item_id: cmd[:item_id], skill_id: cmd[:skill_id], target_index: @enemies.index(target),
          absorbed_hp: absorbed, sp_damage: sp_dmg,
          target_mp: target.mp }
      else
        # The skill's one shared, un-gated effect magnitude -- the exact same
        # idiom the attack branch's own `dmg` local above uses (`hp != 0 ?
        # hp : (mp != 0 ? mp : cmd[:stat_effect])`), since `#battle_skill_command`'s
        # ally branch already builds `hp`/`mp`/`stat_effect` from the
        # identical `base`. Ported from a reference implementation's skill-
        # execution handling, NOT independently confirmed against
        # genuine RPG_RT under wine: it computes one `effect` local --
        # its own skill-effect calculation applies the attribute multiplier
        # and then adjusts for variance
        # exactly once each -- and reads that same raw
        # number into every one of its `affect_hp`/`affect_sp`/`affect_attack`/
        # `affect_defense`/`affect_spirit`/`affect_agility` branches, each
        # still gated by its own fresh `to_hit` percent-chance roll (see
        # `#skill_effect_hits?`'s own per-field calls below -- that part was
        # already correct). Previously `hp`/`mp`/`stat_amount` each ran
        # `#apply_attr_multiplier`/`#varied` independently, so a Cure spell
        # restoring both HP and SP could land two different randomized
        # amounts (and burn two RNG draws) where the ported reference always
        # lands the identical one off a single draw -- `stat_amount` never
        # even got the attribute multiplier at all, only hp/mp did.
        effect = hp != 0 ? hp : (mp != 0 ? mp : (cmd[:stat_effect] || 0))
        effect = apply_attr_multiplier(effect, cmd[:attributes], target)
        effect = varied(effect, cmd[:variance]) if @variance && cmd[:variance] && cmd[:variance] > 0
        # Same hard cap on a reference implementation's one
        # shared `effect` (clamped to a max damage value right after the
        # skill effect is computed, before
        # any affect_* branch reads it), ported and NOT independently
        # confirmed against genuine RPG_RT under wine -- applied once here for
        # the same reason, rather than separately per field afterward (which
        # previously left `mp` uncapped entirely).
        rcap = recover_cap
        effect = rcap if effect > rcap
        hp = effect if hp != 0
        mp = effect if mp != 0
        stat_amount = effect
        before_hp = target.hp
        before_mp = target.mp || 0
        # Each affected field rolls its own, independent accuracy check --
        # ported from a reference implementation's own fresh accuracy roll
        # inside each of `affect_hp`/`affect_sp`'s own `if`, not once for the
        # whole skill (#skill_effect_hits?), NOT independently confirmed
        # against genuine RPG_RT under wine. A skill that restores HP and SP alike can
        # therefore land one and miss the other. The HP write itself is
        # skipped entirely on an already-dead target -- ported from a
        # reference implementation's own HP-effect handling, NOT independently
        # confirmed against genuine RPG_RT under wine: it is a hard no-op
        # (an already-dead target's affected HP resolves to 0) before it ever reaches its own
        # accuracy roll, never adding the skill's heal onto a corpse's raw
        # (possibly deeply negative, nothing floors HP at 0 mid-fight)
        # HP total -- reviving is handled entirely by the cure step below.
        was_dead = target.dead?
        # Whether this same hit's own cure list includes Death -- the one
        # thing that may still affect an already-dead target at all. Ported
        # from EasyRPG Player's source, NOT independently confirmed against
        # genuine RPG_RT under wine: its Game_BattleAlgorithm::vExecute makes
        # every one of its affect_hp/affect_sp/state-cure branches a hard
        # no-op against a target that `!Exists()` unless the hit also
        # revives it first. #command_targets_dead_ok? already keeps an
        # ordinary Skill from ever reaching this branch with a dead target
        # unless it cures Death -- but an Item's own #command_targets_dead_ok?
        # is unconditionally true (`Item::IsTargetValid` ignores the
        # target's state entirely), so a status-curing item (an Antidote,
        # say) used on a downed ally could still reach here without
        # reviving it. Currently unreachable in practice:
        # `Scene::Battle#battle_ally_targets` excludes every dead ally from
        # item/skill targeting in battle at all (a separate,
        # already-documented deferred gap) -- fixed here anyway as defense
        # in depth in this shared method itself, not only at the outer
        # target-selection layer.
        cures_death = (cmd[:cured] || []).include?(Game::States::DEATH_ID)
        target.hp = [target.hp + hp, target.max_hp].min if hp > 0 && !was_dead && skill_effect_hits?(cmd)
        target.mp = [before_mp + mp, target.max_mp].min if mp > 0 && target.max_mp && skill_effect_hits?(cmd) && (!was_dead || cures_death)
        # Cure the target's status conditions, routed through #cure_state
        # (like the attack branch's own `cured.each` above) so curing Death
        # also sets HP to 1 the same way every other cure site in this class
        # does. Rolled the same `skill_effect_hits?(cmd)` per-state check the
        # attack branch's own cure just above uses -- this branch is shared
        # by both a recovery Skill and an Item (#apply_command's own
        # `cmd[:hp]`/`cmd[:cured]` machinery, fed by #command_item /
        # #command_skill alike), and a reference implementation genuinely
        # treats the two differently here (ported from its source, NOT
        # independently confirmed against genuine RPG_RT under wine): a
        # Skill's own execution
        # gates every cured state behind its
        # own fresh accuracy roll, while an Item's own execution
        # cure loop rolls nothing at all (a bare `for` loop over the item's
        # flagged states calling its own state-remove helper unconditionally
        # on each) -- reusing
        # `skill_effect_hits?` here is correct for both, since an Item
        # command never sets `cmd[:chance]` at all (only a Skill's own
        # `#battle_skill_command` does), and the helper's own `cmd[:chance]
        # || 100` fallback makes an absent chance an unconditional hit,
        # exactly matching Item's own roll-free cure.
        cured = (was_dead && !cures_death) ? [] : (cmd[:cured] || []).select { |s| target.state?(s) && skill_effect_hits?(cmd) }
        cured.each { |s| cure_state(target, s) }
        # A revival (this skill's own cure just took Death off the target)
        # layers a heal on top of that HP-to-1 instead of the heal being
        # skipped above -- ported from a reference implementation's own
        # two-step mechanism, NOT
        # independently confirmed against genuine RPG_RT under wine:
        # a revival that just cleared Death applies (affected HP - 1) on top
        # -- `ChangeHp`'s own non-lethal floor (`req_new_hp = std::max(1,
        # req_new_hp)`) is why this reads `[.., 1].max` below rather than
        # simply adding `affected_hp - 1`. A revival item with no heal
        # configured (`hp` 0, and no `cmd[:stat_effect]` at all -- items
        # never set it) lands on exactly 1, matching #cure_state's own bare
        # revival fallback used everywhere else.
        #
        # `affected_hp` is `hp` itself when the skill's own Affect HP flag
        # was on (`hp` already the correct, gated magnitude) -- but a
        # revival *skill* with Affect HP off (a common "cure Death, heal a
        # % of max HP" design, distinct from a flat-amount reviver, which
        # would check Affect HP) forces `hp` to 0 in #battle_skill_command
        # regardless of the skill's own Power/rate, and a reference
        # implementation's own skill-execution handling reads a *percentage*
        # in that exact case instead
        # of the flat-1 floor (ported from its source, NOT independently
        # confirmed against genuine RPG_RT under wine): `if (IsRevived() && effect > 0) { if
        # (skill.affect_hp) { SetAffectedHp(std::max(0, effect)); } else {
        # SetAffectedHp(target->GetMaxHp() * effect / 100); } }` --
        # `effect` there is the skill's own raw, un-gated magnitude
        # (its own skill-effect calculation, before any affect_hp gating), matching
        # this codebase's `cmd[:stat_effect]` (`#battle_skill_command`'s own
        # `base`, already the ATK/DEF/SPI/AGI stat-mod's identical raw
        # figure). `hp` being 0 with `cmd[:stat_effect]` positive can only
        # happen when Affect HP was off (an on-flag skill's own `hp` already
        # equals `stat_effect`'s scaled figure whenever it's nonzero), so no
        # separate flag has to ride along in `cmd` to tell the two apart.
        # A reference implementation's own separate skill-cast handling
        # implements the identical rule for the
        # out-of-battle/menu skill-cast path independently, that source
        # treating this as a general mechanic rather than a battle-only
        # quirk -- though only the battle path is fixed here, and none of
        # this is independently confirmed against genuine RPG_RT under wine.
        if was_dead && !target.dead?
          affected_hp = hp
          if affected_hp.zero? && (cmd[:stat_effect] || 0) > 0 && target.max_hp
            affected_hp = target.max_hp * cmd[:stat_effect] / 100
          end
          revived = target.hp + (affected_hp - 1)
          revived = 1 if revived < 1
          target.hp = target.max_hp ? [revived, target.max_hp].min : revived
        end
        # An RPG2003 reverse_state_effect ally/self-scoped skill flips
        # #battle_skill_command's own `cmd[:inflict]` on instead of `cmd[:cured]`
        # (see its comment) -- roll it here the same way an attack skill does,
        # so e.g. a self-scoped Berserk can confuse its own caster rather than
        # only ever curing states on this branch.
        inflicted, already = target.dead? ? [[], []] : roll_inflict(target, cmd)
        shifted = target.dead? ? [] : apply_attr_shift(target, cmd)
        stat_keys = target.dead? ? [] : (cmd[:stat_mod_keys] || []).select { skill_effect_hits?(cmd) }
        stat_changed = target.dead? ? {} : apply_stat_mods(target, stat_keys, stat_amount)
        { recover: true, actor: b.name, source: cmd[:name],
          item_id: cmd[:item_id], skill_id: cmd[:skill_id], target: target.name,
          target_index: @enemies.index(target),
          recover_hp: target.hp - before_hp, recover_mp: (target.mp || 0) - before_mp,
          cured: cured, inflicted: inflicted, already: already,
          target_ally: ally?(target), attr_shifted: shifted,
          attr_shift_dir: cmd[:attr_shift],
          stat_changed: stat_changed, switch_id: cmd[:switch_id],
          target_hp: target.hp, target_mp: target.mp }
      end
    end

    # Shift `target`'s attribute-defence ranks per `cmd[:attr_shift]` (see
    # #skill_attr_shift): one step per landing, capped at +-1 from the rank
    # the battle started with (Combatant#attr_base_ranks) rather than
    # stacking further on repeat casts, and always inside the valid 0..4
    # (A..E) range. Returns the attribute ids actually moved -- an attribute
    # already at its cap, or a skill that doesn't touch attribute defence at
    # all, moves nothing.
    #
    # A reference implementation rolls its own independent hit chance per
    # targeted attribute id
    # here (ported from its skill-execution handling, NOT
    # independently confirmed against genuine RPG_RT under wine):
    # its own `to_hit_attribute_shift` percent-chance roll inside the `for` loop over
    # `skill.attribute_effects`, evaluated separately for every `id` even
    # though every id shares the same skill-wide `to_hit`) -- the same
    # "rolled fresh per affected field" idiom `#skill_effect_hits?` already
    # gives `stat_mod_keys` above (see its doc comment), reused verbatim here
    # rather than applying the shift unconditionally to every id the skill
    # lists.
    def apply_attr_shift(target, cmd)
      shift = cmd[:attr_shift]
      ids = cmd[:attr_ids]
      return [] unless shift && ids && !ids.empty?
      target.attr_ranks ||= {}
      base = target.attr_base_ranks || {}
      moved = []
      ids.each do |aid|
        next unless skill_effect_hits?(cmd)
        b = Game.clamp(base[aid] || 2, 0, 4)
        cur = target.attr_ranks[aid] || b
        nxt = Game.clamp(cur + shift, Game.clamp(b - 1, 0, 4), Game.clamp(b + 1, 0, 4))
        next if nxt == cur
        target.attr_ranks[aid] = nxt
        moved << aid
      end
      moved
    end

    # RPG2000's default state rate table (liblcf's RPG::State defaults): a
    # susceptibility rank of A..E (index 0..4) scales an infliction chance to
    # 100 / 80 / 60 / 30 / 0 percent. Used as the fallback; a state row that
    # carries its own `a_rate` .. `e_rate` (the `situation` table) overrides it.
    STATE_RATE_PCT = [100, 80, 60, 30, 0].freeze

    # The percentage a susceptibility `rank` (0..4) scales an infliction of state
    # `sid`: the state's own `a_rate` .. `e_rate` from the situation table when
    # known, else the RPG2000 default table.
    def state_rate(sid, rank)
      row = state_def(sid)
      if row && row.respond_to?(:a_rate)
        r = [row.a_rate, row.b_rate, row.c_rate, row.d_rate, row.e_rate][rank]
        return r if r
      end
      STATE_RATE_PCT[rank]
    end

    # The percentage a target's susceptibility scales an infliction of `sid`: its
    # rank in the target's `state_ranks`, defaulting (for a state id the array
    # doesn't cover -- routine, since liblcf/RPG_RT truncate trailing default
    # bytes off it) to C / 60% for an actor or B / 80% for an enemy. A
    # reference implementation models this as two distinct functions with two
    # distinct defaults, ported from that source and not independently
    # confirmed against genuine RPG_RT under wine -- not one shared default
    # the way this used to read.
    # `#ally?` is the same actor-vs-enemy tell `Battle` already uses elsewhere
    # (only an actor-built Combatant, #from_actor, carries a live `actor`).
    # 100 (unscaled) when the target (a bare fixture) models no ranks at all,
    # so a plain sim keeps landing every status.
    # The Knockout state (id 1, `Game::Actor::DEATH_STATE`) is scaled exactly
    # like any other state, despite an uncited yado.tk claim this codebase
    # used to carry (and special-case) that its infliction chance was governed
    # solely by the skill's own occurrence-rate operand, never reduced by the
    # target's A-E resistance rank. Ported from a reference implementation's
    # source, NOT independently confirmed against genuine RPG_RT under wine:
    # its per-actor and per-enemy state-probability functions have no
    # `state_id == kDeathID` special case at all, and both of
    # `Game_BattleAlgorithm`'s infliction call sites -- the Skill state-effect
    # loop and the weapon `state_set` loop --
    # call `target->GetStateProbability(state_id)` uniformly for every flagged
    # state id, checking `state_id == kDeathID` only *after* a successful roll
    # (to track whether the target just died), never to skip the roll itself.
    # An ally's own defensive equipment can scale the A-E result down further
    # still -- see Actor#state_resist_mul.
    def state_susceptibility(target, sid)
      ranks = target.state_ranks
      return 100 if ranks.nil? || ranks.empty?
      is_ally = ally?(target)
      default_rank = is_ally ? 2 : 1
      rank = ranks[sid] || default_rank
      rank = 0 if rank < 0
      rank = 4 if rank > 4
      pct = state_rate(sid, rank)
      # An ally's equipped shield/armor/helmet/accessory can further resist a
      # state landing on top of its A-E rank -- see Actor#state_resist_mul.
      # Enemies equip nothing, matching Game_Enemy::GetStateProbability's own
      # rank-only formula (no equipment scan at all). `respond_to?` tolerates
      # a bare test double standing in for `actor` (#ally? only cares that the
      # field is non-nil), read as full resistance (100, a no-op multiplier).
      if is_ally && target.actor.respond_to?(:state_resist_mul)
        pct = pct * target.actor.state_resist_mul(sid) / 100
      end
      pct
    end

    # Add a state to `target`, applying the inseparable Knockout
    # side effect the instant the state added is id 1 -- ported from
    # a reference implementation's own add-state handling, NOT independently
    # confirmed against genuine RPG_RT under wine: landing Knockout
    # unconditionally zeroes HP,
    # an unconditional side effect fired from *every* battle-time
    # infliction path alike (a skill's own state-effect list, a weapon's
    # `state_set`, Change Monster Condition -- all three route through this
    # one function). It is not something `#dead?` merely inspects after the
    # fact; landing the state *is* what knocks the target out.
    # `Game::Actor#add_state` already carries the identical rule for the
    # field/menu path -- this is its `Combatant` counterpart. Also applies
    # the same crowding-out rule a reference implementation's engine
    # implements (`Game::States::PRUNE_GAP`): the state that
    # just landed may itself immediately push out one already held, or be
    # pushed out by one already held that outranks it.
    # The Knockout state landing resets more than HP -- ported from
    # a reference implementation's own source, NOT independently confirmed
    # against genuine RPG_RT under wine:
    # its add-state Knockout branch resets the active-time gauge, HP, all
    # four ATK/DEF/SPI/AGI modifiers, the defending and charged flags, and
    # any attribute-shift state,
    # fired the instant the state lands, from *every* path that can inflict
    # it -- an ordinary lethal hit (`ChangeHp` calls `AddState(kDeathID,
    # true)` itself once `new_hp <= 0`), a skill/weapon's own state-effect
    # list, Change Monster/Actor Condition, all alike. This method ports
    # the fields with no other reset path once a fight is already
    # under way: the active-time gauge (`#gauge`), the persistent per-battle
    # ATK/DEF/SPI/AGI modifiers a buff/debuff skill accumulates onto
    # (`#atk_mod`/`#def_mod`/`#spi_mod`/`#agi_mod`, see #apply_stat_mods --
    # `SetAtkModifier(0)` and siblings), and any attribute-defence rank
    # shift a skill has applied (`#attr_ranks`, see #apply_attr_shift --
    # `attribute_shift.clear()`, matched here by resetting to an empty
    # Hash, which every reader already treats identically to "no shift"
    # via its own `ranks[aid] || 2`/`base[aid] || 2` fallback).
    # ~~`#defending`/`#charged` (`SetIsDefending`/`SetCharged`) are
    # deliberately not ported: this codebase already resets both to false
    # at the start of every command a battler is given, dead or not, so
    # there is no gap for a Knockout-time reset to close there.~~
    # Corrected (2026-08-21): that is only true for an *ally* — `#end_round`
    # unconditionally clears both for every entry in `@allies` regardless of
    # whether it acted that round, but never touches `@enemies` at all, and
    # an *enemy's* own `#defending` reset (`#strike`'s `b.defending = false`)
    # only fires at the start of *that enemy's own next turn* -- not
    # immediately at death the way real RPG_RT's `AddState` does -- and its
    # `#charged` flag is never reset at all short of actually being consumed
    # by a subsequent charged attack. Between a revival mid-round and that
    # enemy's own next turn, a stale `#defending` wrongly halves incoming
    # damage from other battlers' actions, and a stale `#charged` wrongly
    # doubles the revived enemy's own next attack -- both real divergences
    # this ported behavior's immediate, unconditional reset at death closes.
    # Fixed below by porting the two fields after all.
    #
    # Distinct from `Actor#atb_gauge`'s own cross-*battle* persistence fix
    # (`#apply_to_party` writing back 0 for an ally who ended the *fight*
    # dead): this is the same family of resets but at the moment of death
    # itself, mid-fight -- without it, an ally buffed (or debuffed) by an
    # ordinary ATK/DEF/SPI/AGI-affecting skill, or charged to near-full
    # gauge, who dies and is then revived by an ordinary Full Heal/revival
    # skill within the same fight would fight on with that stale pre-death
    # modifier/charge still active instead of the clean slate this ported
    # behavior gives a revived battler. Called from every place a `Combatant`'s HP
    # can newly reach 0 (this method, and the three raw `hp -=` sites in
    # #deal_attack_with_current_weapon, #apply_skill_hit and
    # #enemy_autodestruct) -- calling it again on an already-dead target is
    # a harmless no-op, matching a corpse's own stats always reading the
    # same reset values whether checked once or many times.
    def apply_knockout_reset(target)
      return unless target.dead?
      target.gauge = 0 if target.respond_to?(:gauge)
      %i[atk_mod def_mod spi_mod agi_mod].each do |field|
        target.send("#{field}=", 0) if target.respond_to?(field)
      end
      target.attr_ranks = {} if target.respond_to?(:attr_ranks=)
      target.defending = false if target.respond_to?(:defending=)
      target.charged = false if target.respond_to?(:charged=)
    end

    # `target`'s live RPG2003 cursed-armor-forced states (`Actor
    # #permanent_states`), or `[]` for an enemy Combatant (no `:actor` field
    # at all) -- ported from a reference implementation's own split, NOT
    # independently confirmed against genuine RPG_RT under wine: an actor's
    # own permanent-states function is overridden with the cursed-armor set,
    # while the shared base implementation (which the enemy side
    # never overrides) always returns empty, so a
    # monster never carries one at all. `#inflict_state`/`#cure_state` need
    # this the same way every one of a reference implementation's own
    # battle-algorithm subclasses' state
    # mutations do -- `target_perm_states = target->GetPermanentStates()`,
    # threaded into every in-battle state add/remove,
    # not just the field-side equivalents
    # (`Actor#knock_out!`, `Party#cast_skill`, `Interpreter#
    # do_change_condition`) this codebase already fixed.
    def combatant_permanent_states(target)
      actor = target.respond_to?(:actor) ? target.actor : nil
      actor && actor.respond_to?(:permanent_states) ? actor.permanent_states : []
    end

    # A newly-inflicted state that leaves `target` under a forced-action
    # restriction (do-nothing/berserk/confusion, #battler_restriction) also
    # drops its Defend stance and any charged-attack flag, matching a
    # reference implementation's own `AddState`, NOT independently confirmed
    # against genuine RPG_RT under wine: it resets both unconditionally
    # whenever the post-add significant restriction is non-normal, not only
    # on death (`apply_knockout_reset`'s own, narrower death-only reset is a
    # separate case already covered there). No equivalent reset for a queued
    # command/battle-algorithm is needed here: this codebase already
    # re-derives a restricted battler's action at round-execution time
    # instead of caching one to invalidate (#command_restricted?'s own doc
    # comment).
    def inflict_state(target, sid)
      return if target.state?(sid)
      target.states = Game::States.prune((target.states || []) + [sid], @states,
                                          keep: combatant_permanent_states(target))
      target.hp = 0 if sid == Game::States::DEATH_ID
      apply_knockout_reset(target)
      if battler_restriction(target) != 0
        target.defending = false if target.respond_to?(:defending=)
        target.charged = false if target.respond_to?(:charged=)
      end
    end

    # Cure a state from `target`, reviving it to 1 HP when curing state 1 is
    # what actually took it off the downed list -- the mirror image of
    # #inflict_state's own HP-zeroing side effect. Ported from a reference
    # implementation's own state-removal handling, NOT independently confirmed
    # against genuine RPG_RT under wine: it snapshots whether the battler carries
    # `kDeathID` before the removal and sets HP to 1 the instant that flips
    # to false afterward -- since removing any *other* id can never change
    # whether `kDeathID` is still carried, checking `sid` itself is an
    # equivalent, simpler test for the same transition.
    #
    # A state one of `target`'s worn cursed items is still actively forcing
    # cannot be cured this way either -- a reference implementation's own
    # state-removal handling hard-refuses exactly like
    # it does for `Actor#remove_state`'s own already-ported lock; unlike
    # that method, this one has no `always_remove_battle_states:`
    # equivalent to bypass it with, since that reference implementation's own
    # in-battle callers never pass one either.
    def cure_state(target, sid)
      return unless target.state?(sid)
      return if combatant_permanent_states(target).include?(sid)
      target.states = (target.states || []) - [sid]
      # Clear the per-state turn counter too, the same idiom
      # #shake_off_states already uses for its own release path -- ported
      # from a reference implementation's own state add/remove handling, NOT
      # independently confirmed against genuine RPG_RT under wine: they share one
      # literal field for "state present" and "turns held"
      # (`states[state_id - 1] = 1` on Add, `st = 0` on Remove;
      # a reference implementation's own turn-heal pass increments
      # that same field each turn), so a cured-then-reinflicted state can
      # never inherit a stale duration there. `#apply_turn_states`'s own
      # `state_turns` hash tracks it separately here and is only ever
      # incremented, never reset on infliction (`#inflict_state` touches
      # `states`/`hp` only) -- leaving a stale entry behind would make a
      # state re-inflicted later in the same fight eligible for its
      # auto-release roll far too early, sometimes on the very next tick.
      target.state_turns.delete(sid) if target.state_turns
      target.hp = 1 if sid == Game::States::DEATH_ID
    end
    public :inflict_state, :cure_state, :apply_knockout_reset

    # Inflict a skill command's `inflict` states on `target`, each landing only if
    # a 0..99 roll comes in under the skill's `chance` (its accuracy) scaled by
    # the target's per-state susceptibility.
    #
    # Returns `[inflicted, already]`: the states that landed, and the ones the
    # target was already carrying. The second list is not a list of failures —
    # RPG_RT counts a state the target already has as a **success** and says so
    # ("X is already poisoned!"), *without* rolling the accuracy first
    # (ported from a reference implementation's already-inflicted handling,
    # which skips the accuracy roll entirely, not independently confirmed
    # against genuine RPG_RT under wine). A Poison Sting on a poisoned foe therefore
    # always reports, where a roll would sometimes have gone quiet.
    def roll_inflict(target, cmd)
      chance = cmd[:chance] || 100
      inflicted = []
      already = []
      (cmd[:inflict] || []).each do |sid|
        if target.state?(sid)
          already << sid
          next
        end
        prob = chance * state_susceptibility(target, sid) / 100
        next unless @rng.random(100) < prob
        inflict_state(target, sid)
        inflicted << sid
      end
      [inflicted, already]
    end

    # A basic Attack's own weapon-granted states (`b.atk_states`, see
    # Game::Actor#weapon_states), rolled the same way #roll_inflict rolls a
    # skill's: each inflict-side state scaled by the target's own
    # susceptibility, each heal-side state (RPG2003's `reverse_state_effect`
    # weapons only) an unscaled roll against the weapon's own chance --
    # a reference implementation's weapon block never calls the state-
    # probability check for the heal side, only the inflict side, ported
    # from that source and not independently confirmed against genuine
    # RPG_RT under wine.
    #
    # Unlike a skill (#roll_inflict's `already`), a weapon that flags a state
    # the target already carries does **nothing** and reports nothing --
    # documented in a reference implementation's own comment: "weapons do not
    # try to reinflict states already present," ported from that source and
    # not independently confirmed against genuine RPG_RT under wine. No
    # `already` list here for that reason.
    #
    # Returns `[inflicted, healed]`.
    def roll_weapon_states(b, target)
      states = b.respond_to?(:atk_states) ? b.atk_states : nil
      return [[], []] unless states
      inflicted = []
      (states[:inflict] || {}).each do |sid, chance|
        next if target.state?(sid)
        prob = chance * state_susceptibility(target, sid) / 100
        next unless @rng.random(100) < prob
        inflict_state(target, sid)
        inflicted << sid
      end
      healed = []
      (states[:heal] || {}).each do |sid, chance|
        next unless target.state?(sid)
        next unless @rng.random(100) < chance
        cure_state(target, sid)
        healed << sid
      end
      [inflicted, healed]
    end
  end
end

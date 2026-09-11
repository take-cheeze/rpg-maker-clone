# Battle-only helpers dropped from mrblib/game.rb wio's own battle exclusion
# left dead: everything here is called only from mruby-rpg2k/mrblib/game/
# battle.rb, mruby-rpg2k/mrblib/scene/battle.rb, mruby-rpg2k/mrblib/scene/
# battle_rpg2k3.rb (already dropped from the wio build, see mrbgem.rake) or
# mruby-rpg2k/mrblib/scene/map_viewer.rb (dropped for the same reason since
# ADR 0097) -- confirmed by grepping every real (non-comment, non-CRuby-
# test-script) call site of each method/class moved here before it moved.
# `Dir.glob(...).sort` loads this file after mrblib/game.rb regardless of
# target (`game.rb` < `game/battle_support.rb` lexically), so every one of
# these reopened classes/modules already exists by the time this file's own
# class bodies run. See docs/adr/0124-rpg2k-battle-only-helpers-trim.md.

module Game
  class Actor
    # Whether the actor is still standing (a live party member).
    def alive?; !dead?; end

    # Replace the state set (Continue restoring the saved conditions). The saved
    # HP is authoritative and restored separately, so this assigns without the
    # HP-coupling side effects.
    def states=(ids)
      @states = (ids || []).reject { |s| s.nil? || s == 0 }.uniq
    end

    # Whether any equipped item guards against critical hits (the armour
    # `prevent_critical` flag, item field 25). A database with no item table
    # (the test fixtures) or an item lacking the flag contributes nothing.
    def prevents_critical?
      return false unless @db.respond_to?(:item)
      @equipment.any? do |iid|
        next false if iid.nil? || iid == 0
        it = @db.item[iid]
        it && it.respond_to?(:prevent_critical) && it.prevent_critical
      end
    end

    # The strongest defensive resistance the actor's equipped shield / armor /
    # helmet / accessory (never a weapon) offers against state `sid` landing,
    # as a percent multiplier (100 = no resistance). Ports a reference
    # implementation's own state-probability routine (NOT independently confirmed against
    # genuine RPG_RT under wine): an item that
    # flags `sid` in its own `state_set` contributes `100 - state_chance`, and
    # the *lowest* (strongest) contribution across every equipped defensive
    # item wins -- "takes the armor of the character with the most resistance
    # for that particular state", not a sum of every piece worn. An RPG2003
    # item with `reverse_state_effect` set plays no part here (that flag turns
    # a *weapon's* own states into cures, per #weapon_states -- it has no
    # meaning on defensive gear's state_set), matching a reference
    # implementation's own equivalent edition/flag guard (ported from that
    # source, NOT independently confirmed against genuine RPG_RT under wine).
    def state_resist_mul(sid)
      mul = 100
      return mul unless @db.respond_to?(:item)
      is2k3 = rpg2003?
      @equipment.each do |iid|
        next if iid.nil? || iid == 0
        it = @db.item[iid]
        next unless it && it.respond_to?(:type) &&
                    [Party::ITEM_SHIELD, Party::ITEM_ARMOR, Party::ITEM_HELMET,
                     Party::ITEM_ACCESSORY].include?(it.type)
        next if is2k3 && it.respond_to?(:reverse_state_effect) && it.reverse_state_effect
        set = it.respond_to?(:state_set) ? it.state_set : nil
        next unless set && set[sid - 1] && set[sid - 1] != 0
        chance = it.respond_to?(:state_chance) ? (it.state_chance || 0) : 0
        mul = 100 - chance if 100 - chance < mul
      end
      mul
    end

    # The battle animation a basic Attack plays with this actor's current gear:
    # the primary weapon slot's own `animation_id` (item field 20 -- the
    # weapon editor's own "アニメーション" picker; the same field
    # Scene::Map#battle_animation_id already reads off a *used* skill/item,
    # reused here for a weapon's normal-attack swing) when one is worn and set,
    # or the actor row's `unarmed_animation` (field 56, 素手戦闘アニメID)
    # otherwise -- RPG2000 has no equivalent monster-side field (an enemy's
    # Attack plays no animation at all), so this is Actor-only by design, not
    # an oversight. Only the primary slot is read: RPG_RT keeps this as one
    # property per actor rather than one per weapon, and a 二刀流 actor's
    # second swing (the shield-slot weapon #attack_hit_rate's own scan already
    # picks up for hit/crit) plays the identical animation as the first, so
    # there is nothing here for that second weapon to override.
    def attack_animation_id
      iid = @equipment[WEAPON_SLOT]
      if iid && iid != 0 && @db.respond_to?(:item)
        it = @db.item[iid]
        if it && it.respond_to?(:type) && it.type == ITEM_WEAPON &&
           it.respond_to?(:animation_id) && it.animation_id && it.animation_id > 0
          return it.animation_id
        end
      end
      @db_row.respond_to?(:unarmed_animation) ? @db_row.unarmed_animation : nil
    end

    # 必中 — an equipped weapon whose attack cannot be evaded. Ported from
    # a reference implementation's own to-hit calculation; confirmed against
    # genuine RPG_RT under wine, 2026-09-05: a hand-authored hit-90 weapon
    # against an agi-999 target (whose evasion alone clamps #to_hit's own
    # agi_adjusted formula to ~0%) landed 0 of 5 attacks without this flag
    # and 2 of 3 with it -- it returns before it applies the agility /
    # evasion term for such a weapon, exactly as ported. 13 of Nepheshel's
    # weapons carry it.
    def ignores_evasion?; equipment_flag?(:ignore_evasion, true); end

    # 全体化 — an equipped weapon whose own flag genuine RPG_RT reads (see
    # Game::Battle#strike), but does NOT actually spread a basic Attack
    # across every living member of the target's side: confirmed by an
    # actual wine capture (2026-09-05) that a reference implementation's own
    # "attack all enemies regardless of original targeting" claim does not
    # hold for genuine RPG_RT.exe, matching the already-confirmed
    # forced-restriction case (a berserk/confused attacker with this same
    # flag also only ever hits the one forced target). See #strike's own
    # citation for the fixture details.
    def attack_all?; equipment_flag?(:attack_all, true); end

    # 先制攻撃 — an equipped weapon that jumps its wielder's basic Attack to
    # the front of the round's turn order. Ported from a reference
    # implementation's own preemptive-attack / execution-order handling, NOT
    # independently confirmed against genuine RPG_RT under wine: it adds
    # 9999 to the battler's computed order for exactly this case —
    # effectively always first, since ordinary agility values never approach
    # that. Only a basic Attack earns the jump; a Skill, Item or Defend with
    # the same weapon still equipped keeps its ordinary agility slot,
    # matching that ported basic-attack-only guard.
    def preemptive?; equipment_flag?(:preemptive, true); end

    # The SP a basic Attack itself costs -- ported from a reference
    # implementation's own weapon-SP-cost routine, which
    # it spends unconditionally
    # once per action, before
    # any swing resolves -- not per swing, so a 二刀流 weapon's extra hit
    # (`#strike_count`) never doubles the bill. Confirmed against genuine
    # RPG_RT under wine (2026-09-05): a solo actor with max_mp/mp forced to
    # exactly 20 and a custom weapon whose own sp_cost field was set to 20
    # had mp read exactly 0 off the status panel immediately after a single
    # basic Attack (90% weapon hit, so the swing may or may not have
    # actually landed on its enemy target -- the deduction did not wait to
    # find out either way). The weapon there is whichever
    # slot governs the action's very first swing: the weapon-slot item alone
    # for a `#double_hand?` two-weapon actor (this engine's only route to a
    # real per-swing weapon split, since ordinary single-weapon gear always
    # combines both slots, which reduces to that one weapon's own cost anyway) --
    # `#equipped_weapons`' own weapon-slot-first ordering, so `.first` is
    # always the right item either way. Halved (rounding up, matching
    # `#skill_cost`'s own fixed-cost branch) by the same MP消費半分 gear. 0 for
    # an unarmed actor.
    def weapon_sp_cost
      it = equipped_weapons.first
      return 0 unless it
      cost = it.respond_to?(:sp_cost) ? (it.sp_cost || 0) : 0
      half_sp_cost? ? (cost + 1) / 2 : cost
    end

    # 物理回避率アップ — a shield/armour/helmet/accessory that makes a normal
    # attack likelier to miss its wearer: ported from a reference
    # implementation's own physical-evasion-up check, consulted right after
    # its AGI term in the to-hit calculation. Confirmed by an actual wine
    # capture (2026-09-05, see Game::Battle#to_hit's own citation) — the
    # ported behavior subtracts a flat 25 from the attacker's already
    # agi-adjusted hit chance. The weapon slot never counts — that check there
    # excludes weapons by item *type*, not slot index, the same
    # way #equip_bonus already reads every equipped slot, so a 二刀流 actor's
    # second weapon (sitting in the shield slot) is correctly excluded too.
    def physical_evasion_up?
      return false unless @db.respond_to?(:item)
      @equipment.any? do |iid|
        next false if iid.nil? || iid == 0
        it = @db.item[iid]
        next false unless it
        next false if it.respond_to?(:type) && it.type == ITEM_WEAPON
        it.respond_to?(:raise_evasion) && it.raise_evasion ? true : false
      end
    end

    def atb_gauge=(v); @atb_gauge = Game.clamp(v || 0, 0, Battle::GAUGE_MAX); end

    # Clear a combo Enable Combo armed, at a fight's end -- ported from
    # a reference implementation's own reset-battle routine, NOT independently confirmed
    # against genuine RPG_RT under wine:
    # it resets the combo command id and multiplier to their unarmed
    # defaults, called for
    # every actor at both a battle's start and its end -- so a combo armed for
    # one fight never carries into the next. #set_battle_combo's own doc
    # comment already claimed the combo stays armed "until battle end", but
    # nothing actually enforced that boundary until this existed; see
    # `Game::Battle#apply_to_party`, the one place a fight's outcome is
    # written back onto the persistent Actor objects, for the call site.
    def clear_battle_combo
      @battle_combo = nil
    end

    # The renamed label itself (独自戦闘コマンド名称, field 67), read only when
    # #rename_skill? is set.
    def skill_command_name
      @db_row.respond_to?(:custom_battle_command_name) ? (@db_row.custom_battle_command_name || '') : ''
    end
  end

  class Party
    # Whether the database asks specifically for RPG2003's gauge battle-screen
    # presentation (`battlecommands.battle_type == 2`) -- distinct from
    # `#alternate_battle_layout?` above, which is also true for the plain
    # sprite-only layout (1). The party status panel reads this to know when
    # to replace its text status window with the gauge card layout (see
    # scene/battle.rb's `#refresh_battle_status`); an alternative-layout (1)
    # database, or one with no `#battlecommands` table at all, reads false.
    def gauge_battle_layout?
      return false unless @db.respond_to?(:battlecommands)
      table = @db.battlecommands
      table && table.battle_type == 2 ? true : false
    end

    # RPG2003's battle-sprite placement choice (`battlecommands.placement`,
    # chunk 29 field 2 -- 0 manual, 1 automatic; see schema.rb). Manual is
    # `Game::Actor#battle_x`/`#battle_y` read as literal screen coordinates;
    # automatic computes a grid formula (a reference implementation's own
    # base-grid-position / 2k3-battle-position calculation, ported in
    # scene/battle.rb's #automatic_battle_position, NOT independently
    # confirmed against genuine RPG_RT under wine) keyed by party index/size
    # and the encounter terrain. A bare test fixture with
    # no `#battlecommands` table, or an RPG2000 database (which never sets
    # this field), reads false/manual, same as `#alternate_battle_layout?`.
    def automatic_battle_placement?
      return false unless @db.respond_to?(:battlecommands)
      table = @db.battlecommands
      table && table.respond_to?(:placement) && table.placement == 1 ? true : false
    end

    # Whether an enemy AI's own self/ally/troop-scope skill action `sk` could
    # possibly help anyone on `caster`'s side (`troop`, its full battle Combatant
    # roster including out-of-play members) -- ported from a reference
    # implementation's own enemy-AI target-effectiveness checks, NOT
    # independently confirmed against genuine RPG_RT under wine, which it
    # believes the real engine consults before letting an
    # AI-selected skill enter its weighted draw at all: an enemy-scope skill
    # (0 single enemy / 1 all enemies, aimed at the *party*) is always
    # considered worth trying -- RPG_RT never checks whether the party side
    # could be affected -- so only scope 2/3/4 (self/single ally/all allies,
    # always the caster's own troop) is filtered here, against `caster` alone
    # for scope 2 or every troop member for 3/4 (the real engine does not
    # distinguish single- from all-ally scope for this purpose, since a single
    # target is chosen only after an action is already selected). This port
    # always runs the *actual* RPG_RT behaviour (that source's own "emulate
    # the authentic bugs" mode
    # -- its alternate bug-fixed "RPG_RT+" algorithm is never selected here,
    # matching every other "authentic engine vs. improved-variant"
    # choice elsewhere in this file), which collapses two of the ported
    # function's branches to their `emulate_bugs` side outright: a
    # Knockout-flagged (state id 1, a revival) skill reads as effective on any
    # hidden/downed troop member purely from the flag being set -- an
    # authentic bug, ignoring `reverse_state_effect` and whether the target is
    # actually the one that is dead -- and an RPG2003 ally-scope skill with
    # `reverse_state_effect` set (see `#battle_skill_command`'s `heals_states`)
    # is checked by whether the target already *has* the state, the same as
    # an ordinary cure, rather than by whether inflicting it would do
    # anything.
    def skill_helps_troop?(sk, caster, troop)
      return true unless Party.normal_skill?(sk)
      scope = sk.respond_to?(:scope) ? sk.scope : 0
      return true if scope == 0 || scope == 1
      targets = scope == 2 ? [caster] : troop
      states = skill_state_ids(sk)
      targets.any? do |t|
        next false unless t
        if t.out_of_play?
          states.include?(1)
        else
          sk.affect_hp || sk.affect_sp || !skill_stat_mod_keys(sk).empty? ||
            states.any? { |sid| t.state?(sid) } ||
            (sk.respond_to?(:affect_attr_defence) && sk.affect_attr_defence && !skill_attributes(sk).empty?)
        end
      end
    end

    # -- Battle-context skill / item use --------------------------------------
    #
    # The on-screen battle commands work on Game::Battle::Combatant snapshots but
    # reuse the field menu's cost / effect formulas (#skill_cost, #skill_effect,
    # #item_recovery). Scope is single-target for now: an attack skill hits one
    # enemy, a recovery skill / medicine restores one ally (or the caster). The
    # all-target scopes (1 all enemies, 4 all allies) and the battle SP / damage
    # variance are later refinements.

    # Battle skill scopes the menu offers: 0 single enemy, 1 all enemies, 2 the
    # caster, 3 a single ally, 4 all allies.
    BATTLE_SKILL_SCOPES = [0, 1, 2, 3, 4].freeze

    # `actor`'s known skills usable in battle, as `[skill_id, cost]` pairs in
    # ascending id order: those flagged `occasion_battle` that either behave as an
    # ordinary skill with a scope the battle menu can aim, or are a **switch**
    # skill (no target — Nepheshel's 突撃準備 / 呪文詠唱 charge-ups are these).
    # `caster` is the battle snapshot the SP cost is figured from.
    def battle_skills(actor, caster)
      return [] unless actor && caster
      actor.skills.sort.select { |sid| battle_skill?(db_skill(sid)) }
           .map { |sid| [sid, skill_cost(db_skill(sid), caster)] }
    end

    # Whether skill row `sk` belongs in the battle menu. Mirrors #field_skill?:
    # the occasion flags gate switch skills only, an escape / teleport skill is
    # never usable in a fight, and an ordinary skill always is — RPG_RT asks
    # nothing else of it once a battle is running.
    def battle_skill?(sk)
      return false unless sk
      case sk.type
      when SKILL_ESCAPE, SKILL_TELEPORT then false
      when SKILL_SWITCH then battle_occasion?(sk)
      else BATTLE_SKILL_SCOPES.include?(sk.scope)
      end
    end

    # Whether a **switch** skill's battle occasion flag is set (see
    # #field_skill? for why only switch skills consult these). Defaults to usable
    # when the row (a bare fixture) carries no flag.
    def battle_occasion?(sk)
      sk.respond_to?(:occasion_battle) ? sk.occasion_battle : true
    end

    # Whom a battle skill targets: :enemy (scope 0), :all_enemy (1), :self (2),
    # :all_ally (4) or a single :ally (3, the default).
    def battle_skill_target(sk)
      case sk.scope
      when 0 then :enemy
      when 1 then :all_enemy
      when 2 then :self
      when 4 then :all_ally
      else :ally
      end
    end

    # A skill's state-infliction accuracy (its `hit` field, default 100), used as
    # the per-state roll when an attack skill inflicts its `state_effects`.
    # 吸収 (`absorb_damage`): the caster gains the HP the skill takes. 13 of
    # Nepheshel's skills and 5 of mtf-meido-action's set it, and nothing read it,
    # so every drain spell in both games was a plain attack spell.
    def skill_absorbs?(sk)
      sk.respond_to?(:absorb_damage) ? (sk.absorb_damage ? true : false) : false
    end

    # `sk.hit == -1` is a sentinel meaning "use the caster's own weapon-based
    # hit chance" rather than a fixed rate -- ported from a reference
    # implementation's own to-hit formula,
    # NOT independently confirmed against genuine RPG_RT under wine: it
    # reads it as its very first line, unconditionally, for
    # every skill (not gated behind any extension-only flag the way
    # the row terms a few lines further down are): the skill's own hit field,
    # or the caster's weapon-based hit chance when that field is the -1
    # sentinel. A `Combatant`
    # snapshot (every real caller today) already carries that merged figure
    # as its own `hit_rate` -- the same field `Game::Battle#to_hit` reads for
    # an ordinary Attack; a bare `Game::Actor`/`Game::Enemy`, should one ever
    # reach this, falls back to `Battle.hit_rate_of` instead, the identical
    # `attack_hit_rate`-reading helper a fresh `Combatant` is seeded from.
    def skill_hit(sk, source)
      return skill_hit_weapon_fallback(source) if sk.respond_to?(:hit) && sk.hit == -1
      sk.respond_to?(:hit) ? (sk.hit || 100) : 100
    end

    def skill_hit_weapon_fallback(source)
      return source.hit_rate || 90 if source.respond_to?(:hit_rate)
      Battle.hit_rate_of(source)
    end

    # A Skill's to-hit chance, ported from a reference implementation's own
    # to-hit formula,
    # NOT independently confirmed against genuine RPG_RT under wine. The overwhelming majority of skills use a flat
    # `skill.hit` reading (already what `skill_hit` returns), which ignores the
    # target's agility the way RPG_RT's non-physical skill formula does. Only an
    # *enemy-scope* skill the editor flagged with the "physical" failure message
    # (`failure_message == 3`) runs the fuller, agility-adjusted, evasion-aware
    # physical formula — RPG2000's own editor hides that flag, so in practice it
    # survives only from converted / hex-edited projects and a handful of 2k3
    # databases, but RPG_RT still honours the bit whenever it is set (see the
    # "Not implemented: CalcSkillToHit" note in docs/TODO.md). `source` is the
    # caster, `target` the first foe the skill lands on.
    # RPG2003 row accuracy does **not** extend to physical skills. A reference
    # implementation gates both its row hit and row damage terms
    # behind an extension-only field
    # the RPG Maker 2003 editor cannot set (absent from every real 2003 file),
    # so a vanilla skill is never row-adjusted -- only a basic attack (#to_hit /
    # #deal_attack on Game::Battle) is. A prior draft applied the same back-row
    # penalty a pre-reference guess had used for attacks; the reference settles
    # it: skills are untouched by rows. See ADR 0053/0054.
    def skill_to_hit(sk, source, target)
      return skill_hit(sk, source) unless sk.respond_to?(:failure_message) && sk.failure_message == 3
      # The physical formula is enemy-only: an ally/self-scoped skill (scope 2/3/4)
      # always falls back to the flat rate regardless of the flag — a reference
      # implementation guards the whole physical branch behind
      # an ally-scope check, and its own comment notes the 2k3 editor
      # can no longer even set the flag, so the branch is reached only by skills
      # that still target the opposing side (scope 0 single / 1 all enemy).
      scope = sk.respond_to?(:scope) ? sk.scope.to_i : 0
      return skill_hit(sk, source) unless scope == 0 || scope == 1

      to_hit = skill_hit(sk, source)
      # A do-nothing-restricted target cannot dodge: the attack always connects.
      return 100 if do_nothing_restricted?(target)
      # The caster's own statuses (e.g. Blind) sour its aim first, before the
      # agility term — the same ordering `Game::Battle#to_hit` already uses for a
      # basic attack.
      to_hit = to_hit * hit_modifier(source) / 100
      # 必中: a source that ignores evasion skips the agility term entirely.
      return to_hit if source.ignores_evasion
      src = effective_agi(source)
      src = 1 if src < 1
      tgt = effective_agi(target)
      agi_adjusted = 100 - (100 - to_hit) * (src + tgt) / (2 * src)
      # 物理回避率アップ: a shield/armour/helmet/accessory flagged
      # `raise_evasion` subtracts a flat 25, after the AGI term.
      agi_adjusted -= 25 if target.evasion_up
      Game.clamp(agi_adjusted, 0, 100)
    end

    # Whether any state afflicting `b` forces "do nothing" (restriction 1), in
    # which case it cannot dodge a physical skill. Mirrors
    # `Game::Battle#do_nothing_restricted?` but reads the state table through
    # this party's own `@db.situation` (a battle-skill's caster/target is
    # sometimes a bare Game::Actor with no Battle behind it, see Party#stat_mode).
    def do_nothing_restricted?(b)
      return false unless b.respond_to?(:states)
      (b.states || []).each do |sid|
        d = @db.respond_to?(:situation) ? @db.situation[sid] : nil
        return true if d.respond_to?(:restriction) && (d.restriction || 0) == 1
      end
      false
    end

    # How much `b`'s own statuses cut its accuracy: the lowest `reduce_hit_ratio`
    # among its states (matching a reference implementation's own running-min
    # helper, not independently confirmed against genuine RPG_RT under wine).
    # 100 means unhindered. Part of #skill_to_hit's physical
    # formula, mirroring `Game::Battle#hit_modifier`.
    def hit_modifier(b)
      m = 100
      return m unless b.respond_to?(:states)
      (b.states || []).each do |sid|
        d = @db.respond_to?(:situation) ? @db.situation[sid] : nil
        r = state_hit_ratio(d)
        m = r if r < m
      end
      m
    end

    # A state's `reduce_hit_ratio`, defaulting to 100 (no reduction) for an
    # unknown state or a fixture row without the field.
    def state_hit_ratio(d)
      return 100 unless d.respond_to?(:reduce_hit_ratio)
      v = d.reduce_hit_ratio
      v.nil? ? 100 : v
    end

    # A skill's damage variance (its `variance` field on the 0-10 scale, default
    # 4), the spread applied to its battle damage when the fight rolls variance.
    def skill_variance(sk)
      sk.respond_to?(:variance) ? (sk.variance || 4) : 4
    end

    # The elemental attribute ids a skill applies — its `attribute_effects` bool
    # array (field 44), a flag per attribute — used to scale the skill's battle
    # damage by the target's resistance. A fixture without the field applies none.
    def skill_attributes(sk)
      set = sk.respond_to?(:attribute_effects) ? sk.attribute_effects : nil
      return [] unless set
      ids = []
      set.each_with_index { |on, i| ids << (i + 1) if on }
      ids
    end

    # Whether skill `sk` is flagged "attribute defence up/down" (`affect_attr_
    # defence`, field 45) and, if so, which direction: +1 (the rank index
    # moves toward E, a *smaller* attr_rate% -- better resistance, less
    # damage taken from that attribute later) or -1 (toward A, a *larger*
    # attr_rate% -- worse resistance, more damage taken; see #attr_rate's own
    # 300/200/100/50/0 table, where a lower-lettered rank means a bigger
    # multiplier). This used to reuse `reverse_state_effect` (field 20) as an
    # unconfirmed guess; a reference implementation's source is what this was
    # ported
    # from instead (NOT independently confirmed against genuine RPG_RT under
    # wine): it
    # computes the shift as +1 when the skill is "positive" and -1 otherwise,
    # right where it applies `affect_attr_defence`, and that "positive" flag was set
    # a few lines earlier from whether the skill targets allies,
    # which is simply the negation of targeting enemies -- true for every scope
    # except Scope_enemy(0)/Scope_enemies(1). `reverse_state_effect` plays no
    # part in this at all (that flag's own state-cure/inflict role is
    # `IsPositive() ^ reverse` -- see #battle_skill_command's own
    # `heals_states`, confirmed against genuine RPG_RT under wine to apply
    # under RPG2000 too, not gated to RPG2003 the way a reference
    # implementation's own source guards it).
    # So the direction is purely the skill's own target scope: an ally-scoped
    # skill (self/single ally/all allies, the "buff"
    # shape) always raises resistance, an enemy-scoped one (single/all
    # enemies, the "curse" shape) always lowers it -- matching
    # #battle_skill_target's own enemy-scope test (`scope == 0 || scope ==
    # 1`). nil when the skill does not touch attribute defence at all.
    def skill_attr_shift(sk)
      return nil unless sk.respond_to?(:affect_attr_defence) && sk.affect_attr_defence
      sk.scope == 0 || sk.scope == 1 ? -1 : 1
    end

    # The (skill field name -> Combatant ability-value key) pairs
    # #skill_stat_mod_keys checks; distinct from `affect_attr_defence`
    # (#skill_attr_shift), which shifts a resistance *rank* rather than a raw
    # ATK/DEF/SPI/AGI value. A reference implementation (not independently
    # confirmed against genuine RPG_RT under wine)
    # rolls each of `affect_attack`/`affect_defense`/`affect_spirit`/
    # `affect_agility` independently, alongside `affect_hp`/`affect_sp`, all
    # against the *same* signed effect value -- `Game::Battle#apply_skill_hit`
    # now rolls all six the same independent way (`#skill_effect_hits?`),
    # matching this. A previous version of this comment recorded a deliberate
    # decision to leave all six unrolled "for consistency" rather than half-fix
    # the gap; the fix closed the whole thing symmetrically instead.
    SKILL_STAT_MOD_FLAGS = { atk: :affect_attack, def: :affect_defense,
                              spi: :affect_spirit, agi: :affect_agility }.freeze

    # Which of `{atk:, def:, spi:, agi:}` skill `sk` touches, per its own
    # affect_attack/affect_defense/affect_spirit/affect_agility flags (schema
    # fields 33-36). `[]` when the skill touches none of the four. The actual
    # signed magnitude is not decided here: `Game::Battle#apply_skill_hit`
    # feeds whichever of these keys are present the exact same final signed
    # effect number (post elemental-attribute scaling, variance, and the
    # damage/recovery cap) it applies to HP/SP for the same hit, matching
    # a reference implementation reading one shared `effect` local for every
    # one of hp/sp/atk/
    # def/spi/agi rather than a separately-computed figure per stat. Applied
    # through `Game::Battle#apply_stat_mods`, which clamps the delta against
    # the target's own cap before it lands.
    def skill_stat_mod_keys(sk)
      SKILL_STAT_MOD_FLAGS.keys.select { |key| sk.respond_to?(SKILL_STAT_MOD_FLAGS[key]) && sk.send(SKILL_STAT_MOD_FLAGS[key]) }
    end

    # The command numbers for casting `sk` from `caster` on `target` (both
    # Combatant snapshots): the caster's SP `cost`, and the signed HP / SP deltas
    # to the target — negative HP for an attack skill (base effect less a quarter
    # of the target's defence, min 1), positive HP / SP for a recovery skill. An
    # attack skill also carries the states it may inflict and the roll chance.
    # Both branches carry the skill's own `variance` now — `Game::Battle#apply_
    # skill_hit` is what actually spreads either sign of effect by it, this
    # method just reports the number the skill row names.
    #
    # `free:` is for a skill invoked by a special/use_skill item rather than
    # chosen from the caster's own skill list — ported from a reference
    # implementation's own skill-start path, NOT independently confirmed
    # against genuine RPG_RT under wine — it
    # branches on whether an item backs the cast, consuming the item's own
    # use instead of the caster's SP — the item pays
    # instead of the caster's own SP, never both.
    def battle_skill_command(sk, caster, target, free: false)
      cost = free ? 0 : skill_cost(sk, caster)
      # A **switch** skill (type 3) has no HP/SP/state effect at all -- its
      # only job, in battle exactly as on the field (`#cast_switch_skill`), is
      # turning on its configured switch once cast. Ported from a reference
      # implementation, NOT independently confirmed
      # against genuine RPG_RT under wine, which
      # special-cases this before any of the ordinary hit/damage/state logic,
      # setting the affected switch and reporting success immediately.
      # `switch_id` rides the command the same way
      # `#command_item`'s own does for a switch item -- `Game::Battle#apply_
      # skill_hit`'s recovery branch already reads `cmd[:switch_id]` onto its
      # log entry, and `Scene::Battle#drive_battle_animate` already flips it
      # the same moment it does for a switch item; only the battle-cast
      # switch-skill command itself never carried one.
      return { cost: cost, switch_id: sk.switch_id } if sk.type == SKILL_SWITCH
      base = skill_effect(sk, caster)
      # Attribute-defence shifting isn't scoped to attack skills -- a "raise
      # my own resistance" buff and a "lower the enemy's" debuff are both this
      # same flag, just cast on a different side -- so it rides on both
      # branches below rather than only the attack one.
      shift = skill_attr_shift(sk)
      shift_ids = shift ? skill_attributes(sk) : []
      stat_keys = skill_stat_mod_keys(sk)
      enemy_scope = sk.scope == 0 || sk.scope == 1 # single or all enemies
      # A skill's own `state_effects` list normally cures on an ally/self scope
      # and inflicts on an enemy scope, XORed with `reverse_state_effect`:
      # an ally-scoped skill with it set inflicts its listed states instead of
      # curing them (a self-scoped Berserk that confuses its own caster, say),
      # and an enemy-scoped one with it set cures its target's states instead
      # of inflicting new ones. A reference implementation guards the reverse
      # term behind an RPG2003-only check (`IsPositive() ^ (Player::IsRPG2k3()
      # && skill.reverse_state_effect)`, matching #skill_attr_shift's own
      # citation of the identical formula) -- this codebase used to port that
      # gate too, on the assumption that a stock RPG2000 editor has no UI to
      # set the bit anyway (true) and so RPG_RT would never honour it there
      # regardless (unconfirmed). Checked directly against genuine RPG_RT.exe
      # under wine (2026-09-05), NOT independently confirmed further than
      # this one scope: a hand-authored RPG2000 database (real edition byte,
      # no RPG2003-only section) enemy-scope skill with the bit set cured a
      # state on its target instead of inflicting it, and the identical skill
      # with the bit clear inflicted normally -- RPG_RT reads and honours
      # `reverse_state_effect` under RPG2000 too, same as the already-known
      # "physical" skill-formula bit (`#skill_to_hit`'s own citation) the 2000
      # editor also cannot set but RPG_RT still reads. The gate is dropped
      # here to match; a database only the 2000 editor itself ever produced
      # still behaves identically, since it can never carry the bit set.
      reverse = sk.respond_to?(:reverse_state_effect) && sk.reverse_state_effect
      heals_states = !enemy_scope ^ reverse
      state_ids = skill_state_ids(sk)
      cure_ids = heals_states ? state_ids : []
      inflict_ids = heals_states ? [] : state_ids
      if enemy_scope # an attack skill
        dmg = base - skill_defence_term(sk, target)
        # Floored at 0, not 1: ported from a reference implementation's own
        # skill-effect formula, confirmed against a genuine RPG_RT.exe under
        # wine (2026-09-05): a purely-magical real skill (Nepheshel's own
        # skill 191, power 25, magical_rate 10) cast by a low-spirit enemy
        # against a target with spirit forced to 999 -- deeply negative
        # pre-clamp (dmg = 27 - 124 = -97) -- landed as a genuine
        # zero-damage hit, with RPG_RT printing its stock
        # "...はダメージを受けていない!" (took no damage) line rather than any
        # minimum-1 scratch message. `#apply_skill_hit` used to tell this
        # branch apart from a recovery skill purely by the sign of `hp`
        # (negative = attack), which broke exactly at this boundary once
        # `dmg` could reach 0 -- `attack: true` below now says so explicitly
        # instead.
        dmg = 0 if dmg < 0
        { cost: cost,
          # `hp`/`mp` each independently gate on their own affect_hp/affect_sp
          # flag now, mirroring the ally/recovery branch below -- ported from
          # a reference implementation, NOT independently confirmed against
          # genuine RPG_RT under wine: it reads the identical one shared
          # `effect` local into both the HP and SP affected-guards
          # rather than rolling either separately, so a dual HP+SP attack
          # skill deals the
          # *same* number to each pool, and an SP-only drain (affect_hp clear,
          # affect_sp set -- a real, valid Effects-tab combination, per
          # @2000_battle_bot/デフォ戦bot trivia on the HP-reaches-zero
          # interaction below) never touches HP at all.
          hp: sk.affect_hp ? -dmg : 0, mp: sk.affect_sp ? -dmg : 0, attack: true,
          inflict: inflict_ids, chance: skill_to_hit(sk, caster, target),
          variance: skill_variance(sk), attributes: skill_attributes(sk),
          # 吸収 — the caster takes what the target loses. Ported from a
          # reference implementation's "absorb and not positive" gate, NOT
          # independently
          # confirmed against genuine RPG_RT under wine: the ported behavior
          # reads the flag only on an *offensive* skill, so it rides only on
          # this branch: a healing skill that sets it drains nothing.
          absorb: skill_absorbs?(sk), attr_shift: shift, attr_ids: shift_ids,
          stat_mod_keys: stat_keys, cured: cure_ids,
          # The raw, un-gated effect (see the ally branch's own `stat_effect`
          # below) -- #apply_skill_hit's ATK/DEF/SPI/AGI modifier and its
          # damage pipeline (elemental scaling, critical, variance) both need
          # this even when affect_hp/affect_sp leave `hp`/`mp` at 0, the same
          # way a reference implementation reads its one `effect` local for
          # every affect_* branch
          # alike regardless of which ones are actually set (ported behavior,
          # NOT independently confirmed against genuine RPG_RT under wine).
          stat_effect: dmg,
          # The skill's own physical_rate (0-10), scaled to a 0..100 percent
          # -- #apply_skill_hit's own #shake_off_states call reads this the
          # same way a reference implementation scales its physical-state-heal
          # rate by it, ported and NOT
          # independently confirmed against genuine RPG_RT under wine. 0 for
          # a purely magical skill, which #shake_off_states already reads as
          # "never rolls".
          physical_rate: (sk.physical_rate || 0) * 10 }
      else
        { cost: cost, hp: sk.affect_hp ? base : 0, mp: sk.affect_sp ? base : 0,
          # Ported from a reference implementation's own skill-effect formula,
          # which runs
          # its attribute-multiplier step unconditionally --
          # there is no heal-vs-damage branch gating it -- so a recovery
          # skill tagged with an elemental attribute scales by the target's
          # resistance exactly like an attack skill's `attributes:` above.
          # This is what lets a database tag a heal with a custom attribute
          # and set a character's own resistance to it to make them
          # harder/easier to heal, or build a caster-excluding MP-restore via
          # 0% self-resistance -- independently confirmed by @2000_battle_bot/
          # デフォ戦bot trivia on this exact trick (the reference implementation
          # citation
          # above is the port target, NOT independently confirmed against
          # genuine RPG_RT under wine by itself).
          attributes: skill_attributes(sk),
          variance: skill_variance(sk), attr_shift: shift, attr_ids: shift_ids,
          stat_mod_keys: stat_keys,
          # The raw, un-gated effect a buff-only skill (affect_hp clear,
          # affect_attack/defense/spirit/agility set) still needs: `hp` above
          # is 0 for such a skill, but the ATK/DEF/SPI/AGI modifier applies
          # regardless, off the same `base` a reference implementation's one
          # shared `effect`
          # local would carry into every affect_* branch alike.
          stat_effect: base,
          # Reuses `Game::Battle#apply_skill_hit`'s existing `cmd[:cured]`
          # machinery when curing (no roll, matching a battle medicine's own
          # state cure) and its `cmd[:inflict]`/`cmd[:chance]` roll when the
          # RPG2003 reverse case above turns this into an inflict instead.
          cured: cure_ids, inflict: inflict_ids, chance: skill_to_hit(sk, caster, target) }
      end
    end

    # Whether item `it` invokes a skill directly (a type-9 Special item, or an
    # equipment item flagged `use_skill`, field 71) rather than being a plain
    # medicine/switch item — the same test `Scene::ItemMenu#choose_item`
    # inlines for the field menu's own dispatch, shared here for the battle
    # menu's identical one (see #battle_usable? just below, which already
    # gates such an item on its invoked skill being battle-usable at all).
    def skill_invoking_item?(it)
      it && (it.type == ITEM_SPECIAL || (it.use_skill && (1..5).cover?(it.type)))
    end

    # Whether item `id` can be used in battle: a medicine flagged occasion_battle
    # the party actually holds, or a **special** item whose skill is battle-usable
    # (the same deferral #field_usable? makes). Nepheshel's whole thrown-bomb line
    # — 火炎玉, 爆裂玉, 氷結玉, 雷撃玉 and the rest — is special items, so this is
    # what puts them in the battle item list at all.
    #
    # A dangling item id (see #field_usable?) is reported the same way here,
    # for the battle menu's own list.
    def battle_usable?(id)
      it = db_item(id)
      if it.nil?
        $stderr.puts "[RPG2k] Item menu: party-held item ##{id} has no " \
                     'matching database row, excluding from battle menu'
        return false
      end
      return false unless item_count(id) > 0
      return use_skill_item_usable?(it, true) if it.use_skill
      case it.type
      when ITEM_MEDICINE then !item_field_only?(it)
      when ITEM_SWITCH then item_battle_occasion?(it)
      when ITEM_SPECIAL then battle_skill?(db_skill(it.skill_id))
      else false
      end
    end

    # Every held item as `[id, count]` pairs in ascending id order, for the
    # battle item list -- mirrors #field_items exactly (see its own doc
    # comment for the full citation): confirmed against genuine RPG_RT.exe,
    # not just a reference implementation's "same list-widget class" claim
    # #field_items already
    # warned this method's own inclusion still needed independent checking --
    # a live battle with a usable Herb and a field-only (battle-unusable)
    # Smelling Salts held listed *both* in the item window, the unusable one
    # in the identical measured "disabled" swatch color the field-menu fix
    # found. #battle_usable? is now consulted only for enablement, the same
    # split as the field menu. The dangling-item exclusion (and its warning)
    # stays, the same defensible corner case #field_items keeps.
    # Stored bag order, not an id sort -- see #field_items' own citation for
    # the wine measurement (cycle #252); the in-battle list shares it.
    def battle_items
      @items.keys.select do |id|
        it = db_item(id)
        if it.nil?
          $stderr.puts "[RPG2k] Item menu: party-held item ##{id} has no " \
                       'matching database row, excluding from battle menu'
        end
        it
      end.map { |id| [id, item_count(id)] }
    end

    # The HP / SP a medicine restores to a battle `target` (Combatant snapshot)
    # plus the status conditions it cures, as `{ hp:, mp:, cured: [ids] }` — the
    # same recovery and (antidote / herb) cure the field menu applies. Pure
    # arithmetic: an actor_set (使用可能キャラ) restriction is a question of
    # which target may be *offered* at all, not of what this formula computes
    # once one legitimately is — see `Scene::Map#battle_ally_targets`, which is
    # where that gate actually lives for a battle-cast item.
    #
    # A 蘇生専用 (`ko_only`) item on a target who is not down does nothing at
    # all, not even the state cure -- ported from a reference implementation,
    # not independently confirmed against genuine RPG_RT under wine: it
    # returns before state removal *and* HP/SP recovery are ever
    # computed once the item is ko_only-flagged and the target is not dead.
    # `#use_medicine` already applies this on the field
    # menu path (`ko_only_blocked?`); the battle path had never checked it,
    # so a revive item cast on a still-standing ally quietly worked as a free
    # full heal instead of doing nothing.
    def battle_item_command(it, target)
      return { hp: 0, mp: 0, cured: [] } if ko_only_blocked?(it, target)
      hp, mp = item_recovery(it, target)
      { hp: hp, mp: mp, cured: item_cured_states(it) }
    end

    # Whether medicine `it` targets the whole party (item scope 1) rather than a
    # single ally (scope 0). The battle menu casts an all-party item on every
    # living member at once, skipping target selection.
    def item_all_allies?(it)
      it.respond_to?(:scope) && it.scope == 1
    end
  end

  class Map
    # Push #set_lower/#set_upper edits back into the LCF chunk data (chunks
    # 71/72, both a plain :int16_array -- see mruby-lcf/mrblib/schema.rb)
    # through #unit's own schema-driven `[]=`, so #unit.to_lcf/#unit.save_to
    # actually carry them. Reading (#lower/#upper, and so Scene::Map's own
    # rendering) never needs this: both already read straight off the same
    # @lower/@upper arrays #set_lower/#set_upper mutate in place -- it is only
    # the file writer that goes through #unit's own separately-decoded copy.
    def sync_layers_to_unit
      @unit[71] = @lower
      @unit[72] = @upper
    end
  end

  # Evaluation of RPG2000 *battle*-event page conditions (troop chunk 11). A
  # page fires when every sub-condition its `flags` bitfield enables holds.
  #
  # The bit values follow liblcf's `TroopPageCondition::Flags` declaration
  # order (switch_a, switch_b, variable, turn, fatigue, enemy_hp, actor_hp,
  # turn_enemy, turn_actor, command_actor) packed LSB-first — the same
  # convention Game::EventPage above uses for map pages.
  #
  # Four of those bits are confirmed against real bytes (Nepheshel, 3265 troop
  # pages, 2819 of them conditional — `ruby scripts/analyze_game.rb --troops`):
  #
  #   * bit 0 SWITCH_A (2650 pages) and bit 1 SWITCH_B (468) — bit 1 only ever
  #     appears together with bit 0, as `flags=0x003`, and those pages carry a
  #     *pair* of plausible switch ids (11/5, 12/6, 13/7), which is what two
  #     switch conditions look like and not what any other field would.
  #   * bit 3 TURN (165) — 156 pages are base 0 / multiple 0 (fire on turn 0,
  #     the opening page) and 9 are base 0 / multiple 1 (fire every turn),
  #     exactly the two shapes #check_turns produces.
  #   * bit 5 ENEMY_HP (4) — every one carries a non-default `0..30%` window
  #     ("the boss enrages below 30% HP"). A default window would prove nothing;
  #     a deliberate one could not survive a wrong bit.
  #
  # Bits 2 (VARIABLE), 4 (FATIGUE), 6 (ACTOR_HP) and 7-9 (the per-battler turn
  # and command tests) are unused by that game, so their positions rest on the
  # liblcf declaration order alone. What the data does establish is that the
  # order is not shifted: a shift would have moved the confirmed four.
  #
  # Only the sub-conditions the battle context can answer are tested; one it
  # cannot answer (see `ctx`) is treated as unmet rather than silently passing,
  # so a page never fires on a condition we did not actually check.
  module BattlePage
    SWITCH_A      = 0x001
    SWITCH_B      = 0x002
    VARIABLE      = 0x004
    TURN          = 0x008
    FATIGUE       = 0x010
    ENEMY_HP      = 0x020
    ACTOR_HP      = 0x040
    TURN_ENEMY    = 0x080
    TURN_ACTOR    = 0x100
    COMMAND_ACTOR = 0x200

    # RPG2000's turn matcher: with no `multiple` the turn must equal `base`
    # exactly; otherwise it must be at or past `base` and an exact number of
    # `multiple` steps beyond it. So base 0 / multiple 2 fires on turns 0, 2,
    # 4, ...
    #
    # Both the body and the argument order are taken from a reference
    # implementation, not
    # from guesswork (not independently confirmed against genuine RPG_RT
    # under wine): its turn-check helper is
    # `turns >= base && (turns - base) == 0` when multiple is 0
    # (which is just `turns == base`, written that way below) and
    # `turns >= base && (turns - base) % multiple == 0` otherwise; and
    # its condition check calls it with
    # the page's `turn_b` as `base` and `turn_a` as `multiple`, which reads backwards
    # from the field names and is exactly why it is worth writing down.
    #
    # Real data agrees but cannot by itself pin the order down: every turn-gated
    # page in the games checked so far has `turn_b == 0` (156 pages at
    # multiple 0, firing on turn 0; 9 at multiple 1, firing every turn), and a
    # swapped order would produce the same two behaviours for those values. A
    # game with a "from turn N, every M" page would settle it independently.
    def self.check_turns(turn, base, multiple)
      return turn == base if multiple.nil? || multiple == 0
      turn >= base && (turn - base) % multiple == 0
    end

    # Whether a battler's HP sits within a percentage window of its maximum
    # (the enemy-HP / actor-HP conditions are expressed in percent).
    def self.hp_within?(battler, min, max)
      return false if battler.nil? || battler.max_hp.nil? || battler.max_hp <= 0
      pct = battler.hp * 100 / battler.max_hp
      pct >= min && pct <= max
    end

    # `ctx` is the battle context the interpreter also runs against; it answers
    # `turn`, `enemy(index)`, `ally_by_actor_id(id)`, `enemy_turn(index)`,
    # `actor_turn(id)`, `fatigue` and `actor_command(id)`. A context that cannot
    # answer a tested sub-condition fails the page.
    #
    # `source` is the battler a per-battler check runs *for* -- the scene passes
    # the battle's #acting_battler at a battler's action boundary. It gates the
    # turn_enemy / turn_actor / command_actor conditions the way a
    # reference implementation's own condition check does (ported, NOT independently
    # confirmed against genuine RPG_RT under wine): a page checked at one
    # battler's turn only fires off that battler's own counter/command, and a
    # command_actor page needs a source at all. A no-source round-boundary
    # check leaves those conditions ungated (turn_* test the named battler
    # regardless, command_actor fails), matching that ported behavior.
    def self.active?(cond, switches, variables, ctx, source = nil)
      # A page whose condition box is entirely unticked never runs -- ported
      # from a reference implementation's own condition check, which opens
      # with exactly this
      # test, NOT independently confirmed against genuine RPG_RT under wine.
      # Worth stating because the
      # opposite reading is the natural one: every other page kind in RPG2000
      # runs when its conditions are vacuously satisfied. Both test beds do have
      # such pages (446 of Nepheshel's 3265, all 88 of mtf-meido-action's), and
      # every one of them is empty, so the rule costs those games nothing.
      return false if cond.nil?
      flags = cond.flags || 0
      return false if flags == 0
      return false if (flags & SWITCH_A) != 0 && !switches[cond.switch_a_id]
      return false if (flags & SWITCH_B) != 0 && !switches[cond.switch_b_id]
      if (flags & VARIABLE) != 0
        return false if variables[cond.variable_id] < cond.variable_value
      end
      return false if (flags & TURN) != 0 &&
                      !check_turns(ctx.turn, cond.turn_b, cond.turn_a)
      if (flags & ENEMY_HP) != 0
        return false unless hp_within?(ctx.enemy(cond.enemy_id),
                                       cond.enemy_hp_min, cond.enemy_hp_max)
      end
      if (flags & ACTOR_HP) != 0
        return false unless hp_within?(ctx.ally_by_actor_id(cond.actor_id),
                                       cond.actor_hp_min, cond.actor_hp_max)
      end
      # turn_enemy / turn_actor / fatigue / command_actor are RPG2003-only
      # conditions -- ported from a reference implementation's own condition
      # check, NOT independently confirmed against genuine
      # RPG_RT under wine, which wraps all four in
      # its own RPG2003-commands gate. The RPG2000 editor's condition box
      # has no controls for any of these bits at all, so a genuine .lmt
      # should never set them on a non-2k3 database -- but an untested flag
      # with no guard reads as "always true" the instant one is set, exactly
      # the same silent-pass-through class of bug the map-event TIMER2
      # condition (Game::EventPage.active?, this file) was already fixed for.
      if (flags & TURN_ENEMY) != 0 && ctx.rpg2003?
        t = ctx.enemy_turn(cond.turn_enemy_id, source)
        return false if t.nil?
        return false unless check_turns(t, cond.turn_enemy_b, cond.turn_enemy_a)
      end
      if (flags & TURN_ACTOR) != 0 && ctx.rpg2003?
        t = ctx.actor_turn(cond.turn_actor_id, source)
        return false if t.nil?
        return false unless check_turns(t, cond.turn_actor_b, cond.turn_actor_a)
      end
      if (flags & COMMAND_ACTOR) != 0 && ctx.rpg2003?
        return false unless ctx.actor_command(cond.command_actor_id, source) == cond.command_id
      end
      if (flags & FATIGUE) != 0 && ctx.rpg2003?
        f = ctx.fatigue
        return false if f.nil?
        return false if f < cond.fatigue_min || f > cond.fatigue_max
      end
      true
    end

    # Every [id, page] whose condition currently holds, in page order — unlike
    # a map event (where the highest active page wins) RPG2000 runs *each*
    # matching battle page. `source` threads to #active? (the battler a
    # per-battler check runs for, see there).
    def self.select_all(pages, switches, variables, ctx, source = nil)
      out = []
      return out if pages.nil?
      pages.each { |id, page| out << [id, page] if active?(page.condition, switches, variables, ctx, source) }
      out
    end
  end

  # One entry of an enemy's 行動パターン (action pattern) table — the database
  # enemy row's chunk 42, decoded off the LCF row into plain data so the battle
  # simulation can pick an action without holding a database row.
  #
  # An enemy does not simply attack: each turn RPG_RT walks this table, keeps the
  # entries whose `condition` currently holds, and picks one at random weighted
  # by `rating` (see Game::Battle#choose_enemy_action). `kind` says what the
  # chosen entry does — a basic action, a skill, or a transformation into another
  # enemy — and an entry may also flip a switch once it has run.
  #
  # The field names and values are liblcf's RPG::EnemyAction. Real data uses
  # nearly all of them: across the two test beds 510 of 959 actions are skills
  # (which is why an enemy that only ever swung its fists was so far off), and
  # every condition type except `sp` appears.
  class EnemyAction
    # `kind`: what the action does.
    KIND_BASIC     = 0
    KIND_SKILL     = 1
    KIND_TRANSFORM = 2

    # `basic`: which basic action, when kind is KIND_BASIC.
    BASIC_ATTACK       = 0
    BASIC_DUAL_ATTACK  = 1
    BASIC_DEFEND       = 2
    BASIC_OBSERVE      = 3
    BASIC_CHARGE       = 4
    BASIC_AUTODESTRUCT = 5
    BASIC_ESCAPE       = 6
    BASIC_NOTHING      = 7

    # `condition_type`: what gates the action. The two `condition_param`s are the
    # inclusive bounds of a range for the numeric conditions, and the turn
    # condition's base / multiple pair.
    COND_ALWAYS    = 0
    COND_SWITCH    = 1
    COND_TURN      = 2
    COND_ACTORS    = 3
    COND_HP        = 4
    COND_SP        = 5
    COND_PARTY_LVL = 6
    COND_FATIGUE   = 7

    attr_reader :kind, :basic, :skill_id, :enemy_id, :condition_type,
                :condition_param1, :condition_param2, :switch_id, :switch_on,
                :switch_on_id, :switch_off, :switch_off_id, :rating

    # Read one action off an LCF row, tolerating a fixture that omits a field
    # (the check harnesses build these by hand).
    def initialize(row)
      @kind             = int_of(row, :kind, 0)
      @basic            = int_of(row, :basic, 0)
      @skill_id         = int_of(row, :skill_id, 0)
      @enemy_id         = int_of(row, :enemy_id, 0)
      @condition_type   = int_of(row, :condition_type, 0)
      @condition_param1 = int_of(row, :condition_param1, 0)
      @condition_param2 = int_of(row, :condition_param2, 0)
      @switch_id        = int_of(row, :switch_id, 0)
      @switch_on_id     = int_of(row, :switch_on_id, 0)
      @switch_off_id    = int_of(row, :switch_off_id, 0)
      @switch_on        = bool_of(row, :switch_on)
      @switch_off       = bool_of(row, :switch_off)
      # The editor's default priority is 50; a row without one still competes.
      @rating           = int_of(row, :rating, 50)
    end

    def skill?;     @kind == KIND_SKILL; end
    def transform?; @kind == KIND_TRANSFORM; end
    def basic?;     @kind == KIND_BASIC; end

    private

    def int_of(row, name, dflt)
      return dflt unless row.respond_to?(name)
      v = row.send(name)
      v.nil? ? dflt : v.to_i
    end

    def bool_of(row, name)
      row.respond_to?(name) && row.send(name) ? true : false
    end
  end

  # A single enemy instantiated from the database (chunk 14) for a battle: its
  # combat stats plus the EXP / gold it is worth and its battle-screen position.
  # Current HP / SP start full. The turn-based battle that would reduce them is
  # not built yet, so for now this backs the Enemy Encounter reward model.
  class Enemy
    attr_reader :id, :name, :battler_name, :max_hp, :max_sp, :atk, :def, :spi,
                :agi, :exp, :gold, :x, :y, :drop_id, :drop_prob
    attr_accessor :hp, :sp
    # Whether the member starts the fight off-screen. Writable because the Show
    # Hidden Monster battle-event command (13150) brings one in mid-fight.
    attr_accessor :hidden

    def initialize(db, id, x = 0, y = 0, hidden = false)
      row = db.enemy[id]
      # A database shrink can leave a troop member naming a deleted individual
      # enemy id (chunk 14) -- shown as "?" in the editor, docs/TODO.md's
      # runtime error catalog, distinct from the enemy-*group* (troop) id case
      # `Game::Party#db_enemy_group`/Enemy Encounter already reports. Degrading
      # to a blank/1-HP model below is unchanged (by design, matching real
      # RPG_RT's own tolerance); only the gap is now visible. `respond_to?`
      # guarded the same way `db_item`/`db_enemy_group` reach into `@db`, so a
      # bare test fixture with no `enemy` table at all stays silent -- this is
      # only for a genuine dangling id in a real database.
      if row.nil? && id && id > 0 && db.respond_to?(:enemy)
        $stderr.puts "[RPG2k] Enemy: enemy id #{id} not found in the " \
                     'database, degrading to a blank placeholder'
      end
      @id = id
      @name    = row ? row.name.to_s : ''
      # The Monster/<name> battle graphic (blank for a fixture that omits it);
      # the battle screen draws it, falling back to a placeholder block.
      @battler_name = row && row.respond_to?(:battler_name) ? (row.battler_name || '') : ''
      @max_hp  = row ? row.max_hp : 1
      @max_sp  = row ? row.max_sp : 0
      @atk     = row ? row.attack : 0
      @def     = row ? row.defense : 0
      @spi     = row ? row.spirit : 0
      @agi     = row ? row.agility : 0
      @exp     = row ? row.exp : 0
      @gold    = row ? row.gold : 0
      # The item this enemy may drop on defeat (field 13, 0 = none) and its drop
      # probability as a percentage (field 14; 0 for a fixture lacking it).
      @drop_id   = row && row.respond_to?(:drop_id) ? (row.drop_id || 0) : 0
      @drop_prob = row && row.respond_to?(:drop_prob) ? (row.drop_prob || 0) : 0
      @x = x
      @y = y
      @hidden = hidden ? true : false
      @hp = @max_hp
      @sp = @max_sp
      # This member's own randomized starting phase for the `levitate` bob's
      # sine argument (0..63, matching a reference implementation's `frame_counter` seed --
      # see `#flying_phase`'s own attr comment below). Rolled per member by
      # `Troop#initialize`, not here, since only the troop has an RNG to
      # hand; left at the schema default of 0 for a bare fixture with none.
      @flying_phase = 0
      # Critical-hit chance as a whole percent (0 = never), from the enemy's
      # critical_hit flag and its 1-in-`critical_hit_chance` rate, truncated
      # the same way -- and for the same reason -- as Actor#crit_chance. An
      # enemy has no equipment, so unlike an actor's this is the whole of it.
      @crit_chance = if row && row.respond_to?(:critical_hit) && row.critical_hit
                       n = row.respond_to?(:critical_hit_chance) ? row.critical_hit_chance : 0
                       n && n > 0 ? (100.0 / n).to_i : 0
                     else
                       0
                     end
      # Per-attribute defence ranks ({ attribute_id => rank 0..4 }) from the
      # enemy's attribute_ranks byte array, so an elemental attack scales its
      # damage by this monster's resistance. Captured now since `row` isn't kept.
      @attribute_ranks = {}
      arr = row && row.respond_to?(:attribute_ranks) ? row.attribute_ranks : nil
      arr.each_with_index { |v, i| @attribute_ranks[i + 1] = v } if arr
      # Per-state susceptibility ranks ({ state_id => rank 0..4 }) from the
      # enemy's state_ranks byte array, scaling how often a status lands on it.
      @state_ranks = {}
      sr = row && row.respond_to?(:state_ranks) ? row.state_ranks : nil
      sr.each_with_index { |v, i| @state_ranks[i + 1] = v } if sr
      # The "miss" flag (field 26): a flagged enemy is clumsier and attacks at a
      # 70% base hit rate rather than the usual 90% (a reference implementation's GetHitChance).
      @miss = row && row.respond_to?(:miss) ? (row.miss ? true : false) : false
      # The "airborne" flag (field 28, `levitate`): purely a battle-screen
      # display effect (per a reference implementation's flying-offset logic) with no
      # accuracy/hit-related effect of any kind -- and, per that same source,
      # RPG2000 never renders it at all ("2k does not support flying, albeit
      # mentioned in the help file"), only RPG2003 does, gated by
      # `Scene::Map#flying_offset` the same way. Read here regardless of
      # edition, same as every other schema field this class exposes.
      @levitate = row && row.respond_to?(:levitate) ? (row.levitate ? true : false) : false
      # The "Appear Transparent" flag (field 10): the battle screen renders this
      # enemy's sprite at reduced opacity for the whole fight -- purely cosmetic,
      # like `levitate`, with no accuracy/evasion effect of any kind. Ported
      # from a reference implementation, NOT independently confirmed against
      # genuine RPG_RT under wine: it
      # treats this as a bare passthrough, and
      # computes `alpha = 160 *
      # alpha / 255` whenever it is set -- 160/255 (~63%) of whatever opacity the
      # sprite would otherwise have (255 outside of the death-fade/explode
      # animations this codebase does not yet model).
      @transparent = row && row.respond_to?(:transparent) ? (row.transparent ? true : false) : false
      # The battle-graphic hue shift (field 3, degrees 0..359): lets a game
      # reuse one Monster/<name> bitmap for several palette-swapped variants
      # (a red slime and a blue slime sharing "Slime.png") instead of shipping
      # a separate file per colour. Ported from a reference implementation, NOT
      # independently confirmed against genuine RPG_RT under wine:
      # it treats this as a bare
      # passthrough, and
      # rotates the loaded bitmap through
      # a hue-change blit whenever it is nonzero, before the sprite is
      # ever shown -- purely a render-time recolour with no stat effect,
      # unlike every field above it.
      @battler_hue = row && row.respond_to?(:battler_hue) ? (row.battler_hue || 0) : 0
      # The 行動パターン table (field 42), decoded now since `row` isn't kept. An
      # enemy whose row lists none falls back to plain attacking.
      @actions = []
      list = row && row.respond_to?(:actions) ? row.actions : nil
      list.each { |_i, a| @actions << EnemyAction.new(a) } if list
    end

    # This enemy's action pattern (Game::EnemyAction list, possibly empty).
    attr_reader :actions

    attr_reader :crit_chance, :attribute_ranks, :state_ranks

    # The "airborne" flag (field 28) -- see the comment in #initialize for what
    # it does and does not affect.
    attr_reader :levitate

    # This member's own randomized starting phase (0..63) for `Scene::Battle
    # #flying_offset`'s sine bob. Ported from a reference implementation, NOT
    # independently confirmed against genuine RPG_RT under wine, which does
    # not bob every levitating troop
    # member in lockstep from one shared clock: it
    # reads a *per-battler* frame counter,
    # which
    # is seeded
    # independently per battler at battle start -- a random value in 0..63
    # -- before that counter
    # increments in lockstep for the rest of the
    # fight for every battler. So each
    # levitating member bobs on its own fixed, randomized phase relative to
    # the others, not in unison. Writable so `Troop#initialize` can roll it.
    attr_accessor :flying_phase

    # The "Appear Transparent" flag (field 10) -- see the comment in #initialize.
    attr_reader :transparent

    # The battle-graphic hue shift (field 3) -- see the comment in #initialize.
    attr_reader :battler_hue

    # Base to-hit percentage for this enemy's normal attack (70 when the "miss"
    # flag is set, otherwise 90); fed into the battle's to-hit roll.
    def attack_hit_rate; @miss ? 70 : 90; end

    def dead?; @hp <= 0; end

    # Re-seeds this troop member's own reward fields from `into` (a fresh
    # `Enemy` for whatever database row a mid-fight Transform just repointed
    # the parallel `Game::Battle::Combatant` at) -- what `RPG2k::Scene::
    # Battle#sync_troop_member_rewards` calls once it notices a combatant's
    # battler no longer matches the sprite it was drawn from. Only the fields
    # `#total_exp`/`#total_gold`/`#drops` actually read; everything else this
    # class carries (position, `levitate`, `hidden`) is transform-invariant --
    # a Transform keeps its place and never revives a hidden member.
    def reseed_rewards(into)
      @exp = into.exp
      @gold = into.gold
      @drop_id = into.drop_id
      @drop_prob = into.drop_prob
    end
  end

  # An enemy troop (敵グループ, chunk 15) instantiated for a battle: the live
  # Enemy members at their positions. Also totals the EXP / gold the troop is
  # worth, which the Enemy Encounter command grants on victory. The battle
  # simulation itself is still to come.
  class Troop
    attr_reader :id, :name, :members
    # The troop's battle-event pages (chunk 11), each entry carrying a
    # `condition` (see Game::BattlePage) and an `event` command list the battle
    # interpreter runs. nil / empty for a troop that scripts nothing.
    attr_reader :pages

    def initialize(db, id, rng = nil)
      row = db.enemy_group[id]
      @id = id
      @name = row ? row.name.to_s : ''
      @members = []
      # Array2D#each yields (id, entry); a plain Hash test double does the same.
      row.members.each { |_, m| @members << member(db, m) } if row && row.members
      @pages = row && row.respond_to?(:pages) ? row.pages : nil
      apply_appear_randomly(row, rng) if row && rng
      # Each levitating member's own `flying_phase` (see Enemy#flying_phase's
      # own citation): rolled once here, in member order, the same way
      # a reference implementation's own battle-reset seeds every battler's
      # frame counter
      # independently at battle start. RPG_RT actually rolls this for every
      # battler on both sides, levitating or not, party actor included --
      # deliberately narrowed here to only the members whose `flying_phase`
      # can ever be observed at all (a non-levitating member's own bob is
      # always 0, and only a Troop's own `Enemy` members bob in the first
      # place), so as not to shift the shared `rng`'s draw count for every
      # ordinary fight the way a full, unconditional port would.
      @members.each { |m| m.flying_phase = rng.random(64) if m.levitate } if rng
    end

    # EXP / gold / drops are only earned from members that actually fell in
    # this fight -- a member still flagged `hidden` at victory time (never
    # revealed by a Show Hidden Monster page, sent running by a page's own
    # Force Flee, sent running by its own basic Escape action, or blown up by
    # its own basic Autodestruct -- see `Game::Battle#enemy_autodestruct`)
    # contributes none of the three, even though a fight can end in victory
    # while such a member is technically still at full HP:
    # `Game::Battle#enemy_active?` (`mruby-rpg2k/mrblib/game.rb`) already
    # treats hidden the same as dead for win/loss purposes (`out_of_play?`),
    # so `enemy_active?(@enemies)` goes false -- and victory fires -- the
    # instant every *visible* member is down, with no requirement that a still-hidden
    # one ever engaged at all. Ported from a reference implementation, NOT
    # independently confirmed against genuine RPG_RT under wine:
    # its reward-generation routines each loop, skipping any member whose
    # HP is already zero, before
    # summing/rolling that member at all -- a hidden member's own
    # HP is never touched by never fighting, a Force-Fled/Escaped member's
    # isn't either (hidden alone, never killed), and neither is a
    # self-destructed one's (that routine only ever
    # hides its own caster, never touching its HP -- see
    # `enemy_autodestruct`'s own comment), so all three read as not dead and
    # are skipped by all three reward routines. This class
    # never lets a member's HP move at all -- the actual combat plays out on
    # parallel `Combatant` structs in `Game::Battle`, not on `Troop`'s own
    # `Enemy` objects -- so `hidden` (kept live by
    # `Scene::Map#reveal_battle_monster`/`#remove_fled_monster` for a battle
    # page's own commands, and by `Scene::Map#refresh_battle_sprites` for
    # anything a combatant does to itself mid-fight) is the one signal
    # available here, and by the "hidden ~ not dead" equivalence above it is
    # also the *correct* one: a non-hidden member reaching this call is
    # always the dead case.
    def total_exp;  live_members.reduce(0) { |s, e| s + e.exp } end
    def total_gold; live_members.reduce(0) { |s, e| s + e.gold } end

    # The item ids the troop yields on victory: each member carrying a drop item
    # rolls its `drop_prob` percentage against `rng` (0..99 < prob, a reference
    # implementation's percent-chance roll), so a 100% drop is certain, a 0% never lands, and the
    # same item can drop from several members. Returns the ids in member order.
    def drops(rng)
      live_members.each_with_object([]) do |e, out|
        next unless e.drop_id && e.drop_id > 0
        out << e.drop_id if rng.random(100) < e.drop_prob
      end
    end

    private

    # Members that actually took part and fell -- see the comment on
    # #total_exp/#total_gold/#drops above for why `hidden` is the right (and
    # only available) proxy for "dead" at this call site.
    def live_members; @members.reject(&:hidden) end

    def member(db, m)
      Enemy.new(db, m.enemy_id, m.x, m.y, m.invisible)
    end

    # ランダムに出現 (Appear Randomly, chunk 15 field 6): once per battle, roll
    # each initially-visible member for a 40% chance to start hidden instead,
    # stopping the instant only one member is left visible -- a fight always
    # needs at least one visible foe to open against. Ports a reference
    # implementation's battle-reset logic (NOT independently confirmed against
    # genuine RPG_RT under wine): a
    # per-member 40% chance roll, an already-hidden member
    # (its own individual chunk-15-member field 4, `invisible`) skipped
    # rather than re-rolled or counted against the "one must stay visible"
    # floor, and the roll happening once, in member order, not a
    # roll-then-reveal-one-back pass. `rng` is optional (nil skips the whole
    # pass) since most callers -- the seeded harness fixtures included --
    # have no RNG to hand in and expect a `Troop` to build deterministically.
    def apply_appear_randomly(row, rng)
      return unless row.respond_to?(:appear_randomly) && row.appear_randomly
      non_hidden = @members.count { |m| !m.hidden }
      @members.each do |m|
        break if non_hidden <= 1
        next if m.hidden
        next unless rng.random(100) < 40
        m.hidden = true
        non_hidden -= 1
      end
    end
  end

  # A turn-stepped auto-battle that decides an Enemy Encounter by the combatants'
  # stats. Battlers act in agility order (highest first); each attacks a random
  # living opponent for `attack_damage`, and the fight resolves to :victory when
  # every enemy is down or :defeat when the whole party is. `#step` performs one
  # action at a time and appends a `#log` entry, so an on-screen battle can
  # animate it action-by-action; `#run` steps to completion for a headless
  # The outside world an enemy's 行動パターン needs, which Game::Battle itself
  # deliberately does not hold: it works on Combatant snapshots and keeps no
  # database. A skill action needs the skill table (and the party's own casting
  # formulas, so an enemy's fireball is costed and scaled exactly like a hero's),
  # a transformation needs the enemy table, and the switch / party-level
  # conditions read live game state.
  #
  # Passed to Game::Battle as its `ai` collaborator. Every accessor tolerates a
  # partial source so the check harnesses can hand in a stub (or nothing at all,
  # in which case the enemies fall back to plain attacking as before).
  class EnemyAi
    # bc2cpp: (, Game::State)
    def initialize(db, state)
      @db = db
      @state = state
    end

    # The database row for a skill / enemy id, or nil.
    def skill(id)
      @db && @db.respond_to?(:skill) ? @db.skill[id] : nil
    end

    # A freshly instantiated Game::Enemy for `id` — what a transformation turns
    # into, read through the same constructor a troop member is built with (so it
    # decodes its stats, ranks and its own action pattern). nil when unknown.
    # bc2cpp: (fixnum)
    def enemy(id)
      return nil unless @db && @db.respond_to?(:enemy) && id && id > 0
      return nil unless @db.enemy[id]
      Enemy.new(@db, id)
    end

    # The cast numbers for `sk` from `caster` on `target`, reusing Game::Party's
    # own battle_skill_command so an enemy's skill costs and scales identically.
    def skill_command(sk, caster, target)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return nil unless party && party.respond_to?(:battle_skill_command)
      party.battle_skill_command(sk, caster, target)
    end

    # Whether `sk`, cast by `caster` against its own `troop`, could possibly
    # help anyone -- reuses Game::Party's own #skill_helps_troop? formula so an
    # enemy's own AI reads the exact same skill-effectiveness rules a field
    # cast's greyed-out-if-a-no-op check does. Defaults to "always worth
    # trying" without a party to ask, matching every other tolerant accessor
    # here.
    def skill_helps_troop?(sk, caster, troop)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return true unless party && party.respond_to?(:skill_helps_troop?)
      party.skill_helps_troop?(sk, caster, troop)
    end

    # Whether `sk` is even a legal in-battle action to name in an enemy's own
    # action pattern -- reuses Game::Party's own #battle_skill? so an enemy's
    # AI is gated the exact same way a field/battle actor cast is. Ported
    # from a reference implementation, NOT independently confirmed against genuine
    # RPG_RT under wine: it
    # rejects a skill action outright when
    # it is not usable at all -- before the action's own
    # weight is ever computed -- and that usability check,
    # which is reached in
    # battle, is unconditionally false for an Escape/Teleport-type skill and
    # gated on the skill's own `occasion_battle` flag for a Switch-type one.
    # Defaults to "usable" without a party to ask, matching every other
    # tolerant accessor here.
    def skill_battle_usable?(sk)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return true unless party && party.respond_to?(:battle_skill?)
      party.battle_skill?(sk)
    end

    # Whether `caster` (a live Game::Actor, not a battle Combatant snapshot —
    # #choose_auto_battle_command reaches through a Combatant's own `#actor`
    # to get one) can actually cast skill `sid` right now: reuses
    # Game::Party's own #can_cast? (affordability, silence and weapon-
    # Attribute equip-gating) so a Forced-AI actor's own skill eligibility
    # matches the ordinary field/menu gate exactly, mirroring a reference
    # implementation's own skill-usability check, the same function its
    # auto-battle rank calculation gates on. Defaults to "eligible" without a party to ask, matching every
    # other tolerant accessor here.
    def skill_ready?(caster, sid)
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      return true unless party && party.respond_to?(:can_cast?)
      party.can_cast?(caster, sid)
    end

    def switch?(id)
      sw = @state && @state.respond_to?(:switches) ? @state.switches : nil
      sw ? sw[id] : false
    end
    # bc2cpp: (fixnum, )

    def set_switch(id, on)
      sw = @state && @state.respond_to?(:switches) ? @state.switches : nil
      sw[id] = on if sw && id && id > 0
    end

    # The party's average level, which the party_lvl action condition ranges
    # over (a reference implementation's average-level calculation). 0 with no party.
    def party_level
      party = @state && @state.respond_to?(:party) ? @state.party : nil
      actors = party && party.respond_to?(:actors) ? party.actors : nil
      return 0 if actors.nil? || actors.empty?
      total = 0
      actors.each { |a| total += (a.respond_to?(:level) ? (a.level || 0) : 0) }
      total / actors.size
    end
  end

  module States
    # RPG2003's per-state battle-sprite pose: which pose (0-indexed, the same
    # scheme `Scene::Battle::ACTOR_*_POSE` constants use) a `db.battleranimations`
    # entry should show while this state is the significant one on a living
    # party member. Ported from a reference implementation's own source, NOT
    # independently confirmed against genuine RPG_RT under wine:
    # it
    # reads the battler animation id field directly as
    # the pose to show (its own `+1`/`101->7` dance is that logic
    # translating into its own runtime `AnimationState` enum, which carries an
    # extra `Null` head element ahead of `Idle` that this schema's own 0-based
    # `battler_animation_id` field never had to begin with -- liblcf's own
    # schema default for this field, field 39 on the `situation` chunk, is
    # already `6`, this codebase's own `ACTOR_BAD_STATUS_POSE` index, not the
    # C++ side's raw pre-translation sentinel `100`). DEFAULT_ANIMATION_POSE
    # is that same fallback for a fixture/older-save row that omits the field
    # outright.
    DEFAULT_ANIMATION_POSE = 6
    def self.animation_pose(id, table)
      r = row(id, table)
      p = r && r.respond_to?(:battler_animation_id) ? r.battler_animation_id : nil
      p.nil? ? DEFAULT_ANIMATION_POSE : p
    end

    # RPG_RT's sentence for a state landing on `battler_name`. The database
    # stores the *predicate* only ("は毒にかかった！"), which RPG2000 prints
    # straight after the battler's name — a reference implementation's
    # state-message formatting, whose placeholder form is RPG2003-only. Actors and enemies get different
    # wordings (message_actor / message_enemy). nil when the database has no
    # sentence, so the caller can compose its own.
    def self.inflict_message(id, table, battler_name, ally)
      message(battler_name,
              field(id, table, ally ? :message_actor : :message_enemy))
    end

    # ... and for a state lifting, which has one wording for both sides.
    def self.recovery_message(id, table, battler_name)
      message(battler_name, field(id, table, :message_recovery))
    end

    # ... and the per-turn reminder a battler still carrying (or just having
    # shaken off) a state gets at the very start of its own turn, before its
    # action -- distinct from #inflict_message, which fires only the instant
    # a state first lands. One wording for both sides, like recovery.
    def self.affected_message(id, table, battler_name)
      message(battler_name, field(id, table, :message_affected))
    end

    # ... and for one the target **already** carried when something tried to
    # inflict it again ("はすでに毒に冒されている！"). One wording for both sides,
    # like the recovery line. RPG_RT treats this as a result worth announcing
    # rather than a silent no-op, which is why the field exists at all: 15 of
    # Nepheshel's 25 states and 7 of mtf-meido-action's 10 fill it in.
    def self.already_message(id, table, battler_name)
      message(battler_name, field(id, table, :message_already))
    end

    def self.field(id, table, name)
      r = row(id, table)
      v = r && r.respond_to?(name) ? r.send(name) : nil
      v.nil? || v.empty? ? nil : v
    end

    def self.message(battler_name, predicate)
      return nil unless predicate
      "#{battler_name}#{predicate}"
    end

    # The 用語 (term) table's battle sentences, composed the way RPG2000 does.
    #
    # Every one of these fields is a *predicate*, not a template: the database
    # stores 「の攻撃！」 and RPG_RT puts the battler's name in front of it. The
    # `%S`-style placeholders a reference implementation supports are an RPG2003 / 2k3E feature, so
    # this side of it is pure concatenation with one Japanese particle.
    #
    # Both test beds fill in 126 of the 127 term fields, and until now the
    # runtime read two of them (`gold`, `normal_status`): the battle log spoke
    # invented English while the game's own words sat unread in the table.
    #
    # Each builder returns nil when the field is blank, so the caller can keep
    # its composed English for a database that leaves one out.
    module BattleText
      # The particle between a battler's name and the number of a damage line.
      # RPG_RT picks it by side -- は for one of yours, に for one of theirs --
      # and follows the number with a space. This is the CP932 branch of
      # a reference implementation's damaged-message formatting; the
      # Western-encoding branch uses a plain
      # space for both, and this build decodes every string as CP932 (see
      # LCF.cp932_to_utf8), so there is no second branch to take.
      ALLY_PARTICLE = 'は '.freeze
      ENEMY_PARTICLE = 'に '.freeze

      def self.term(terms, name)
        v = terms && terms.respond_to?(name) ? terms.send(name) : nil
        v.nil? || v.to_s.empty? ? nil : v.to_s
      end

      # `name + predicate` — the shape of every "so-and-so did a thing" line:
      # the attack itself (`attacking`), Defend (`defending`), Observe
      # (`observing`), Charge (`focus`), an enemy blowing itself up
      # (`autodestruction`), one fleeing (`enemy_escape`) and one transforming
      # (`enemy_transform`).
      def self.action(terms, battler_name, field)
        t = term(terms, field)
        t && "#{battler_name}#{t}"
      end

      # 「スライムに 42 のダメージを与えた！」 / 「リトは 42 のダメージを受けた！」
      # — the same sentence from the two sides, which is why the table holds two
      # predicates and one particle rule rather than two whole templates.
      def self.damage(terms, target_name, value, ally)
        t = term(terms, ally ? :actor_damaged : :enemy_damaged)
        return nil unless t
        "#{target_name}#{ally ? ALLY_PARTICLE : ENEMY_PARTICLE}#{value} #{t}"
      end

      # A blow that got through for nothing: no number and no particle.
      def self.undamaged(terms, target_name, ally)
        action(terms, target_name, ally ? :actor_undamaged : :enemy_undamaged)
      end

      # 「会心の一撃！！」 / 「痛恨の一撃！！」 — the extra line RPG_RT inserts
      # between the start line and the damage line on a critical hit
      # (`Scene_Battle_Rpg2k::ProcessBattleActionCritical`, which runs before
      # `ProcessBattleActionApply`). No battler name goes in front of it: the
      # 2k branch of a reference implementation's own critical-hit-message
      # formatting returns the bare term.
      #
      # ADR 0036 left this term unwired because which side keys it was
      # ambiguous from the test-bed data alone. A reference implementation's
      # own source was read as settling it the other way (keyed on the
      # target, the same way `actor_damaged`/`enemy_damaged` are) but that
      # reading was never checked against genuine RPG_RT and turned out
      # backwards: confirmed under wine (2026-09-05) by swapping the
      # database's own `actor_critical`/`enemy_critical` terms for distinct
      # ASCII markers -- an ally's own critical hit against an enemy showed
      # the `actor_critical` marker, and an enemy's critical hit against
      # that same ally showed the `enemy_critical` marker. That is keyed on
      # the **attacker's** side, the opposite of `actor_damaged`/
      # `enemy_damaged` (which genuinely are target-keyed, unaffected by
      # this fix) despite the naming symmetry suggesting otherwise.
      def self.critical(terms, attacker_ally)
        term(terms, attacker_ally ? :actor_critical : :enemy_critical)
      end

      # A miss. RPG2000 words it from the target's side ("...は身をかわした！"),
      # which is why one term serves both sides.
      def self.dodge(terms, target_name)
        action(terms, target_name, :dodge)
      end

      # A skill announces itself with its **own** two sentences rather than with
      # a term, which is why a skill has a voice and a plain attack does not.
      # `using_message1` follows the caster's name the way every other predicate
      # does; `using_message2` stands alone as a second line (a reference
      # implementation's second-start-message formatting returns the field
      # with no name in front),
      # so a skill can read 「リトは炎を放った！」 / 「あたりが真っ赤に染まる！」.
      #
      # Returns [] when the skill sets neither, so the caller keeps its own line.
      # 351 of the test beds' skills set the first and 18 the second.
      def self.skill_start(skill_row, caster_name)
        return [] unless skill_row
        first = term(skill_row, :using_message1)
        second = term(skill_row, :using_message2)
        lines = []
        lines << "#{caster_name}#{first}" if first
        lines << second if second
        lines
      end

      # A skill that achieved nothing. Which sentence says so is the skill row's
      # own choice: `failure_message` indexes the three 用語 failure lines, and 3
      # borrows the dodge line (a reference implementation's skill-failure-message
      # formatting). Worded from
      # the target's side, like the dodge it can become.
      FAILURE_TERMS = [:skill_failure_a, :skill_failure_b, :skill_failure_c,
                       :dodge].freeze

      # An item has no sentence of its own — it borrows the `use_item` term, and
      # is the one line RPG2000 builds from *two* names: 「リトはポーションを使っ
      # た！」 is the caster, は, the item, and the term. `item.using_message`
      # (schema field 51) is an int, not a string — but it is not dead data: a
      # skill-casting item (special/use_skill) reads as 0 or nonzero, gating
      # whether *this* generic line or the invoked skill's own sentence(s)
      # opens the log entry — see Scene::Battle#skill_start_lines.
      def self.item_start(terms, caster_name, item_name)
        t = term(terms, :use_item)
        t && "#{caster_name}#{ALLY_PARTICLE.strip}#{item_name}#{t}"
      end

      # 「リトのＨＰが 30 回復した！」 — what a potion or a cure spell restored.
      # `points` is the 用語 name of the pool (`hp` / `mp`, which Nepheshel writes
      # full-width as ＨＰ / ＭＰ and mtf-meido-action as HP / MP), and the shape
      # is a reference implementation's HP/SP-recovered-message formatting:
      # name, の, pool, "が ", the amount,
      # a space, then the term.
      def self.recovered(terms, target_name, value, points)
        t = term(terms, :hp_recovery)
        pool = term(terms, points)
        return nil unless t && pool
        "#{target_name}の#{pool}が #{value} #{t}"
      end

      # 「スライムのＨＰを 20 奪った！」 / 「リトはＨＰを 20 奪われた！」 — what a
      # 吸収 skill took. Close to the recovery line but not the same shape: the
      # particle before the pool name is の for one of theirs and は for one of
      # yours (the recovery line always takes の), the pool is followed by を
      # rather than が, and the two sides have their own predicate.
      def self.absorbed(terms, target_name, value, points, ally)
        t = term(terms, ally ? :actor_hp_absorbed : :enemy_hp_absorbed)
        pool = term(terms, points)
        return nil unless t && pool
        "#{target_name}#{ally ? 'は' : 'の'}#{pool}を #{value} #{t}"
      end

      def self.skill_failure(terms, skill_row, target_name)
        i = skill_row && skill_row.respond_to?(:failure_message) ?
              skill_row.failure_message : nil
        f = FAILURE_TERMS[i || 0]
        f && action(terms, target_name, f)
      end

      # 「リトの攻撃力が 10 上がった！」 / 「…下がった！」 — what an ATK/DEF/SPI
      # (mind)/AGI-affecting skill (`skill.affect_attack` and friends, applied
      # by `Game::Battle#apply_stat_mods`) did to a stat. `value` is the signed
      # delta actually applied (already clamped against RPG_RT's own -(base/2)
      # .. +base band); `points` is the 用語 name of the stat itself (`:attack`
      # / `:defense` / `:mind` / `:agility`) rather than a pool. Same の…が…
      # shape as #recovered above, but which of the two predicates
      # (`parameter_increase` / `parameter_decrease`) speaks is `value`'s own
      # sign rather than fixed -- a reference implementation's
      # parameter-change-message formatting.
      def self.parameter_change(terms, target_name, value, points)
        return nil if value.nil? || value == 0
        t = term(terms, value > 0 ? :parameter_increase : :parameter_decrease)
        pool = term(terms, points)
        return nil unless t && pool
        "#{target_name}の#{pool}が #{value.abs} #{t}"
      end

      # 「リトは火に対する耐性が 上がった！」 — an attribute-defence-shift skill
      # (`skill.affect_attr_defence`, applied by `Game::Battle#apply_attr_shift`)
      # moving a resistance rank. `positive` is the shift's own direction
      # (`Game::Party#skill_attr_shift`'s `attr_shift`, +1 raises / -1 lowers,
      # the same for every attribute id one skill cast touches) -- unlike the
      # parameter version above, a reference implementation's
      # attribute-shift-message formatting never
      # shows a magnitude here, only which way the rank moved, so there is no
      # `value` argument to speak of.
      def self.attribute_shift(terms, target_name, positive, attr_name)
        return nil if attr_name.nil? || attr_name.to_s.empty?
        t = term(terms, positive ? :resistance_increase : :resistance_decrease)
        return nil unless t
        "#{target_name}は#{attr_name} #{t}"
      end
    end
  end

  class Interpreter
    # Drain the Show Hidden Monster (13150) troop-member indices queued since the
    # last call. The scene polls this and builds the sprites for the revealed
    # members. Non-blocking.
    def take_revealed_monsters
      ids = @revealed_monsters
      @revealed_monsters = []
      ids
    end

    # Drain the Force Flee (1006) troop-member indices queued since the last
    # call — the members that just ran from the fight. The scene polls this and
    # drops their sprites. Non-blocking.
    def take_fled_monsters
      ids = @fled_monsters
      @fled_monsters = []
      ids
    end

    # Drain the troop-member indices Change Monster HP (13110) has just killed
    # since the last call. Ported from a reference implementation, not
    # independently confirmed against genuine RPG_RT under wine:
    # the command plays the enemy-kill system SE the instant its own
    # dead-check goes true, same as any other in-combat kill --
    # #do_change_monster_hp writes straight to the live combatant with no
    # `entry` hash for the scene's own #play_battle_action_se to read, so
    # this queue is this command's only way to tell the scene a kill just
    # happened. Non-blocking.
    def take_monster_kills
      ids = @monster_kills
      @monster_kills = []
      ids
    end

    # Drain the Change Battle Background (13210) name queued since the last call,
    # or nil. Non-blocking.
    def take_battle_background
      name = @battle_background
      @battle_background = nil
      name
    end
  end
end

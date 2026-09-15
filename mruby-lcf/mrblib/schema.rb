# Schemas for the LCF binary formats (RPG_RT.ldb / .lmt / ...).
#
# Chunk IDs and field layouts are transcribed from the VIPRPG 200X analysis
# notes: https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81
#
# Type vocabulary understood by the reader (see lcf.rb): :int, :bool, :string,
# :Array1D, :Array2D, :Tree.  A few chunks hold packed homogeneous arrays that
# the reader does not decode yet; those are annotated with a descriptive type
# (:int8_array / :int16_array / :int32_array / :event) so the layout is still
# documented, matching the pre-existing :int16_array convention.
module LCF
  module Schema
    # One field/section descriptor -- what used to be a bare Hash literal
    # (`{name: :foo, type: :int, default: 0}`) throughout this file, now a
    # concrete, fixed-shape type instead of an opaque, arbitrarily-keyed
    # container. `keyword_init: true` keeps every one of this file's ~930
    # call sites looking almost identical to the Hash literal it replaces
    # (just `FieldSchema.new(...)` instead of `{...}`); real mruby's own
    # Struct (3rd/mruby/mrbgems/mruby-struct) supports both `keyword_init:`
    # and `#[]`/`#[]=` with a Symbol key exactly like Hash's own bracket
    # access (`struct_aref_sym`/`struct_aset`, 3rd/mruby/mrbgems/
    # mruby-struct/src/struct.c), so every real consumer (lcf.rb/
    # lcf_file.rb's own `s[:type]`/`elem[:name]`/`schema[:elements] = ...`)
    # keeps working completely unchanged -- confirmed against the real
    # source, not assumed. Every real key this file's own entries actually
    # use, confirmed by parsing this file with RubyVM::AbstractSyntaxTree
    # and unioning every Hash-literal key set that included `:name` (not
    # guessed from reading a sample): `name`/`type` (932 entries each),
    # `default` (688), `elements` (115), `order` (3), `enums` (1) -- six
    # members total, in roughly descending frequency order below (member
    # order only matters for POSITIONAL `.new(...)` calls, which this file
    # never uses with `keyword_init: true`, but keeping it frequency-
    # ordered costs nothing and reads naturally).
    #
    # `enums:`/`order:` values stay ordinary Hash/Array literals (an
    # int->Symbol lookup table, a fixed field-name ordering) -- genuine
    # small maps/lists, not fixed-schema records themselves, so they were
    # never in scope for this same conversion.
    #
    # `sym2idx` is a SEVENTH member, never set by any literal entry in this
    # file (schema.rb itself never assigns it) -- it exists purely because
    # `LCF::Array1D#sym2idx` (mruby-lcf/mrblib/lcf.rb) memoizes a computed
    # name->chunk-id lookup table directly onto the schema entry object it
    # was handed, `@schema[:sym2idx] = @sym2idx`, the exact same "cache
    # onto the shared, persistent schema entry" trick `elements:` laziness
    # already relies on (see the `lazy` comment below). A plain Hash
    # tolerates an arbitrary extra key for free; a Struct does not (real,
    # confirmed behavior: `Struct#[]=` with an unknown member name raises
    # `NameError: no member 'x' in struct`, not a silent no-op) -- a real
    # crash this conversion would have introduced were this member left
    # out, caught by actually grepping every `\w+\[:\w+\]\s*=` bracket-
    # assignment site across this gem's own source, not just this file's
    # own literal key vocabulary.
    FieldSchema = Struct.new(:name, :type, :default, :elements, :order, :enums, :sym2idx, keyword_init: true)

    # Wraps a hash-literal block as lazily-built and self-memoizing: unlike
    # DATABASE's own per-entry `elements:` lambdas (LCF.elements_of in
    # lcf.rb caches the resolved Hash back onto the shared, persistent
    # schema entry that held the lambda), several of the constants below are
    # only ever consumed through a fresh, throwaway `{ elements: SAVE_X }`
    # wrapper built on every call (see mruby-rpg2k/mrblib/game.rb's
    # Game::State#to_lsd/.from_lsd) -- LCF.elements_of would cache onto that
    # throwaway wrapper, not onto SAVE_X's own constant binding, so the
    # block would otherwise re-run on every single save/load. `cache`, a
    # local captured by the returned lambda's own closure, survives across
    # calls to that same Proc object (the module-level constant itself)
    # regardless of which wrapper's #call reached it.
    def self.lazy(&block)
      cache = nil
      -> { cache ||= block.call }
    end

    COMMON_EVENT = {
      1 => FieldSchema.new(
        name: :name, type: :string, default: ''
      ),
      11 => FieldSchema.new(
        name: :start_term, type: :int, default: 5, enums: {
          3 => :auto_start,
          4 => :parallel,
          5 => :called,
        }
      ),
      12 => FieldSchema.new(
        name: :need_flag, type: :bool, default: false
      ),
      13 => FieldSchema.new(
        name: :switch_id, type: :int, default: 1
      ),
      21 => FieldSchema.new(
        name: :event_size, type: :int
      ),
      22 => FieldSchema.new(
        name: :event, type: :event
      ),
    }

    BGM = {
      1 => FieldSchema.new( name: :file, type: :string ),
      2 => FieldSchema.new( name: :fade_in, type: :int, default: 0 ),
      3 => FieldSchema.new( name: :volume, type: :int, default: 100 ),
      4 => FieldSchema.new( name: :pitch, type: :int, default: 100 ),
      5 => FieldSchema.new( name: :balance, type: :int, default: 50 ),
    }

    SE = {
      1 => FieldSchema.new( name: :file, type: :string ),
      3 => FieldSchema.new( name: :volume, type: :int, default: 100 ),
      4 => FieldSchema.new( name: :pitch, type: :int, default: 100 ),
      5 => FieldSchema.new( name: :balance, type: :int, default: 50 ),
    }

    # A single "skill learned at level" entry (used by actors and classes).
    LEARNING = {
      1 => FieldSchema.new( name: :level, type: :int, default: 1 ),
      2 => FieldSchema.new( name: :skill_id, type: :int, default: 1 ),
    }

    # Battler-animation attachment (使用時アニメ) shared by skills and items.
    # The アイテム and 特殊技能 pages document different fields of the same
    # object; this is their union. The weapon/movement fields (3, 4, 7-9, 12,
    # 13) are from the item page, the basic-CBA field (14) from the skill page.
    BATTLER_ANIMATION = {
      3 => FieldSchema.new( name: :weapon_cba, type: :int, default: 0 ),        # 武器CBAの選択 (2003)
      4 => FieldSchema.new( name: :weapon, type: :int, default: 0 ),            # 武器 (2003)
      5 => FieldSchema.new( name: :movement, type: :int, default: 0 ),          # 移動の選択
      6 => FieldSchema.new( name: :after_image, type: :bool, default: false ),  # 残像の選択
      7 => FieldSchema.new( name: :attack_times, type: :int, default: 0 ),      # 攻撃の回数 (2003)
      8 => FieldSchema.new( name: :ranged_weapon, type: :bool, default: false ),# 遠距離武器/使う (2003)
      9 => FieldSchema.new( name: :flying_animation, type: :int, default: 0 ),  # 飛行中のアニメの選択 (2003)
      12 => FieldSchema.new( name: :speed, type: :int, default: 0 ),            # 速度 (2003)
      13 => FieldSchema.new( name: :extension, type: :int, default: 1 ),        # 拡張 (2003)
      14 => FieldSchema.new( name: :battle_animation_id, type: :int, default: 3 ), # 基本CBAの選択
    }

    DATABASE = FieldSchema.new(
      name: :DataBase, type: :Array1D,
      elements: {
        11 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E4%B8%BB%E4%BA%BA%E5%85%AC
          name: :player, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :title, type: :string, default: '' ),
            3 => FieldSchema.new( name: :charset_name, type: :string, default: '' ),
            4 => FieldSchema.new( name: :charset_index, type: :int, default: 0 ),
            5 => FieldSchema.new( name: :semi_transparent, type: :bool, default: false ),
            7 => FieldSchema.new( name: :initial_level, type: :int, default: 1 ),
            8 => FieldSchema.new( name: :max_level, type: :int, default: -> { LCF.level_max } ),
            9 => FieldSchema.new( name: :has_critical_rate, type: :bool, default: true ),
            10 => FieldSchema.new( name: :critical_rate, type: :int, default: 30 ),

            15 => FieldSchema.new( name: :faceset_name, type: :string, default: '' ),
            16 => FieldSchema.new( name: :faceset_index, type: :int, default: 0 ),

            21 => FieldSchema.new( name: :double_hand, type: :bool, default: false ),       # 二刀流
            22 => FieldSchema.new( name: :equipment_fixed, type: :bool, default: false ),   # 装備固定
            23 => FieldSchema.new( name: :force_ai, type: :bool, default: false ),          # 強制AI
            24 => FieldSchema.new( name: :strong_defence, type: :bool, default: false ),    # 強力防御

            # `order:` names only the first six raw shorts -- a level-1-only
            # view real code never actually reads for a multi-level curve
            # (see Game::Actor#base_stats's own comment): the full raw array
            # is stat-major (six max_level-sized blocks, one per stat here),
            # confirmed against a genuine RPG_RT.exe, not row-major.
            31 => FieldSchema.new( name: :status, type: :int16_array, order: [:max_hp, :max_mp, :atk, :def, :int, :agi] ),

            41 => FieldSchema.new( name: :exp_basic, type: :int, default: -> { LCF.exp_default } ),
            42 => FieldSchema.new( name: :exp_increase, type: :int, default: -> { LCF.exp_default } ),
            43 => FieldSchema.new( name: :exp_correction, type: :int, default: -> { LCF.exp_default } ),

            51 => FieldSchema.new( name: :initial_equipment, type: :int16_array, order: [:weapon, :shield, :armor, :helmet, :accessory] ),

            56 => FieldSchema.new( name: :unarmed_animation, type: :int, default: 0 ),      # 素手戦闘アニメID
            57 => FieldSchema.new( name: :class_id, type: :int, default: 0 ),               # 職業ID (2003)
            59 => FieldSchema.new( name: :battle_x, type: :int, default: 0 ),               # 手動配置X (2003)
            60 => FieldSchema.new( name: :battle_y, type: :int, default: 0 ),               # 手動配置Y (2003)
            62 => FieldSchema.new( name: :battler_animation, type: :int, default: 0 ),      # id into chunk 32's battleranimations (2003)
            63 => FieldSchema.new( name: :skills, type: :Array2D, elements: LEARNING ),     # 習得する特殊技能
            66 => FieldSchema.new( name: :custom_battle_command, type: :bool, default: false ), # 独自戦闘コマンド有効 (2000)
            67 => FieldSchema.new( name: :custom_battle_command_name, type: :string ),      # 独自戦闘コマンド名称 (2000)

            71 => FieldSchema.new( name: :state_ranks_size, type: :int, default: 0 ),       # 状態有効度データ数
            72 => FieldSchema.new( name: :state_ranks, type: :int8_array ),                 # 状態有効度 (byte[])
            73 => FieldSchema.new( name: :attribute_ranks_size, type: :int, default: 0 ),   # 属性有効度データ数
            74 => FieldSchema.new( name: :attribute_ranks, type: :int8_array ),             # 属性有効度 (byte[])

            80 => FieldSchema.new( name: :battle_commands, type: :int32_array ),            # 戦闘コマンド (int[7], 2003)
          } }
        ),
        12 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E7%89%B9%E6%AE%8A%E6%8A%80%E8%83%BD
          name: :skill, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :description, type: :string, default: '' ),
            3 => FieldSchema.new( name: :using_message1, type: :string, default: '' ),
            4 => FieldSchema.new( name: :using_message2, type: :string, default: '' ),
            7 => FieldSchema.new( name: :failure_message, type: :int, default: 0 ),
            8 => FieldSchema.new( name: :type, type: :int, default: 0 ),
            9 => FieldSchema.new( name: :sp_type, type: :int, default: 0 ),
            10 => FieldSchema.new( name: :sp_percent, type: :int, default: 1 ),
            11 => FieldSchema.new( name: :sp_cost, type: :int, default: 0 ),
            12 => FieldSchema.new( name: :scope, type: :int, default: 0 ),
            13 => FieldSchema.new( name: :switch_id, type: :int, default: 1 ),              # ONにするスイッチ (種別: スイッチ)
            14 => FieldSchema.new( name: :animation_id, type: :int, default: 1 ),
            16 => FieldSchema.new( name: :sound_effect, type: :Array1D, elements: SE ),     # 効果音 (種別: テレポート/エスケープ/スイッチ)
            18 => FieldSchema.new( name: :occasion_field, type: :bool, default: true ),     # 使用可能な場面/フィールド
            19 => FieldSchema.new( name: :occasion_battle, type: :bool, default: false ),   # 使用可能な場面/バトル
            20 => FieldSchema.new( name: :reverse_state_effect, type: :bool, default: false ),
            21 => FieldSchema.new( name: :physical_rate, type: :int, default: 0 ),
            22 => FieldSchema.new( name: :magical_rate, type: :int, default: 3 ),
            23 => FieldSchema.new( name: :variance, type: :int, default: 4 ),
            24 => FieldSchema.new( name: :power, type: :int, default: 0 ),
            25 => FieldSchema.new( name: :hit, type: :int, default: 100 ),
            31 => FieldSchema.new( name: :affect_hp, type: :bool, default: false ),
            32 => FieldSchema.new( name: :affect_sp, type: :bool, default: false ),
            33 => FieldSchema.new( name: :affect_attack, type: :bool, default: false ),
            34 => FieldSchema.new( name: :affect_defense, type: :bool, default: false ),
            35 => FieldSchema.new( name: :affect_spirit, type: :bool, default: false ),
            36 => FieldSchema.new( name: :affect_agility, type: :bool, default: false ),
            37 => FieldSchema.new( name: :absorb_damage, type: :bool, default: false ),
            38 => FieldSchema.new( name: :ignore_defense, type: :bool, default: false ),
            41 => FieldSchema.new( name: :state_effects_size, type: :int, default: 0 ),
            42 => FieldSchema.new( name: :state_effects, type: :int8_array ),              # bool[]
            43 => FieldSchema.new( name: :attribute_effects_size, type: :int, default: 0 ),
            44 => FieldSchema.new( name: :attribute_effects, type: :int8_array ),          # bool[]
            45 => FieldSchema.new( name: :affect_attr_defence, type: :bool, default: false ),
            49 => FieldSchema.new( name: :battler_animation_data_size, type: :int, default: 0 ),
            50 => FieldSchema.new( name: :battler_animation_data, type: :Array2D, elements: BATTLER_ANIMATION ),
          } }
        ),
        13 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%82%A2%E3%82%A4%E3%83%86%E3%83%A0
          name: :item, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :description, type: :string, default: '' ),
            3 => FieldSchema.new( name: :type, type: :int, default: 0 ),
            5 => FieldSchema.new( name: :price, type: :int, default: 0 ),
            6 => FieldSchema.new( name: :uses, type: :int, default: 1 ),
            11 => FieldSchema.new( name: :atk_points1, type: :int, default: 0 ),
            12 => FieldSchema.new( name: :def_points1, type: :int, default: 0 ),
            13 => FieldSchema.new( name: :spi_points1, type: :int, default: 0 ),
            14 => FieldSchema.new( name: :agi_points1, type: :int, default: 0 ),
            15 => FieldSchema.new( name: :two_handed, type: :int, default: 0 ),
            16 => FieldSchema.new( name: :sp_cost, type: :int, default: 0 ),
            # The analysis notes list 0 as the omitted-value default (matching
            # their blanket assumption for most `ber` fields), but real
            # Nepheshel data contradicts it: 76 of its 104 weapons -- the
            # ordinary, never-hand-tuned ones, short sword included -- omit
            # this field entirely, while every weapon that *does* write it
            # spells out 70/80/85/98/100 and never 90. A weapon whose hit
            # rate silently defaulted to 0 would never land a single Attack,
            # which is not how the shipped game plays. 90 -- RPG2000's own
            # baseline hit rate, already used as the unarmed/no-weapon
            # fallback (Actor#attack_hit_rate) and the default enemy rate --
            # is what an unedited weapon actually carries.
            17 => FieldSchema.new( name: :hit, type: :int, default: 90 ),
            18 => FieldSchema.new( name: :critical_hit, type: :int, default: 0 ),
            20 => FieldSchema.new( name: :animation_id, type: :int, default: 1 ),
            21 => FieldSchema.new( name: :preemptive, type: :bool, default: false ),
            22 => FieldSchema.new( name: :dual_attack, type: :bool, default: false ),
            23 => FieldSchema.new( name: :attack_all, type: :bool, default: false ),
            24 => FieldSchema.new( name: :ignore_evasion, type: :bool, default: false ),
            25 => FieldSchema.new( name: :prevent_critical, type: :bool, default: false ),  # 必殺(痛恨の一撃)防止 (盾/鎧/兜/装飾品)
            26 => FieldSchema.new( name: :raise_evasion, type: :bool, default: false ),     # 物理攻撃の回避率アップ
            27 => FieldSchema.new( name: :half_sp_cost, type: :bool, default: false ),      # MP消費量半分
            28 => FieldSchema.new( name: :no_terrain_damage, type: :bool, default: false ), # 地形ダメージ無効
            29 => FieldSchema.new( name: :cursed, type: :bool, default: false ),
            31 => FieldSchema.new( name: :scope, type: :int, default: 0 ),
            32 => FieldSchema.new( name: :recover_hp_rate, type: :int, default: 0 ),
            33 => FieldSchema.new( name: :recover_hp, type: :int, default: 0 ),
            34 => FieldSchema.new( name: :recover_sp_rate, type: :int, default: 0 ),
            35 => FieldSchema.new( name: :recover_sp, type: :int, default: 0 ),
            37 => FieldSchema.new( name: :occasion_field1, type: :bool, default: false ),
            38 => FieldSchema.new( name: :ko_only, type: :bool, default: false ),
            41 => FieldSchema.new( name: :max_hp_points, type: :int, default: 0 ),
            42 => FieldSchema.new( name: :max_sp_points, type: :int, default: 0 ),
            43 => FieldSchema.new( name: :atk_points2, type: :int, default: 0 ),
            44 => FieldSchema.new( name: :def_points2, type: :int, default: 0 ),
            45 => FieldSchema.new( name: :spi_points2, type: :int, default: 0 ),
            46 => FieldSchema.new( name: :agi_points2, type: :int, default: 0 ),
            51 => FieldSchema.new( name: :using_message, type: :int, default: 0 ),
            53 => FieldSchema.new( name: :skill_id, type: :int, default: 1 ),
            55 => FieldSchema.new( name: :switch_id, type: :int, default: 1 ),
            57 => FieldSchema.new( name: :occasion_field2, type: :bool, default: true ),
            58 => FieldSchema.new( name: :occasion_battle, type: :bool, default: false ),
            61 => FieldSchema.new( name: :actor_set_size, type: :int, default: 0 ),
            62 => FieldSchema.new( name: :actor_set, type: :int8_array ),                  # bool[]
            63 => FieldSchema.new( name: :state_set_size, type: :int, default: 0 ),
            64 => FieldSchema.new( name: :state_set, type: :int8_array ),                  # bool[]
            65 => FieldSchema.new( name: :attribute_set_size, type: :int, default: 0 ),
            66 => FieldSchema.new( name: :attribute_set, type: :int8_array ),              # bool[]
            67 => FieldSchema.new( name: :state_chance, type: :int, default: 0 ),
            68 => FieldSchema.new( name: :reverse_state_effect, type: :bool, default: false ),
            69 => FieldSchema.new( name: :animation_data_size, type: :int, default: 0 ),
            70 => FieldSchema.new( name: :animation_data, type: :Array2D, elements: BATTLER_ANIMATION ),
            71 => FieldSchema.new( name: :use_skill, type: :bool, default: false ),
            72 => FieldSchema.new( name: :class_set_size, type: :int, default: 0 ),
            73 => FieldSchema.new( name: :class_set, type: :int8_array ),                  # bool[]
          } }
        ),
        14 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%95%B5%E3%82%AD%E3%83%A3%E3%83%A9
          name: :enemy, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :battler_name, type: :string, default: '' ),
            3 => FieldSchema.new( name: :battler_hue, type: :int, default: 0 ),
            4 => FieldSchema.new( name: :max_hp, type: :int, default: 10 ),
            5 => FieldSchema.new( name: :max_sp, type: :int, default: 10 ),
            6 => FieldSchema.new( name: :attack, type: :int, default: 10 ),
            7 => FieldSchema.new( name: :defense, type: :int, default: 10 ),
            8 => FieldSchema.new( name: :spirit, type: :int, default: 10 ),
            9 => FieldSchema.new( name: :agility, type: :int, default: 10 ),
            10 => FieldSchema.new( name: :transparent, type: :bool, default: false ),
            11 => FieldSchema.new( name: :exp, type: :int, default: 0 ),
            12 => FieldSchema.new( name: :gold, type: :int, default: 0 ),
            13 => FieldSchema.new( name: :drop_id, type: :int, default: 0 ),
            14 => FieldSchema.new( name: :drop_prob, type: :int, default: 100 ),
            21 => FieldSchema.new( name: :critical_hit, type: :bool, default: false ),
            22 => FieldSchema.new( name: :critical_hit_chance, type: :int, default: 30 ),
            26 => FieldSchema.new( name: :miss, type: :bool, default: false ),
            28 => FieldSchema.new( name: :levitate, type: :bool, default: false ),
            31 => FieldSchema.new( name: :state_ranks_size, type: :int, default: 0 ),
            32 => FieldSchema.new( name: :state_ranks, type: :int8_array ),               # byte[]
            33 => FieldSchema.new( name: :attribute_ranks_size, type: :int, default: 0 ),
            34 => FieldSchema.new( name: :attribute_ranks, type: :int8_array ),           # byte[]
            42 => FieldSchema.new(
              name: :actions, type: :Array2D,
              elements: {
                1 => FieldSchema.new( name: :kind, type: :int, default: 0 ),
                2 => FieldSchema.new( name: :basic, type: :int, default: 0 ),
                3 => FieldSchema.new( name: :skill_id, type: :int, default: 1 ),
                4 => FieldSchema.new( name: :enemy_id, type: :int, default: 1 ),
                5 => FieldSchema.new( name: :condition_type, type: :int, default: 0 ),
                6 => FieldSchema.new( name: :condition_param1, type: :int, default: 0 ),
                7 => FieldSchema.new( name: :condition_param2, type: :int, default: 0 ),
                8 => FieldSchema.new( name: :switch_id, type: :int, default: 1 ),
                9 => FieldSchema.new( name: :switch_on, type: :bool, default: false ),
                10 => FieldSchema.new( name: :switch_on_id, type: :int, default: 1 ),
                11 => FieldSchema.new( name: :switch_off, type: :bool, default: false ),
                12 => FieldSchema.new( name: :switch_off_id, type: :int, default: 1 ),
                13 => FieldSchema.new( name: :rating, type: :int, default: 50 ),
              }
            ),
          } }
        ),
        15 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%95%B5%E3%82%B0%E3%83%AB%E3%83%BC%E3%83%97
          name: :enemy_group, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new(
              name: :members, type: :Array2D,
              elements: {
                1 => FieldSchema.new( name: :enemy_id, type: :int, default: 1 ),
                2 => FieldSchema.new( name: :x, type: :int, default: 0 ),
                3 => FieldSchema.new( name: :y, type: :int, default: 0 ),
                4 => FieldSchema.new( name: :invisible, type: :bool, default: false ),
              }
            ),
            4 => FieldSchema.new( name: :terrain_data_size, type: :int, default: 0 ),
            5 => FieldSchema.new( name: :terrain_set, type: :int8_array ),                # bool[]
            # ランダムに出現 (Appear Randomly): rolled once at battle start,
            # see Game::Troop#apply_appear_randomly (mruby-rpg2k/mrblib/game.rb).
            6 => FieldSchema.new( name: :appear_randomly, type: :bool, default: false ),
            11 => FieldSchema.new(
              name: :pages, type: :Array2D,
              elements: {
                2 => FieldSchema.new(
                  name: :condition, type: :Array1D,
                  elements: {
                    1 => FieldSchema.new( name: :flags, type: :int, default: 0 ),
                    2 => FieldSchema.new( name: :switch_a_id, type: :int, default: 1 ),
                    3 => FieldSchema.new( name: :switch_b_id, type: :int, default: 1 ),
                    4 => FieldSchema.new( name: :variable_id, type: :int, default: 1 ),
                    5 => FieldSchema.new( name: :variable_value, type: :int, default: 0 ),
                    6 => FieldSchema.new( name: :turn_a, type: :int, default: 0 ),
                    7 => FieldSchema.new( name: :turn_b, type: :int, default: 0 ),
                    8 => FieldSchema.new( name: :fatigue_min, type: :int, default: 0 ),
                    9 => FieldSchema.new( name: :fatigue_max, type: :int, default: 100 ),
                    10 => FieldSchema.new( name: :enemy_id, type: :int, default: 0 ),
                    11 => FieldSchema.new( name: :enemy_hp_min, type: :int, default: 0 ),
                    12 => FieldSchema.new( name: :enemy_hp_max, type: :int, default: 100 ),
                    13 => FieldSchema.new( name: :actor_id, type: :int, default: 1 ),
                    14 => FieldSchema.new( name: :actor_hp_min, type: :int, default: 0 ),
                    15 => FieldSchema.new( name: :actor_hp_max, type: :int, default: 100 ),
                    16 => FieldSchema.new( name: :turn_enemy_id, type: :int, default: 0 ),
                    17 => FieldSchema.new( name: :turn_enemy_a, type: :int, default: 0 ),
                    18 => FieldSchema.new( name: :turn_enemy_b, type: :int, default: 0 ),
                    19 => FieldSchema.new( name: :turn_actor_id, type: :int, default: 1 ),
                    20 => FieldSchema.new( name: :turn_actor_a, type: :int, default: 0 ),
                    21 => FieldSchema.new( name: :turn_actor_b, type: :int, default: 0 ),
                    22 => FieldSchema.new( name: :command_actor_id, type: :int, default: 1 ),
                    23 => FieldSchema.new( name: :command_id, type: :int, default: 1 ),
                  }
                ),
                11 => FieldSchema.new( name: :event_size, type: :int, default: 4 ),
                12 => FieldSchema.new( name: :event, type: :event ),
              }
            ),
          } }
        ),
        16 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E5%9C%B0%E5%BD%A2
          name: :terrain, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :damage, type: :int, default: 0 ),
            3 => FieldSchema.new( name: :encounter_rate, type: :int, default: 100 ),
            4 => FieldSchema.new( name: :background_name, type: :string, default: '' ),
            5 => FieldSchema.new( name: :boat_pass, type: :bool, default: false ),
            6 => FieldSchema.new( name: :ship_pass, type: :bool, default: false ),
            7 => FieldSchema.new( name: :airship_pass, type: :bool, default: true ),
            9 => FieldSchema.new( name: :airship_land, type: :bool, default: true ),
            11 => FieldSchema.new( name: :bush_depth, type: :int, default: 0 ),
            # RPG2003 field 0x0F is a full `Sound` struct (filename + volume +
            # tempo + balance, liblcf's own `generator/csv/fields.csv`:
            # `Terrain,footstep,f,Sound,0x0F,...`), not a bare filename --
            # the same shape every other Sound-typed database field here
            # already uses (see `SE` above).
            15 => FieldSchema.new( name: :footstep, type: :Array1D, elements: SE ),
            16 => FieldSchema.new( name: :on_damage_se, type: :bool, default: false ),
            17 => FieldSchema.new( name: :background_type, type: :int, default: 0 ),
            21 => FieldSchema.new( name: :background_a_name, type: :string, default: '' ),
            22 => FieldSchema.new( name: :background_a_scrollh, type: :bool, default: false ),
            23 => FieldSchema.new( name: :background_a_scrollv, type: :bool, default: false ),
            24 => FieldSchema.new( name: :background_a_scrollh_speed, type: :int, default: 0 ),
            25 => FieldSchema.new( name: :background_a_scrollv_speed, type: :int, default: 0 ),
            30 => FieldSchema.new( name: :background_b, type: :bool, default: false ),
            31 => FieldSchema.new( name: :background_b_name, type: :string, default: '' ),
            32 => FieldSchema.new( name: :background_b_scrollh, type: :bool, default: false ),
            33 => FieldSchema.new( name: :background_b_scrollv, type: :bool, default: false ),
            34 => FieldSchema.new( name: :background_b_scrollh_speed, type: :int, default: 0 ),
            35 => FieldSchema.new( name: :background_b_scrollv_speed, type: :int, default: 0 ),
            40 => FieldSchema.new( name: :special_flags, type: :int, default: 0 ),
            41 => FieldSchema.new( name: :special_back_party, type: :int, default: 15 ),
            42 => FieldSchema.new( name: :special_back_enemies, type: :int, default: 10 ),
            43 => FieldSchema.new( name: :special_lateral_party, type: :int, default: 10 ),
            44 => FieldSchema.new( name: :special_lateral_enemies, type: :int, default: 5 ),
            45 => FieldSchema.new( name: :grid_location, type: :int, default: 0 ),
            46 => FieldSchema.new( name: :grid_top_y, type: :int, default: 0 ),
            47 => FieldSchema.new( name: :grid_elongation, type: :int, default: 375 ),
            48 => FieldSchema.new( name: :grid_inclination, type: :int, default: 16400 ),
          } }
        ),
        17 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E5%B1%9E%E6%80%A7
          name: :property, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :type, type: :int, default: 0 ),      # 0: weapon, 1: magic
            11 => FieldSchema.new( name: :a_rate, type: :int, default: 300 ),
            12 => FieldSchema.new( name: :b_rate, type: :int, default: 200 ),
            13 => FieldSchema.new( name: :c_rate, type: :int, default: 100 ),
            14 => FieldSchema.new( name: :d_rate, type: :int, default: 50 ),
            15 => FieldSchema.new( name: :e_rate, type: :int, default: 0 ),
          } }
        ),
        18 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E7%8A%B6%E6%85%8B
          name: :situation, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :type, type: :int, default: 0 ),      # 0: battle only, 1: also on map
            3 => FieldSchema.new( name: :color, type: :int, default: 6 ),
            4 => FieldSchema.new( name: :priority, type: :int, default: 50 ),
            5 => FieldSchema.new( name: :restriction, type: :int, default: 0 ),
            11 => FieldSchema.new( name: :a_rate, type: :int, default: 100 ),
            12 => FieldSchema.new( name: :b_rate, type: :int, default: 80 ),
            13 => FieldSchema.new( name: :c_rate, type: :int, default: 60 ),
            14 => FieldSchema.new( name: :d_rate, type: :int, default: 30 ),
            15 => FieldSchema.new( name: :e_rate, type: :int, default: 0 ),
            21 => FieldSchema.new( name: :hold_turn, type: :int, default: 0 ),
            22 => FieldSchema.new( name: :auto_release_prob, type: :int, default: 0 ),
            23 => FieldSchema.new( name: :release_by_attack, type: :int, default: 0 ),
            30 => FieldSchema.new( name: :affect_type, type: :int, default: 2 ),   # 0 halve/1 double/2 no change
            31 => FieldSchema.new( name: :affect_attack, type: :bool, default: false ),
            32 => FieldSchema.new( name: :affect_defense, type: :bool, default: false ),
            33 => FieldSchema.new( name: :affect_spirit, type: :bool, default: false ),
            34 => FieldSchema.new( name: :affect_agility, type: :bool, default: false ),
            35 => FieldSchema.new( name: :reduce_hit_ratio, type: :int, default: 100 ),
            36 => FieldSchema.new( name: :avoid_attacks, type: :bool, default: false ),      # 2003
            37 => FieldSchema.new( name: :reflect_magic, type: :bool, default: false ),      # 2003
            38 => FieldSchema.new( name: :cursed, type: :bool, default: false ),             # 2003
            39 => FieldSchema.new( name: :battler_animation_id, type: :int, default: 6 ),    # 2003
            41 => FieldSchema.new( name: :restrict_skill, type: :bool, default: false ),
            42 => FieldSchema.new( name: :restrict_skill_level, type: :int, default: 0 ),
            43 => FieldSchema.new( name: :restrict_magic, type: :bool, default: false ),
            44 => FieldSchema.new( name: :restrict_magic_level, type: :int, default: 0 ),
            45 => FieldSchema.new( name: :hp_change_type, type: :int, default: 0 ),          # 2003
            46 => FieldSchema.new( name: :sp_change_type, type: :int, default: 0 ),          # 2003
            51 => FieldSchema.new( name: :message_actor, type: :string, default: '' ),       # 2000
            52 => FieldSchema.new( name: :message_enemy, type: :string, default: '' ),       # 2000
            53 => FieldSchema.new( name: :message_already, type: :string, default: '' ),     # 2000
            54 => FieldSchema.new( name: :message_affected, type: :string, default: '' ),    # 2000
            55 => FieldSchema.new( name: :message_recovery, type: :string, default: '' ),    # 2000
            61 => FieldSchema.new( name: :hp_change_max, type: :int, default: 0 ),
            62 => FieldSchema.new( name: :hp_change_val, type: :int, default: 0 ),
            63 => FieldSchema.new( name: :hp_change_map_steps, type: :int, default: 0 ),
            64 => FieldSchema.new( name: :hp_change_map_val, type: :int, default: 0 ),
            65 => FieldSchema.new( name: :sp_change_max, type: :int, default: 0 ),
            66 => FieldSchema.new( name: :sp_change_val, type: :int, default: 0 ),
            67 => FieldSchema.new( name: :sp_change_map_steps, type: :int, default: 0 ),
            68 => FieldSchema.new( name: :sp_change_map_val, type: :int, default: 0 ),
          } }
        ),
        19 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%88%A6%E9%97%98%E3%82%A2%E3%83%8B%E3%83%A1
          name: :battle_anime, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :animation_name, type: :string, default: '' ),
            3 => FieldSchema.new( name: :large, type: :int, default: 0 ),     # 2003; 0: 480x480, 1: 640x640
            6 => FieldSchema.new(
              name: :timings, type: :Array2D,
              elements: {
                1 => FieldSchema.new( name: :frame, type: :int, default: 0 ),
                2 => FieldSchema.new( name: :se, type: :Array1D, elements: SE ),
                3 => FieldSchema.new( name: :flash_scope, type: :int, default: 0 ),   # 0 none/1 target/2 screen
                4 => FieldSchema.new( name: :flash_red, type: :int, default: 31 ),
                5 => FieldSchema.new( name: :flash_green, type: :int, default: 31 ),
                6 => FieldSchema.new( name: :flash_blue, type: :int, default: 31 ),
                7 => FieldSchema.new( name: :flash_power, type: :int, default: 0 ),
                8 => FieldSchema.new( name: :screen_shaking, type: :int, default: 0 ), # 2003
              }
            ),
            9 => FieldSchema.new( name: :scope, type: :int, default: 0 ),     # 0: single, 1: all
            10 => FieldSchema.new( name: :position, type: :int, default: 1 ), # 0 head/1 center/2 feet
            11 => FieldSchema.new( name: :grid, type: :bool, default: true ),
            12 => FieldSchema.new(
              name: :frames, type: :Array2D,
              elements: {
                1 => FieldSchema.new(
                  name: :cells, type: :Array2D,
                  elements: {
                    1 => FieldSchema.new( name: :visible, type: :bool, default: true ),
                    2 => FieldSchema.new( name: :cell_id, type: :int, default: 0 ),
                    3 => FieldSchema.new( name: :x, type: :int, default: 0 ),
                    4 => FieldSchema.new( name: :y, type: :int, default: 0 ),
                    5 => FieldSchema.new( name: :zoom, type: :int, default: 100 ),
                    6 => FieldSchema.new( name: :tone_red, type: :int, default: 100 ),
                    7 => FieldSchema.new( name: :tone_green, type: :int, default: 100 ),
                    8 => FieldSchema.new( name: :tone_blue, type: :int, default: 100 ),
                    9 => FieldSchema.new( name: :tone_gray, type: :int, default: 100 ),
                    10 => FieldSchema.new( name: :transparency, type: :int, default: 0 ),
                  }
                ),
              }
            ),
          } }
        ),
        20 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%83%81%E3%83%83%E3%83%97%E3%82%BB%E3%83%83%E3%83%88
          name: :chipset, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :chipset_name, type: :string, default: '' ),
            3 => FieldSchema.new( name: :terrain_data, type: :int16_array ),        # 地形ID (short[162])
            4 => FieldSchema.new( name: :passable_data_lower, type: :int8_array ),  # 下層通行 (byte[162])
            5 => FieldSchema.new( name: :passable_data_upper, type: :int8_array ),  # 上層通行 (byte[144])
            11 => FieldSchema.new( name: :animation_type, type: :int, default: 0 ), # 水アニメパターン
            12 => FieldSchema.new( name: :animation_speed, type: :int, default: 0 ), # 水アニメ速度
          } }
        ),
        21 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E7%94%A8%E8%AA%9E
          name: :term, type: :Array1D,
          elements: -> { {
            # Battle messages
            1 => FieldSchema.new( name: :encounter, type: :string, default: '' ),
            2 => FieldSchema.new( name: :special_combat, type: :string, default: '' ),
            3 => FieldSchema.new( name: :escape_success, type: :string, default: '' ),
            4 => FieldSchema.new( name: :escape_failure, type: :string, default: '' ),
            5 => FieldSchema.new( name: :victory, type: :string, default: '' ),
            6 => FieldSchema.new( name: :defeat, type: :string, default: '' ),
            7 => FieldSchema.new( name: :exp_received, type: :string, default: '' ),
            8 => FieldSchema.new( name: :gold_received_a, type: :string, default: '' ),
            9 => FieldSchema.new( name: :gold_received_b, type: :string, default: '' ),
            10 => FieldSchema.new( name: :item_received, type: :string, default: '' ),
            11 => FieldSchema.new( name: :attacking, type: :string, default: '' ),
            12 => FieldSchema.new( name: :actor_critical, type: :string, default: '' ),
            13 => FieldSchema.new( name: :enemy_critical, type: :string, default: '' ),
            14 => FieldSchema.new( name: :defending, type: :string, default: '' ),
            15 => FieldSchema.new( name: :observing, type: :string, default: '' ),
            16 => FieldSchema.new( name: :focus, type: :string, default: '' ),
            17 => FieldSchema.new( name: :autodestruction, type: :string, default: '' ),
            18 => FieldSchema.new( name: :enemy_escape, type: :string, default: '' ),
            19 => FieldSchema.new( name: :enemy_transform, type: :string, default: '' ),
            20 => FieldSchema.new( name: :enemy_damaged, type: :string, default: '' ),
            21 => FieldSchema.new( name: :enemy_undamaged, type: :string, default: '' ),
            22 => FieldSchema.new( name: :actor_damaged, type: :string, default: '' ),
            23 => FieldSchema.new( name: :actor_undamaged, type: :string, default: '' ),
            24 => FieldSchema.new( name: :skill_failure_a, type: :string, default: '' ),
            25 => FieldSchema.new( name: :skill_failure_b, type: :string, default: '' ),
            26 => FieldSchema.new( name: :skill_failure_c, type: :string, default: '' ),
            27 => FieldSchema.new( name: :dodge, type: :string, default: '' ),
            28 => FieldSchema.new( name: :use_item, type: :string, default: '' ),
            29 => FieldSchema.new( name: :hp_recovery, type: :string, default: '' ),
            30 => FieldSchema.new( name: :parameter_increase, type: :string, default: '' ),
            31 => FieldSchema.new( name: :parameter_decrease, type: :string, default: '' ),
            32 => FieldSchema.new( name: :enemy_hp_absorbed, type: :string, default: '' ),
            33 => FieldSchema.new( name: :actor_hp_absorbed, type: :string, default: '' ),
            34 => FieldSchema.new( name: :resistance_increase, type: :string, default: '' ),
            35 => FieldSchema.new( name: :resistance_decrease, type: :string, default: '' ),
            36 => FieldSchema.new( name: :level_up, type: :string, default: '' ),
            37 => FieldSchema.new( name: :skill_learned, type: :string, default: '' ),
            38 => FieldSchema.new( name: :battle_start, type: :string, default: '' ),  # 2003
            39 => FieldSchema.new( name: :miss, type: :string, default: '' ),          # 2003

            # Shop A
            41 => FieldSchema.new( name: :shop_greeting1, type: :string, default: '' ),
            42 => FieldSchema.new( name: :shop_regreeting1, type: :string, default: '' ),
            43 => FieldSchema.new( name: :shop_buy1, type: :string, default: '' ),
            44 => FieldSchema.new( name: :shop_sell1, type: :string, default: '' ),
            45 => FieldSchema.new( name: :shop_leave1, type: :string, default: '' ),
            46 => FieldSchema.new( name: :shop_buy_select1, type: :string, default: '' ),
            47 => FieldSchema.new( name: :shop_buy_number1, type: :string, default: '' ),
            48 => FieldSchema.new( name: :shop_purchased1, type: :string, default: '' ),
            49 => FieldSchema.new( name: :shop_sell_select1, type: :string, default: '' ),
            50 => FieldSchema.new( name: :shop_sell_number1, type: :string, default: '' ),
            51 => FieldSchema.new( name: :shop_sold1, type: :string, default: '' ),

            # Shop B
            54 => FieldSchema.new( name: :shop_greeting2, type: :string, default: '' ),
            55 => FieldSchema.new( name: :shop_regreeting2, type: :string, default: '' ),
            56 => FieldSchema.new( name: :shop_buy2, type: :string, default: '' ),
            57 => FieldSchema.new( name: :shop_sell2, type: :string, default: '' ),
            58 => FieldSchema.new( name: :shop_leave2, type: :string, default: '' ),
            59 => FieldSchema.new( name: :shop_buy_select2, type: :string, default: '' ),
            60 => FieldSchema.new( name: :shop_buy_number2, type: :string, default: '' ),
            61 => FieldSchema.new( name: :shop_purchased2, type: :string, default: '' ),
            62 => FieldSchema.new( name: :shop_sell_select2, type: :string, default: '' ),
            63 => FieldSchema.new( name: :shop_sell_number2, type: :string, default: '' ),
            64 => FieldSchema.new( name: :shop_sold2, type: :string, default: '' ),

            # Shop C
            67 => FieldSchema.new( name: :shop_greeting3, type: :string, default: '' ),
            68 => FieldSchema.new( name: :shop_regreeting3, type: :string, default: '' ),
            69 => FieldSchema.new( name: :shop_buy3, type: :string, default: '' ),
            70 => FieldSchema.new( name: :shop_sell3, type: :string, default: '' ),
            71 => FieldSchema.new( name: :shop_leave3, type: :string, default: '' ),
            72 => FieldSchema.new( name: :shop_buy_select3, type: :string, default: '' ),
            73 => FieldSchema.new( name: :shop_buy_number3, type: :string, default: '' ),
            74 => FieldSchema.new( name: :shop_purchased3, type: :string, default: '' ),
            75 => FieldSchema.new( name: :shop_sell_select3, type: :string, default: '' ),
            76 => FieldSchema.new( name: :shop_sell_number3, type: :string, default: '' ),
            77 => FieldSchema.new( name: :shop_sold3, type: :string, default: '' ),

            # Inn A
            80 => FieldSchema.new( name: :inn_a_greeting_1, type: :string, default: '' ),
            81 => FieldSchema.new( name: :inn_a_greeting_2, type: :string, default: '' ),
            82 => FieldSchema.new( name: :inn_a_greeting_3, type: :string, default: '' ),
            83 => FieldSchema.new( name: :inn_a_accept, type: :string, default: '' ),
            84 => FieldSchema.new( name: :inn_a_cancel, type: :string, default: '' ),

            # Inn B
            85 => FieldSchema.new( name: :inn_b_greeting_1, type: :string, default: '' ),
            86 => FieldSchema.new( name: :inn_b_greeting_2, type: :string, default: '' ),
            87 => FieldSchema.new( name: :inn_b_greeting_3, type: :string, default: '' ),
            88 => FieldSchema.new( name: :inn_b_accept, type: :string, default: '' ),
            89 => FieldSchema.new( name: :inn_b_cancel, type: :string, default: '' ),

            # Item / currency labels
            92 => FieldSchema.new( name: :possessed_items, type: :string, default: '' ),
            93 => FieldSchema.new( name: :equipped_items, type: :string, default: '' ),
            95 => FieldSchema.new( name: :gold, type: :string, default: '' ),

            # Battle command menu
            101 => FieldSchema.new( name: :battle_fight, type: :string, default: '' ),
            102 => FieldSchema.new( name: :battle_auto, type: :string, default: '' ),
            103 => FieldSchema.new( name: :battle_escape, type: :string, default: '' ),
            104 => FieldSchema.new( name: :battle_attack, type: :string, default: '' ),
            105 => FieldSchema.new( name: :battle_defend, type: :string, default: '' ),
            106 => FieldSchema.new( name: :battle_item, type: :string, default: '' ),
            107 => FieldSchema.new( name: :battle_skill, type: :string, default: '' ),
            108 => FieldSchema.new( name: :battle_equipment, type: :string, default: '' ),
            110 => FieldSchema.new( name: :battle_save, type: :string, default: '' ),
            112 => FieldSchema.new( name: :battle_end_game, type: :string, default: '' ),

            # Title menu
            114 => FieldSchema.new( name: :new_game, type: :string, default: '' ),
            115 => FieldSchema.new( name: :continue, type: :string, default: '' ),
            117 => FieldSchema.new( name: :shutdown, type: :string, default: '' ),

            # Main menu (2003)
            118 => FieldSchema.new( name: :status, type: :string, default: '' ),
            119 => FieldSchema.new( name: :row, type: :string, default: '' ),
            120 => FieldSchema.new( name: :order, type: :string, default: '' ),
            121 => FieldSchema.new( name: :wait_on, type: :string, default: '' ),
            122 => FieldSchema.new( name: :wait_off, type: :string, default: '' ),

            # Status terms
            123 => FieldSchema.new( name: :level, type: :string, default: '' ),
            124 => FieldSchema.new( name: :hp, type: :string, default: '' ),
            125 => FieldSchema.new( name: :mp, type: :string, default: '' ),
            126 => FieldSchema.new( name: :normal_status, type: :string, default: '' ),
            127 => FieldSchema.new( name: :exp_short, type: :string, default: '' ),
            128 => FieldSchema.new( name: :level_short, type: :string, default: '' ),
            129 => FieldSchema.new( name: :hp_short, type: :string, default: '' ),
            130 => FieldSchema.new( name: :mp_short, type: :string, default: '' ),
            131 => FieldSchema.new( name: :mp_cost, type: :string, default: '' ),
            132 => FieldSchema.new( name: :attack, type: :string, default: '' ),
            133 => FieldSchema.new( name: :defense, type: :string, default: '' ),
            134 => FieldSchema.new( name: :mind, type: :string, default: '' ),
            135 => FieldSchema.new( name: :agility, type: :string, default: '' ),
            136 => FieldSchema.new( name: :weapon, type: :string, default: '' ),
            137 => FieldSchema.new( name: :shield, type: :string, default: '' ),
            138 => FieldSchema.new( name: :armor, type: :string, default: '' ),
            139 => FieldSchema.new( name: :helmet, type: :string, default: '' ),
            140 => FieldSchema.new( name: :accessory, type: :string, default: '' ),

            # Save / load
            146 => FieldSchema.new( name: :save_file_select, type: :string, default: '' ),
            147 => FieldSchema.new( name: :load_file_select, type: :string, default: '' ),
            148 => FieldSchema.new( name: :file, type: :string, default: '' ),
            151 => FieldSchema.new( name: :end_game_confirm, type: :string, default: '' ),
            152 => FieldSchema.new( name: :yes, type: :string, default: '' ),
            153 => FieldSchema.new( name: :no, type: :string, default: '' ),
          } }
        ),
        22 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%82%B7%E3%82%B9%E3%83%86%E3%83%A0
          name: :system, type: :Array1D,
          elements: -> { {
            10 => FieldSchema.new( name: :maker_version, type: :int ),                    # 使用ツクールバージョン
            11 => FieldSchema.new( name: :boat_name, type: :string, default: '' ),
            12 => FieldSchema.new( name: :ship_name, type: :string, default: '' ),
            13 => FieldSchema.new( name: :airship_name, type: :string, default: '' ),
            14 => FieldSchema.new( name: :boat_index, type: :int, default: 0 ),
            15 => FieldSchema.new( name: :ship_index, type: :int, default: 0 ),
            16 => FieldSchema.new( name: :airship_index, type: :int, default: 0 ),
            17 => FieldSchema.new( name: :title, type: :string, default: '' ),            # タイトルグラフィック
            18 => FieldSchema.new( name: :gameover_name, type: :string, default: '' ),
            # System graphic that supplies the window skin (background, frame
            # border and selection cursor).
            19 => FieldSchema.new( name: :system_graphic, type: :string ),                # システムグラフィック
            20 => FieldSchema.new( name: :system2_name, type: :string, default: '' ),     # 2003
            21 => FieldSchema.new( name: :party_size, type: :int, default: 0 ),
            22 => FieldSchema.new( name: :party, type: :int16_array ),                    # 初期パーティ (short[])
            26 => FieldSchema.new( name: :menu_commands_size, type: :int, default: 0 ),   # 2003
            27 => FieldSchema.new( name: :menu_commands, type: :int16_array ),            # 2003

            # BGM
            31 => FieldSchema.new( name: :title_music, type: :Array1D, elements: BGM ),
            32 => FieldSchema.new( name: :battle_music, type: :Array1D, elements: BGM ),
            33 => FieldSchema.new( name: :battle_end_music, type: :Array1D, elements: BGM ),
            34 => FieldSchema.new( name: :inn_music, type: :Array1D, elements: BGM ),
            35 => FieldSchema.new( name: :boat_music, type: :Array1D, elements: BGM ),
            36 => FieldSchema.new( name: :ship_music, type: :Array1D, elements: BGM ),
            37 => FieldSchema.new( name: :airship_music, type: :Array1D, elements: BGM ),
            38 => FieldSchema.new( name: :gameover_music, type: :Array1D, elements: BGM ),

            # Sound effects
            41 => FieldSchema.new( name: :cursor_se, type: :Array1D, elements: SE ),
            42 => FieldSchema.new( name: :decision_se, type: :Array1D, elements: SE ),
            43 => FieldSchema.new( name: :cancel_se, type: :Array1D, elements: SE ),
            44 => FieldSchema.new( name: :buzzer_se, type: :Array1D, elements: SE ),
            45 => FieldSchema.new( name: :battle_se, type: :Array1D, elements: SE ),
            46 => FieldSchema.new( name: :escape_se, type: :Array1D, elements: SE ),
            47 => FieldSchema.new( name: :enemy_attack_se, type: :Array1D, elements: SE ),
            48 => FieldSchema.new( name: :enemy_damaged_se, type: :Array1D, elements: SE ),
            49 => FieldSchema.new( name: :actor_damaged_se, type: :Array1D, elements: SE ),
            50 => FieldSchema.new( name: :dodge_se, type: :Array1D, elements: SE ),
            51 => FieldSchema.new( name: :enemy_death_se, type: :Array1D, elements: SE ),
            52 => FieldSchema.new( name: :item_se, type: :Array1D, elements: SE ),

            # Transitions
            61 => FieldSchema.new( name: :transition_out, type: :int, default: 0 ),
            62 => FieldSchema.new( name: :transition_in, type: :int, default: 0 ),
            63 => FieldSchema.new( name: :battle_start_fadeout, type: :int, default: 0 ),
            64 => FieldSchema.new( name: :battle_start_fadein, type: :int, default: 0 ),
            65 => FieldSchema.new( name: :battle_end_fadeout, type: :int, default: 0 ),
            66 => FieldSchema.new( name: :battle_end_fadein, type: :int, default: 0 ),

            # System graphic settings
            71 => FieldSchema.new( name: :message_stretch, type: :int, default: 0 ),
            72 => FieldSchema.new( name: :font_id, type: :int, default: 0 ),

            # Battle animation editor leftovers
            81 => FieldSchema.new( name: :selected_condition, type: :int, default: 1 ),
            82 => FieldSchema.new( name: :selected_hero, type: :int, default: 1 ),

            # Battle test
            84 => FieldSchema.new( name: :battle_test_background, type: :string, default: '' ),
            85 => FieldSchema.new(
              name: :battle_test_data, type: :Array2D,
              elements: {
                1 => FieldSchema.new( name: :actor_id, type: :int, default: 1 ),
                2 => FieldSchema.new( name: :level, type: :int, default: 1 ),
                11 => FieldSchema.new( name: :weapon_id, type: :int, default: 0 ),
                12 => FieldSchema.new( name: :shield_id, type: :int, default: 0 ),
                13 => FieldSchema.new( name: :armor_id, type: :int, default: 0 ),
                14 => FieldSchema.new( name: :helmet_id, type: :int, default: 0 ),
                15 => FieldSchema.new( name: :accessory_id, type: :int, default: 0 ),
              }
            ),

            91 => FieldSchema.new( name: :saved_times, type: :int, default: 0 ),

            # Battle test position (2003)
            94 => FieldSchema.new( name: :battle_test_terrain, type: :int, default: 0 ),
            95 => FieldSchema.new( name: :battle_test_formation, type: :int, default: 0 ),
            96 => FieldSchema.new( name: :battle_test_condition, type: :int, default: 0 ),

            # Whether 使用可能キャラ item/equipment restriction is decided per
            # Actor (0, the default) or per Class (1) -- a single global
            # RPG2003 toggle (Game::Party#item_usable_by?'s own source).
            97 => FieldSchema.new( name: :equipment_setting, type: :int, default: 0 ),

            # Decorative window (2003)
            99 => FieldSchema.new( name: :show_frame, type: :bool, default: false ),
            100 => FieldSchema.new( name: :frame_name, type: :string, default: '' ),
            101 => FieldSchema.new( name: :invert_animations, type: :bool, default: false ),

            111 => FieldSchema.new( name: :show_title, type: :bool, default: true ),
          } }
        ),
        23 => FieldSchema.new(
          name: :switch, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
          } }
        ),
        24 => FieldSchema.new(
          name: :variable, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
          } }
        ),
         25 => FieldSchema.new(
           # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%82%B3%E3%83%A2%E3%83%B3%E3%82%A4%E3%83%99%E3%83%B3%E3%83%88
           name: :common_event, type: :Array2D,
           elements: COMMON_EVENT
         ),
         # RPG2003-only database sections (chunks 26/27/28 sit between the 2000
         # common-events table and the 2003 battle-commands list; 31 sits between
         # the 2003 Classes table and the Battler-Animation table). They are
         # present-but-empty in the only 2003 test bed (mtf-meido-action), so the
         # record layout is not yet transcribed from the RPG_RT specification.
         # Declared as bare Array2D tables -- every top-level database section is a
         # record table, so this is structurally correct and preserves any real
         # bytes that a non-empty project writes, while making the sections
         # nameable instead of raising on access.
         26 => FieldSchema.new( name: :section_26, type: :Array2D, elements: {} ),
         27 => FieldSchema.new( name: :section_27, type: :Array2D, elements: {} ),
         28 => FieldSchema.new( name: :section_28, type: :Array2D, elements: {} ),
         29 => FieldSchema.new(
          # RPG2003's database-wide "Battle Commands" list (0x1D on liblcf's
          # own rpg::Database, not on the VIPRPG 200X wiki this file otherwise
          # transcribes -- confirmed against liblcf's generator/csv/fields.csv
          # and enums.csv instead). A single instance, not a table: field 10
          # (0x0A) is the table itself, one BattleCommand (name + type) per
          # entry. An actor's or class's own `battle_commands` (field 80 on
          # 11/30 below) holds ids that index into `commands` here -- 1-based,
          # matching every other database table id in this format -- except 0
          # (Row) and -1 (an empty slot), which name no entry and are handled
          # by the caller instead.
          name: :battlecommands, type: :Array1D,
          elements: -> { {
            # Where a living party member's battle sprite is positioned in the
            # alternative/gauge layouts (BattleCommands::Placement in liblcf):
            # 0 manual (the actor's own database `battle_x`/`battle_y`, see
            # chunk 11 fields 59/60), 1 automatic (a grid formula keyed by
            # party size/index and the encounter's terrain -- the exact
            # formula is not yet implemented here, and NOT independently
            # confirmed against genuine RPG_RT under wine). Confirmed against
            # liblcf's own generator/csv/fields.csv (0x02) and enums.csv, not
            # guessed.
            2 => FieldSchema.new( name: :placement, type: :int, default: 0 ),
            # RPG2003's battle-screen presentation choice (BattleType in
            # liblcf): 0 traditional (RPG2000-style status window only), 1
            # alternative (actor sprites), 2 gauge (actor sprites + HP/SP
            # gauges). RPG2000's editor has no such option, so an RPG2000
            # database never sets this and correctly reads back as 0.
            7 => FieldSchema.new( name: :battle_type, type: :int, default: 0 ),
            # RPG2003-only BattleCommands field (chunk 9). A single byte (0 in the
            # mtf-meido-action test bed); the RPG_RT semantic is not yet
            # transcribed from the specification, so it is declared as a plain int
            # to keep the value round-tripping and nameable rather than guessed.
            9 => FieldSchema.new( name: :section_flags_9, type: :int, default: 0 ),
            10 => FieldSchema.new(
              name: :commands, type: :Array2D,
              elements: {
                1 => FieldSchema.new( name: :name, type: :string, default: '' ),
                # 0 attack, 1 skill, 2 subskill (a single named skill used as
                # its own shortcut), 3 defense, 4 item, 5 escape, 6 special.
                2 => FieldSchema.new( name: :type, type: :int, default: 0 ),
              }
            ),
            # RPG2003's "Death Handler": when set, a wandering-monster
            # encounter's party wipe runs common event `death_event` and/or
            # teleports the party instead of the ordinary Game Over screen --
            # confirmed against liblcf's own generator/csv/fields.csv (not
            # guessed), which also carries a `death_handler_unused` boolean
            # at 0x04 the editor always writes alongside this one but real
            # RPG_RT never reads, so it is deliberately left out of this
            # schema. See Game::Party#death_handler? (mruby-rpg2k/mrblib/
            # game.rb), which also gates this on an RPG2003-only check the
            # same way every other RPG2003-only flag in this codebase is --
            # this whole gating behavior is NOT independently confirmed
            # against genuine RPG_RT under wine.
            15 => FieldSchema.new( name: :death_handler, type: :bool, default: false ),
            16 => FieldSchema.new( name: :death_event, type: :int, default: 1 ),
            # RPG2003-only BattleCommands field (chunk 24). A single byte (1 in the
            # mtf-meido-action test bed); the RPG_RT semantic is not yet
            # transcribed from the specification, so it is declared as a plain int
            # to keep the value round-tripping and nameable rather than guessed.
            24 => FieldSchema.new( name: :section_flags_24, type: :int, default: 0 ),
            # `death_teleport_face` follows the same 1-based up/right/down/
            # left-with-0-meaning-"keep the current facing" layout as the
            # Teleport event command's own facing parameter (liblcf's
            # `BattleCommands_Facing` enum, generator/csv/enums.csv: 0
            # retain, 1 up, 2 right, 3 down, 4 left) -- see Interpreter
            # #teleport_facing, reused as-is for this field.
            25 => FieldSchema.new( name: :death_teleport, type: :bool, default: false ),
            26 => FieldSchema.new( name: :death_teleport_id, type: :int, default: 1 ),
            27 => FieldSchema.new( name: :death_teleport_x, type: :int, default: 0 ),
            28 => FieldSchema.new( name: :death_teleport_y, type: :int, default: 0 ),
            29 => FieldSchema.new( name: :death_teleport_face, type: :int, default: 0 ),
          } }
        ),
        30 => FieldSchema.new(
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E8%81%B7%E6%A5%AD
          name: :job, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            21 => FieldSchema.new( name: :double_hand, type: :bool, default: false ),       # 二刀流
            22 => FieldSchema.new( name: :equipment_fixed, type: :bool, default: false ),   # 装備固定
            23 => FieldSchema.new( name: :force_ai, type: :bool, default: false ),          # 強制AI
            24 => FieldSchema.new( name: :strong_defence, type: :bool, default: false ),    # 強力防御
            # 能力値 -- stat-major: six max_level-sized blocks (max_hp, max_mp,
            # atk, def, int, agi), read the same way as the actor row's own
            # field 31 above (Game::Actor#base_stats/#curve_row), confirmed
            # against a genuine RPG_RT.exe.
            31 => FieldSchema.new( name: :parameters, type: :int16_array ),
            41 => FieldSchema.new( name: :exp_basic, type: :int, default: -> { LCF.exp_default } ),
            42 => FieldSchema.new( name: :exp_increase, type: :int, default: -> { LCF.exp_default } ),
            43 => FieldSchema.new( name: :exp_correction, type: :int, default: 0 ),
            62 => FieldSchema.new( name: :battler_animation, type: :int, default: 1 ),      # id into chunk 32's battleranimations
            63 => FieldSchema.new( name: :skills, type: :Array2D, elements: LEARNING ),
            71 => FieldSchema.new( name: :state_ranks_size, type: :int, default: 0 ),
            72 => FieldSchema.new( name: :state_ranks, type: :int8_array ),
            73 => FieldSchema.new( name: :attribute_ranks_size, type: :int, default: 0 ),
            74 => FieldSchema.new( name: :attribute_ranks, type: :int8_array ),
             80 => FieldSchema.new( name: :battle_commands, type: :int32_array ),
           } }
         ),
         # RPG2003-only database section (chunk 31) between the 2003 Classes
         # table and the Battler-Animation table. Present-but-empty in the only
         # 2003 test bed (mtf-meido-action); declared as a bare Array2D table --
         # structurally correct and preserves any real bytes a non-empty project
         # writes, matching the 26/27/28 sections above.
         31 => FieldSchema.new( name: :section_31, type: :Array2D, elements: {} ),
         32 => FieldSchema.new(
          # RPG2003's database-wide "Battler Animation" table (0x20 on
          # liblcf's ChunkDatabase, `rpg::BattlerAnimation`) -- a named set of
          # up to 12 poses an actor's battle sprite can show, one entry per
          # Pose (lcf::rpg::BattlerAnimation::Pose): 0 idle, 1 attack right, 2
          # attack left, 3 skill, 4 dead, 5 damage, 6 dazed, 7 defend, 8 walk
          # left, 9 walk right, 10 victory, 11 item. `player.battler_animation`
          # (chunk 11 field 62) and `job.battler_animation` (chunk 30 field
          # 62) hold ids into this table -- 1-based, matching every other
          # database table id in this format. This entry used to be
          # transcribed from the VIPRPG wiki's "戦闘アニメ２" page under the
          # name `battle_anime2` with several field names guessed wrong
          # (confirmed against liblcf's own generator/csv/fields.csv and
          # generated/lcf/ldb/chunks.h instead): field 2 is `speed`, not
          # `attack_motion`, and within each pose entry field 5 is
          # `battle_animation_id` (an id into chunk 31's `battle_animation`
          # table), not an unexplained `extension`.
          #
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%88%A6%E9%97%98%E3%82%A2%E3%83%8B%E3%83%A1%EF%BC%92
          name: :battleranimations, type: :Array2D,
          elements: -> { {
            1 => FieldSchema.new( name: :name, type: :string, default: '' ),
            2 => FieldSchema.new( name: :speed, type: :int, default: 20 ),
            10 => FieldSchema.new(
              # Id-keyed by Pose (see above), not a densely-packed list -- a
              # given entry may define anywhere from 0 to 12 of the 12 poses.
              name: :poses, type: :Array2D,
              elements: {
                1 => FieldSchema.new( name: :name, type: :string, default: '' ),
                2 => FieldSchema.new( name: :battler_name, type: :string, default: '' ),   # 戦闘(武器)グラフィック
                3 => FieldSchema.new( name: :battler_index, type: :int, default: 0 ),      # グラフィック/位置
                # 0 character (a normal 4-direction charset sheet), 1 battle
                # (a CBA-style battle sheet).
                4 => FieldSchema.new( name: :animation_type, type: :int, default: 0 ),
                5 => FieldSchema.new( name: :battle_animation_id, type: :int, default: 1 ),
              }
            ),
            11 => FieldSchema.new(
              # Per-weapon pose overrides -- out of scope for now, not needed
              # for base pose rendering; left as originally transcribed.
              name: :weapon_data, type: :Array2D,
              elements: {
                1 => FieldSchema.new( name: :name, type: :string, default: '' ),
                2 => FieldSchema.new( name: :battler_name, type: :string, default: '' ),   # 戦闘(武器)グラフィック
                3 => FieldSchema.new( name: :battler_position, type: :int, default: 0 ),   # グラフィック/位置
              }
            ),
          } }
        ),
      },
    )

    MAP_TREE = [
      FieldSchema.new(
        name: :map_properties, type: :Array2D,
        elements: {
          1 => FieldSchema.new( name: :name, type: :string ),
          2 => FieldSchema.new( name: :parent_map_id, type: :int ),
          # Editor-only node depth / management data.
          3 => FieldSchema.new( name: :indentation, type: :int ),
          # 0 = root, 1 = normal map, 2 = area.
          4 => FieldSchema.new( name: :type, type: :int, default: 1 ),
          # Editor-only scrollbar positions (RPG Maker's map-editor viewport),
          # stored as signed ints — not booleans.
          5 => FieldSchema.new( name: :scrollbar_x, type: :int, default: 0 ),
          6 => FieldSchema.new( name: :scrollbar_y, type: :int, default: 0 ),
          7 => FieldSchema.new( name: :node_extracted, type: :bool, default: false ),
          11 => FieldSchema.new( name: :bgm_type, type: :int, default: 0 ),
          12 => FieldSchema.new( name: :bgm, type: :Array1D, elements: BGM ),
          21 => FieldSchema.new( name: :backdrop_type, type: :int, default: 0 ),
          22 => FieldSchema.new( name: :backdrop_file, type: :string ),
          31 => FieldSchema.new( name: :teleport, type: :int, default: 1 ),
          32 => FieldSchema.new( name: :escape, type: :int, default: 1 ),
          33 => FieldSchema.new( name: :save, type: :int, default: 1 ),
          41 => FieldSchema.new( name: :enemy_groups, type: :Array2D, elements: {1 => FieldSchema.new( name: :enemy_group_id, type: :int, default: 1 )}),
          44 => FieldSchema.new( name: :encount_steps, type: :int, default: 25 ),
          # Area bounds, only used by area nodes (type == 2): [X1, Y1, X2 + 1, Y2 + 1].
          51 => FieldSchema.new( name: :area, type: :int16_array, order: [:left, :top, :right, :bottom] ),
        }
      ),
      FieldSchema.new(
        name: :tree,
        type: :Tree,
      ),
      FieldSchema.new(
        name: :initial,
        type: :Array1D,
        elements: {
          1 => FieldSchema.new( name: :initial_map_id, type: :int ),
          2 => FieldSchema.new( name: :initial_x, type: :int ),
          3 => FieldSchema.new( name: :initial_y, type: :int ),

          11 => FieldSchema.new( name: :boat_map_id, type: :int ),
          12 => FieldSchema.new( name: :boat_x, type: :int ),
          13 => FieldSchema.new( name: :boat_y, type: :int ),

          21 => FieldSchema.new( name: :ship_map_id, type: :int ),
          22 => FieldSchema.new( name: :ship_x, type: :int ),
          23 => FieldSchema.new( name: :ship_y, type: :int ),

          31 => FieldSchema.new( name: :airship_map_id, type: :int ),
          32 => FieldSchema.new( name: :airship_x, type: :int ),
          33 => FieldSchema.new( name: :airship_y, type: :int ),
        },
      ),
    ]

    # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%9E%E3%83%83%E3%83%97
    #
    # Conditions that must hold for an event page to be active.
    MAP_EVENT_PAGE_CONDITION = lazy { {
      # Bit flags selecting which of the conditions below are enabled.
      1 => FieldSchema.new( name: :flags, type: :int, default: 0 ),
      2 => FieldSchema.new( name: :switch_a_id, type: :int, default: 1 ),
      3 => FieldSchema.new( name: :switch_b_id, type: :int, default: 1 ),
      4 => FieldSchema.new( name: :variable_id, type: :int, default: 1 ),
      5 => FieldSchema.new( name: :variable_value, type: :int, default: 0 ),
      6 => FieldSchema.new( name: :item_id, type: :int, default: 1 ),
      7 => FieldSchema.new( name: :actor_id, type: :int, default: 1 ),
      # Genuine RPG2000 condition (flags bit 0x20): the page is active once
      # Timer1 has counted down to timer_sec seconds or below -- see
      # Game::EventPage::TIMER.
      8 => FieldSchema.new( name: :timer_sec, type: :int, default: 0 ),
      # RPG2003-only: a second timer condition (flags bit 0x40, gated on an
      # RPG2003 command check ported from a reference implementation, NOT
      # independently confirmed against genuine RPG_RT under wine) and the
      # variable comparison operator, both now read by Game::EventPage -- see its own
      # TIMER2 / compare_operator handling there.
      9 => FieldSchema.new( name: :timer2_sec, type: :int, default: 0 ),
      # 0 == 1 >= 2 <= 3 > 4 < 5 != (liblcf's EventPageCondition::Comparison
      # enum). Default 1 (>=), not 0 (==): liblcf's generated
      # eventpagecondition.h declares `int32_t compare_operator = 1;`, and an
      # absent chunk field reads as its schema default -- an RPG2000 database
      # (which never writes this RPG2003-only field at all) or an RPG2003
      # page whose editor dropdown was left at its own default both need the
      # ordinary ">=" reading, not "==", once EventPage actually consults
      # this field.
      10 => FieldSchema.new( name: :compare_operator, type: :int, default: 1 ),
    } }

    MOVE_ROUTE = {
      11 => FieldSchema.new( name: :command_size, type: :int, default: 0 ),
      12 => FieldSchema.new( name: :commands, type: :move_commands, default: [] ),
      21 => FieldSchema.new( name: :repeat, type: :bool, default: true ),
      22 => FieldSchema.new( name: :skippable, type: :bool, default: false ),
    }

    MAP_EVENT_PAGE = lazy { {
      2 => FieldSchema.new( name: :condition, type: :Array1D, elements: MAP_EVENT_PAGE_CONDITION ),
      21 => FieldSchema.new( name: :charset_name, type: :string, default: '' ),
      22 => FieldSchema.new( name: :charset_index, type: :int, default: 0 ),
      # 2 = down, 4 = left, 6 = right, 8 = up.
      23 => FieldSchema.new( name: :direction, type: :int, default: 2 ),
      24 => FieldSchema.new( name: :pattern, type: :int, default: 1 ),
      25 => FieldSchema.new( name: :translucent, type: :bool, default: false ),
      31 => FieldSchema.new( name: :move_type, type: :int, default: 0 ),
      32 => FieldSchema.new( name: :move_frequency, type: :int, default: 3 ),
      # Start condition: 0 = action key, 1 = touch by player, ...
      33 => FieldSchema.new( name: :trigger, type: :int, default: 0 ),
      # Layer / priority: 0 = below, 1 = same, 2 = above the player.
      34 => FieldSchema.new( name: :layer, type: :int, default: 0 ),
      35 => FieldSchema.new( name: :overlap_forbidden, type: :bool, default: false ),
      36 => FieldSchema.new( name: :animation_type, type: :int, default: 0 ),
      37 => FieldSchema.new( name: :move_speed, type: :int, default: 3 ),
      41 => FieldSchema.new( name: :move_route, type: :Array1D, elements: MOVE_ROUTE ),
      # Mirrors field 52's own encoded byte length exactly (confirmed
      # empirically: a genuine file's own field 51 == `LCF.encode_event_
      # commands(page.event_commands).bytesize` for every page checked) --
      # NOT a command count, despite the name. Genuine RPG_RT.exe reads and
      # trusts this length rather than deriving it from field 52's own outer
      # chunk framing: cycle #181 confirmed this the hard way, splicing one
      # extra parameter onto an already-genuine Teleport command (growing
      # field 52 by a byte) without recomputing this field, which
      # reproducibly hung genuine RPG_RT.exe on a black screen after the
      # Teleport -- an artifact of the stale length, not of anything about
      # the added parameter itself. Recomputing this field after any edit
      # to field 52 (`page[51] = LCF.encode_event_commands(cmds).bytesize`)
      # fixed it; any future single-parameter splice onto an event command
      # list (per cycles #137-139/#176/#178/#180/#181's own discipline) must
      # do the same.
      51 => FieldSchema.new( name: :event_command_size, type: :int, default: 0 ),
      52 => FieldSchema.new( name: :event_commands, type: :event ),
    } }

    MAP_EVENT = {
      1 => FieldSchema.new( name: :name, type: :string, default: '' ),
      2 => FieldSchema.new( name: :x, type: :int, default: 0 ),
      3 => FieldSchema.new( name: :y, type: :int, default: 0 ),
      5 => FieldSchema.new( name: :pages, type: :Array2D, elements: MAP_EVENT_PAGE ),
    }

    # Used directly as a `.lmu` file's own root schema (LCF::MapUnit#schema
    # below), the same way DATABASE is a `.ldb`'s -- so, like DATABASE, this
    # outer Hash itself must stay eager (File#initialize reads `schema[:type]`
    # off it directly, never through LCF.elements_of); only the `elements:`
    # value, one map's worth of live fields, is lazy.
    MAP_UNIT = FieldSchema.new(
      name: :Map, type: :Array1D,
      elements: -> { {
        1 => FieldSchema.new( name: :chipset_id, type: :int, default: 1 ),
        2 => FieldSchema.new( name: :width, type: :int, default: 20 ),
        3 => FieldSchema.new( name: :height, type: :int, default: 15 ),
        # 0 = none, 1 = vertical, 2 = horizontal, 3 = both.
        11 => FieldSchema.new( name: :scroll_type, type: :int, default: 0 ),
        31 => FieldSchema.new( name: :parallax_flag, type: :bool, default: false ),
        32 => FieldSchema.new( name: :parallax_name, type: :string, default: '' ),
        33 => FieldSchema.new( name: :parallax_loop_x, type: :bool, default: false ),
        34 => FieldSchema.new( name: :parallax_loop_y, type: :bool, default: false ),
        35 => FieldSchema.new( name: :parallax_autoloop_x, type: :bool, default: false ),
        36 => FieldSchema.new( name: :parallax_sx, type: :int, default: 0 ),
        37 => FieldSchema.new( name: :parallax_autoloop_y, type: :bool, default: false ),
        38 => FieldSchema.new( name: :parallax_sy, type: :int, default: 0 ),
        # --- RPG2003 random dungeon generator (マップ生成) -------------------
        #
        # Editor-only: the settings the "generate dungeon" tool was last run
        # with, kept so reopening the map restores the dialog. RPG_RT never
        # reads them at run time and neither does this runtime — they are
        # declared so a real map parses completely rather than leaving live
        # chunks unaccounted for.
        #
        # Not on the wiki's マップ page, so the ids and defaults are liblcf's
        # LMU_Reader::ChunkMap / RPG::Map (0x28..0x3E and 0x5A). The test beds
        # confirm the ones they exercise: mtf-meido-action writes top_level
        # (42) on 8 maps, and generator_height (50) as 2 on all 13 — the fields
        # it leaves out are exactly the ones already at their liblcf default
        # (generator_width 4, the six `true` flags), which is what an eliding
        # writer produces and is a good check that these defaults are right.
        40 => FieldSchema.new( name: :generator_flag, type: :bool, default: false ),
        41 => FieldSchema.new( name: :generator_mode, type: :int, default: 0 ),
        42 => FieldSchema.new( name: :top_level, type: :bool, default: false ),
        48 => FieldSchema.new( name: :generator_tiles, type: :int, default: 0 ),
        49 => FieldSchema.new( name: :generator_width, type: :int, default: 4 ),
        50 => FieldSchema.new( name: :generator_height, type: :int, default: 1 ),
        51 => FieldSchema.new( name: :generator_surround, type: :bool, default: true ),
        52 => FieldSchema.new( name: :generator_upper_wall, type: :bool, default: true ),
        53 => FieldSchema.new( name: :generator_floor_b, type: :bool, default: true ),
        54 => FieldSchema.new( name: :generator_floor_c, type: :bool, default: true ),
        55 => FieldSchema.new( name: :generator_extra_b, type: :bool, default: true ),
        56 => FieldSchema.new( name: :generator_extra_c, type: :bool, default: true ),
        # Nine room slots. x/y are liblcf `uint32_t` vectors, read here as
        # signed 32-bit — the values are map coordinates, so the two readings
        # only differ above 2^31, which no map reaches. The tile ids are
        # shorts: reading chunk 62 as int16 yields real RPG2000 tile ids
        # (49 lower-layer, 10000/10001/10006/10007 upper-layer) where an int32
        # reading gives nonsense, which is what pins the width down.
        60 => FieldSchema.new( name: :generator_x, type: :int32_array ),
        61 => FieldSchema.new( name: :generator_y, type: :int32_array ),
        62 => FieldSchema.new( name: :generator_tile_ids, type: :int16_array ),
        # width * height signed shorts, one tile id per cell.
        71 => FieldSchema.new( name: :lower_layer, type: :int16_array ),
        72 => FieldSchema.new( name: :upper_layer, type: :int16_array ),
        81 => FieldSchema.new( name: :events, type: :Array2D, elements: MAP_EVENT ),
        # The 2k3e ("RPG2003 English release") save counter, a second counter
        # beside the ordinary one below. BER-encoded like every other int —
        # mtf-meido-action's first map holds 593.
        90 => FieldSchema.new( name: :save_count_2k3e, type: :int, default: 0 ),
        91 => FieldSchema.new( name: :save_count, type: :int, default: 0 ),
      } }
    )

    # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%82%BB%E3%83%BC%E3%83%96%E3%83%87%E3%83%BC%E3%82%BF
    #
    # Snapshot of a hero or vehicle on the map. Vehicles reuse the same layout.
    SAVE_MOVABLE = lazy { {
      11 => FieldSchema.new( name: :map_id, type: :int ),
      12 => FieldSchema.new( name: :x, type: :int ),
      13 => FieldSchema.new( name: :y, type: :int ),
      # liblcf's `SaveMapEventBase.facing` (generator/csv/fields.csv, 0x16 ==
      # 22) -- *not* this runtime's numpad convention (2/4/6/8) the database-
      # side event-page facing field (MAP_EVENT_PAGE field 23) uses directly.
      # The 0=up/1=right/2=down/3=left enum order this codebase assumes
      # (`Game::CharSet::DIR_ROW` doubles as the encoder, `EventGraphic.
      # numpad_direction` as the decoder) is NOT independently confirmed
      # against genuine RPG_RT under wine -- cycle #174 tried and could not
      # reach a verdict either way: varying this field across all four raw
      # values (0/1/2/3) on a genuine Nepheshel `Save01.lsd` produced a
      # byte-identical (`compare -metric AE` == 0) rendered hero across every
      # value, on four independent wine boots, so no directional difference
      # was observable to check the mapping against at all. The same probe
      # also found this field's sibling `x`/`y` (11-13 above) silently
      # ignored the same way -- writing 2,2 vs 14,11 vs 14,9 on the same
      # save/map all rendered identically too -- so the null result likely
      # traces to this specific save's own leader (database actor 15,
      # "デモ用", a demo/placeholder actor from Nepheshel's scripted opening;
      # see `scripts/gen-rpg2k-save.rb`'s own header) rather than to this
      # field's meaning being wrong. Left open: repeat this probe against a
      # save whose leader is an ordinary, non-placeholder actor.
      22 => FieldSchema.new( name: :direction, type: :int ),
      # liblcf's own generator/csv/fields.csv names field 0x15/21 `direction`
      # ("Sprite direction") and field 0x16/22 (just above) `facing` -- the
      # reverse of the names already established here, kept as-is rather
      # than risk an invasive rename of the widely-referenced field 22.
      # Confirmed present on a genuine kk1.12 save under wine, holding the
      # exact same raw value as field 22 in that capture (both "\x02",
      # facing down) -- consistent with 21 simply mirroring 22 whenever the
      # hero is not itself mid-turn-animation (the one case liblcf's own
      # naming implies the two could differ), which this codebase has no
      # separate concept of. Not otherwise investigated -- left as a
      # write-only mirror, the same shape as chunk 104's own 73/74
      # (`charset_name`/`charset_index`) sprite mirror.
      21 => FieldSchema.new( name: :sprite_direction, type: :int ),
      # liblcf's own `layer` (generator/csv/fields.csv, 0x21 == 33): confirmed
      # present as the constant 1 ("same as characters") on a genuine kk1.12
      # save under wine, on the hero's own record and every vehicle's alike
      # (chunks 104-107) -- RPG2000/2003 has no "Change Hero/Vehicle Layer"
      # command (only a map *event* page can be pinned below/above
      # characters), so this codebase's own `#to_lsd` writes it as a true
      # constant rather than tracking any live state for it.
      33 => FieldSchema.new( name: :layer, type: :int ),
      # liblcf's `SaveMapEventBase.transparency` (generator/csv/fields.csv,
      # 0x18 == 24): "0 or 3 - Transparency level of the current event page".
      # On the *hero's* own record (chunk 104) this is Set Transparent Flag's
      # (Player Visibility, 11310) runtime override -- Game::State
      # #player_transparent. It used to be smuggled into SAVE_SYSTEM's own
      # field 55 instead, which liblcf actually names `event_message_active`
      # (a flag ShowMessage/ShowChoices/ShowNumberInput set, unrelated to
      # transparency at all) -- ADR 0020 declared it `:transparent` with no
      # citation for the claim. Confirmed against the repo's own real save
      # fixture: `event_message_active` (55) decodes true on Nepheshel
      # Save01.lsd, which would have made Continue permanently hide the hero
      # on any save taken with a message on screen -- a real, severe
      # regression a genuine RPG_RT save can trigger, not merely a naming
      # slip. The vehicle chunks (105-107) never used field 55 for anything,
      # so this field is otherwise new to them too -- vehicles have no
      # runtime "hidden" state to persist, so their own #load_movable simply
      # never reads it.
      24 => FieldSchema.new( name: :transparency, type: :int, default: 0 ),
      # liblcf's own generator/csv/fields.csv (0x20 == 32, default 2): the
      # move-frequency a forced move route (Set Move Route) runs its target
      # at -- see Game::State#player_route's own citation in game.rb for why
      # this lives on the hero's own record specifically (Scene::Map's
      # transient @player_char mirror, not tracked anywhere else). Not
      # independently confirmed against genuine RPG_RT under wine.
      32 => FieldSchema.new( name: :move_frequency, type: :int, default: 2 ),
      35 => FieldSchema.new( name: :animation_type, type: :int ),
      37 => FieldSchema.new( name: :move_speed, type: :int ),
      # liblcf's own `SaveMapEventBase.move_route` (generator/csv/fields.csv,
      # 0x29 == 41), the same `MOVE_ROUTE` struct (11/12 move_commands,
      # 21 repeat, 22 skippable) MAP_EVENT_PAGE's own field 41 already uses
      # for a database-configured custom route -- `LCF.parse_move_commands`/
      # `.encode_move_commands`'s exact byte format is exercised across the
      # full test-bed corpus of real editor-authored maps (116076 real move
      # commands parsed with every `command_id` landing in its valid 0..41
      # range, `scripts/lcf_testbed_check.rb`). On the
      # hero's own record this is a live Set Move Route (11330) targeting
      # the player, not a database page property -- see Game::State
      # #player_route's own citation in game.rb. Confirmed present with
      # real command data on a genuine kk1.12 save under wine (the hero had
      # a live custom route recorded in that capture).
      41 => FieldSchema.new( name: :move_route, type: :Array1D, elements: MOVE_ROUTE ),
      # SaveMapEventBase's own move-route cursor: how far into a page's
      # move_type CUSTOM route this event had gotten (Game::MoveRoute#index),
      # ported from a reference implementation's schema field layout, not
      # independently confirmed against genuine RPG_RT under wine (0x2B ==
      # 43). liblcf also has a SaveMapEvent.original_move_route_index (0x66/102),
      # tracking the route in force *before* a Set Move Route override --
      # left undecoded, since this codebase's own Game::State
      # #map_event_route_index has no separate "original vs current route"
      # concept to source it from, only the single live cursor field 43
      # already covers. No `default:` (matching e.g. SAVE_INVENTORY's
      # turns/steps counters), so an absent field reads back as nil rather
      # than 0 -- Game::State.from_lsd tells "no saved cursor, restart the
      # route from the top" from "explicitly at command 0" the same way.
      43 => FieldSchema.new( name: :move_route_index, type: :int ),
      # liblcf's own `through` (generator/csv/fields.csv, 0x33 == 51,
      # default false): "Walk Everywhere On/Off" (36/37), a Set Move Route
      # command that ignores map collision for its target until turned back
      # off or the route ends. On the hero's own record this is Scene::Map's
      # own transient @player_through mirror -- see Game::State
      # #player_route's own citation in game.rb. Not independently confirmed
      # against genuine RPG_RT under wine.
      51 => FieldSchema.new( name: :through, type: :bool, default: false ),
      # liblcf's `SaveMapEventBase` (generator/csv/fields.csv): `sprite_name`
      # 0x49 == 73, `sprite_id` 0x4A == 74. Field 75 (0x4B) is `processed`, an
      # unrelated per-frame flag ("has this event already taken its movement
      # step this frame") -- ADR 0020 originally mapped charset_index to 75,
      # citing "liblcf's RPG::SaveSystem", but SaveSystem's own fields 73-75
      # are battle_end_music/inn_music/current_music, nothing to do with a
      # character graphic; SaveMapEventBase (the struct chunk 104/105-107
      # actually use, already correctly named two fields up for
      # move_route_index) is the right one. Confirmed against a real save
      # (Nepheshel Save01's hero record): field 75 is present (`\x01`, a
      # plausible `processed` value) while 73/74 are both absent -- exactly
      # what "no sprite override, mid-frame" looks like, not what a genuine
      # sprite_id co-occurring without its paired sprite_name ever would.
      73 => FieldSchema.new( name: :charset_name, type: :string ),
      74 => FieldSchema.new( name: :charset_index, type: :int ),
      # liblcf's own generator/csv/fields.csv (0x51-0x55 == 81-85): an
      # in-flight Flash Sprite (11320), or a map-triggered battle-animation
      # flash reusing the same mechanism (see Game::State#player_flash's own
      # citation in game.rb). `flash_current_level` is declared a `Double`
      # (not an Int32 like its siblings) -- liblcf tracks the *current*,
      # already-decayed strength directly rather than recomputing it from
      # `flash_power`/`flash_time_left` each frame, so `#to_lsd` derives an
      # equivalent value from this codebase's own `power * frames / total`
      # decay math (`Scene::Map#flash_tone`'s own formula). Confirmed against
      # a genuine kk1.12 save under wine, for the *not flashing* case only:
      # flash_red/_green/_blue present as an explicit 0 (not the schema's own
      # -1 generator default, and not absent either) while
      # flash_current_level/_time_left stayed absent -- so RPG_RT always
      # writes the RGB triple, defaulting to 0 rather than -1, and only adds
      # the level/time_left pair while a flash is actually in progress. The
      # *flashing* case's exact byte values (in particular whether
      # `flash_current_level`'s own decay curve matches this codebase's
      # linear one) has not been confirmed against genuine RPG_RT.
      81 => FieldSchema.new( name: :flash_red, type: :int ),
      82 => FieldSchema.new( name: :flash_green, type: :int ),
      83 => FieldSchema.new( name: :flash_blue, type: :int ),
      84 => FieldSchema.new( name: :flash_current_level, type: :double ),
      85 => FieldSchema.new( name: :flash_time_left, type: :int ),
      # liblcf's own `SaveVehicleLocation` struct (generator/csv/fields.csv,
      # 0x65 == 101, name `vehicle`) -- a boat/ship/airship-only field this
      # shared SAVE_MOVABLE table otherwise has no equivalent for (the hero's
      # own chunk 104 record never carries it). Confirmed present on a
      # genuine kk1.12 save under wine as the vehicle's own 1/2/3 ordinal
      # (boat/ship/airship), on all three vehicle chunks, none of which had
      # ever been boarded that session -- see SAVE_DATA's own 105-107
      # comment for the larger discovery this field was found alongside.
      101 => FieldSchema.new( name: :vehicle, type: :int ),
      # Field 108 (0x6C, liblcf's own `SaveMapEvent.parallel_event_execstate`,
      # generator/csv/fields.csv) -- a map event's OWN Parallel Process's full
      # call-stack snapshot, the identical SAVE_EVENT_EXEC_STATE struct chunk
      # 111's own sibling chunks 113/114 (SAVE_FOREGROUND_EVENT/
      # SAVE_COMMON_EVENT) already use. `elements:` names SAVE_EVENT_EXEC_STATE,
      # declared later in this file (SAVE_MOVABLE is one of the earliest
      # tables; SAVE_EVENT_EXEC_STATE, added by cycle #191, comes much
      # later) -- referencing it here by name only works (rather than a
      # load-order NameError) because `lazy` above defers actually
      # evaluating this hash literal until first real access, long after
      # every constant in the file exists.
      #
      # Cycle #193 closes the one gap cycle #191/#192's own foreground/
      # common-event call-stack persistence deliberately left open: a Map
      # Event's own Parallel Process (trigger Parallel Process on the event's
      # own page, distinct from a Common Event's Parallel Process, already
      # covered by SAVE_COMMON_EVENT) previously had no persistence at all --
      # not even the older, coarser #resumable_index-style cursor
      # `Game::State#common_event_progress` gives common events, since no such
      # cursor ever existed for map events (`Scene::Map#build_parallels`'s own
      # comment: "a real 'visit' gives a map event's own parallel process no
      # id that means anything on the map being left"). See
      # `Game::State#map_event_exec`'s own comment (game.rb) for the full
      # engine-side wiring this field now backs, and why -- unlike
      # `#common_event_exec` -- it is scoped to the currently-loaded map only,
      # matching `#map_event_positions`.
      #
      # liblcf's own two neighbouring fields on `SaveMapEvent` --
      # `waiting_execution` (0x65/101, "this event is waiting for foreground
      # execution") and `original_move_route_index` (0x66/102) /
      # `triggered_by_decision_key` (0x67/103) -- are deliberately left
      # unmodelled: 101 collides with this same shared SAVE_MOVABLE table's
      # pre-existing, differently-typed `:vehicle` field (chunks 105-107's own
      # boat/ship/airship ordinal, write-only byte parity with no reader), so
      # giving it a second meaning here is not possible without splitting
      # SAVE_MOVABLE into per-chunk tables -- out of scope for this cycle,
      # which only needs field 108. 102/103 are real, uncontested fields this
      # codebase's own `Game::State` simply has no distinct "original route
      # before an override"/"triggered by decision key" concept to source for
      # a map event specifically (the latter is already carried per-frame
      # inside `stack`'s own outermost `SAVE_EVENT_EXEC_FRAME`, field 13, which
      # is what this codebase's reader actually consults) -- left for a future
      # cycle alongside SAVE_MOVABLE's own already-catalogued larger gaps (see
      # that table's own comment on the hero's unmodelled move-route chunk/
      # `through`/movement timers).
      108 => FieldSchema.new( name: :parallel_event_execstate, type: :Array1D, elements: SAVE_EVENT_EXEC_STATE ),
    } }

    # A genuine kk1.12 save's own chunk 104 (the hero's SAVE_MOVABLE record)
    # carries a lot more of liblcf's full `SaveMapEventBase` struct
    # (generator/csv/fields.csv) than this table models:
    # `stop_count`/`anim_count`/`max_stop_count` (0x34-36/52-54, movement/
    # animation frame timers) and `begin_jump_x`/`_y` (0x3E-3F/62-63,
    # mid-jump coordinates). Both are pure per-frame scheduling this engine
    # already recomputes fresh rather than resuming byte-for-byte -- a save
    # taken mid-jump or between two move-route steps restarts that one
    # sub-frame's own timing rather than resuming it exactly, the same
    # category of imperfection already accepted for fields 81-85's own
    # flash decay curve. Left as a known, minor gap for a future cycle --
    # see field 32/41/43/51's own comments for the rest of the move-route
    # picture (`move_frequency`/`move_route`/`move_route_index`/`through`),
    # field 33's own comment for `layer`, and fields 81-85's own comment for
    # `flash_red`/`_green`/`_blue`/`_current_level`/`_time_left`, all
    # already covered. `processed` (0x4B/75, already noted above) remains
    # unmodeled too.
    #
    # https://w.atwiki.jp/rpg2kpsp/pages/21.html
    #
    # Runtime state of a "show picture" command (chunk 103 of the save file),
    # one entry per picture number.
    #
    # Field 31/32 were identified as *a* live position by experiment against
    # the genuine RPG_RT (rewriting them in a real Nepheshel save and
    # comparing the resumed frame against the unedited one moved the picture
    # exactly as edited), but that experiment only ever exercised a picture at
    # rest -- and liblcf's own generator table (`generator/csv/fields.csv`)
    # names 31/32 `finish_x`/`finish_y`: the move's *target*, not its
    # in-flight position. The two agree exactly at rest, which is why the
    # earlier experiment could not tell them apart -- real RPG_RT re-syncs
    # current to finish every idle frame the same way `Game::Picture#update`
    # already does here. The genuinely live position (and zoom/transparency/
    # tone) sit at fields 4/5/7/8/11-14 instead, confirmed by a second
    # experiment: a save edited to have current_x/y (4/5) and finish_x/y
    # (31/32) genuinely differ, with time_left (51) still counting down,
    # resumed under real RPG_RT as a picture visibly still gliding from the
    # current position toward the finish one -- not sitting statically at
    # either.
    #
    # Field 2/3 -- cycle #154 spotted genuine RPG_RT.exe writing an
    # undeclared pair here (on a picture at rest, decoding to the same x/y as
    # 4/5 and 31/32, so left unidentified) and cycle #155 pinned it down with
    # a follow-up experiment: Show Picture at (111,77), then Move Picture to
    # (222,188) over 5.0s with a 3.0s Wait before saving (so the move is
    # genuinely still in flight, current_x/y at 4/5 reading the interpolated
    # 177.6/143.6 and finish_x/y at 31/32 reading the target 222/188, both
    # confirmed against this same save) -- field 2/3 stayed at 111.0/77.0
    # throughout, tracking *neither* current nor finish, but the position the
    # picture was originally shown at and never touched by the move at all.
    # No liblcf field name could be consulted for this pair (this file's own
    # standing narrow exception did not extend to a name never seen without
    # network access to `generator/csv/fields.csv`), so `show_x`/`show_y`
    # names it by the behavior actually observed: the argument of the last
    # Show Picture call for this id, holding steady across any number of
    # subsequent Move Picture calls, reset only by a fresh Show Picture.
    # Whether genuine RPG_RT ever *reads* this pair back for anything beyond
    # round-tripping it through Save/Continue is not established either way
    # -- see docs/TODO.md.
    SAVE_PICTURE = lazy { {
      1 => FieldSchema.new( name: :name, type: :string ),              # ピクチャグラフィックのファイル名
      # Show Picture's own "fixed to map position" checkbox (param4 in
      # `Interpreter#do_show_picture`, which pins the picture to scroll with
      # the camera instead of the screen). Confirmed against genuine
      # RPG_RT.exe under wine (cycle #164): a Show Picture issued with this
      # flag clear wrote chunk 103 with field 6 *absent*; an otherwise
      # byte-identical Show Picture with only this flag set wrote field 6
      # *present* as a single `0x01` byte -- elided at its own (false)
      # default, the same convention as every other picture flag/field in
      # this table.
      #
      # liblcf's own generator/csv/fields.csv (`SavePicture`) names field 8
      # `current_top_trans` and field 0x22/34 `finish_top_trans` -- RPG2003
      # (below 1.12) can split a picture's transparency into independent top
      # and bottom halves, with `current_bot_trans` at field 0x12/18 and
      # `finish_bot_trans` at field 0x23/35 as their own separate fields, both
      # confirmed present (alongside 8/34, holding the identical value) on a
      # real kk1.12 (RPG2003) save under wine even though that save never
      # exercises a genuine top/bottom split. `Game::Picture` here has no
      # top/bottom split of its own -- only the one `#opacity` this table's
      # field 8/34 already round-trip -- so `#to_lsd` writes 18/35 as plain
      # mirrors of 8/34 (top == bottom, matching "never split" byte for byte)
      # rather than modelling the split feature itself, left as a future
      # extension the same way `docs/TODO.md` already tracks other unmodelled
      # save fields.
      6 => FieldSchema.new( name: :fixed_to_map, type: :bool, default: false ),
      2 => FieldSchema.new( name: :show_x, type: :double, default: 0.0 ),
      3 => FieldSchema.new( name: :show_y, type: :double, default: 0.0 ),
      # The picture's genuinely live position/zoom/transparency/tone -- see
      # this table's own comment above for how 4/5 were told apart from
      # 31/32. Confirmed unconditional (present whenever a picture is shown
      # at all, not only while a move is in flight) by cycle #155: a picture
      # shown and never moved still wrote 4/5/7/8/11-14 with the exact same
      # values as 31-34/41-44, matching real RPG_RT's own current-tracks-
      # finish idle sync already noted above -- see Game::State#to_lsd's own
      # comment for the fix this corrected (the old code wrote these only
      # while Game::Picture#moving?). Defaults match a fresh Game::Picture so
      # an old save written before these fields existed restores identically
      # to before.
      4 => FieldSchema.new( name: :current_x, type: :double, default: 0.0 ),
      5 => FieldSchema.new( name: :current_y, type: :double, default: 0.0 ),
      7 => FieldSchema.new( name: :current_zoom, type: :double, default: 100.0 ),
      8 => FieldSchema.new( name: :current_transparency, type: :double, default: 0.0 ),
      # RPG2003-only bottom-half transparency (`current_bot_trans`) -- see
      # field 8's own comment above. Written as a plain mirror of field 8
      # (top == bottom), never independently.
      18 => FieldSchema.new( name: :current_bot_transparency, type: :double, default: 0.0 ),
      11 => FieldSchema.new( name: :current_tone_red, type: :double, default: 100.0 ),
      12 => FieldSchema.new( name: :current_tone_green, type: :double, default: 100.0 ),
      13 => FieldSchema.new( name: :current_tone_blue, type: :double, default: 100.0 ),
      14 => FieldSchema.new( name: :current_tone_saturation, type: :double, default: 100.0 ),
      # Show Picture's "not affected by transparent color" checkbox (param7
      # in `Interpreter#do_show_picture`, `use_transparent_color`) -- NOT
      # "visible", as a prior version of this comment guessed purely from
      # this field id's position in the table (between the current_* and
      # finish_* clusters). That guess was never confirmed and, worse, was
      # actively misleading: cycles #154/#155/#159 all failed to find field
      # 9 present in any of five genuine-RPG_RT.exe capture shapes because
      # none of them ever varied the transparent-color flag -- an
      # unrelated-field absence was being read as "this field is unused."
      # Cycle #164 confirmed the real mapping directly against genuine
      # RPG_RT.exe under wine: a Show Picture issued with this flag clear
      # wrote chunk 103 with field 9 *absent*; an otherwise byte-identical
      # Show Picture with only this flag set wrote field 9 *present* as a
      # single `0x01` byte, and setting *both* this flag and the
      # `fixed_to_map` flag (field 6) together wrote both fields 6 and 9
      # present simultaneously, each independently -- ruling out any
      # bit-packing between the two and confirming both really are their
      # own elided-at-default boolean fields.
      9 => FieldSchema.new( name: :use_transparent_color, type: :bool, default: false ),
      # The picture's resting/target position -- see this table's own
      # comment above for why these are named finish_*, not current_*.
      31 => FieldSchema.new( name: :finish_x, type: :double, default: 0.0 ), # 表示位置Ｘ (中心)
      32 => FieldSchema.new( name: :finish_y, type: :double, default: 0.0 ), # 表示位置Ｙ (中心)
      # Zoom/transparency/tone (both the current_* set above and this
      # finish_* set) are each elided independently at their own default --
      # confirmed by cycle #155's own controlled pair of genuine RPG_RT.exe
      # captures, identical in every other respect (same name, same
      # position, same "never moved" state): one issuing Show Picture with
      # every one of these six values left at its own default (zoom 100,
      # transparency 0, tone 100/100/100/100) wrote fields 7/8/11-14/33/34/
      # 41-44 *absent*; the other issuing the identical command with every
      # one of the six pushed off its own default (zoom 133, transparency
      # 25, tone 140/60/180/50) wrote every one of those fields *present*
      # with the exact values given -- ruling out the alternative reading
      # cycle #154 flagged ("every value that cycle's own probe chose merely
      # happened to equal the default") in favour of genuine per-field
      # elision, the same convention already established for SAVE_SCREEN's
      # own tint fields (cycle #154) and SAVE_SYSTEM's message-config
      # cluster (cycle #152/#153).
      33 => FieldSchema.new( name: :zoom, type: :int, default: 100 ),        # 拡大率
      34 => FieldSchema.new( name: :transparency, type: :int, default: 0 ),  # 透明度
      # RPG2003-only bottom-half finish transparency (`finish_bot_trans`) --
      # see field 8's own comment above for the top/bottom split this table
      # doesn't model; written as a plain mirror of field 34, never
      # independently.
      35 => FieldSchema.new( name: :bot_transparency, type: :int, default: 0 ),
      41 => FieldSchema.new( name: :tone_red, type: :int, default: 100 ),        # 色調：赤(R)
      42 => FieldSchema.new( name: :tone_green, type: :int, default: 100 ),      # 色調：緑(G)
      43 => FieldSchema.new( name: :tone_blue, type: :int, default: 100 ),       # 色調：青(B)
      44 => FieldSchema.new( name: :tone_saturation, type: :int, default: 100 ), # 色調：彩度(S)
      # How many frames remain in an in-flight Move Picture; 0 (the default,
      # covering both a still picture and an old save missing this field
      # entirely) means #restore_pictures does not start a fresh move on load.
      51 => FieldSchema.new( name: :time_left, type: :int, default: 0 ),
    } }

    # https://w.atwiki.jp/rpg2kpsp/pages/40.html
    #
    # Saved per-actor status (chunk 108), one entry per hero the party has held.
    # The rpg2kpsp page documents the state block; the fields below were decoded
    # from a real save (Nepheshel Save01) and cross-checked against the database:
    # level (31) rises with exp (32) across the roster — actor 3 is L5/307exp,
    # actor 4 L8/1177exp; current HP/SP (71/72) sit at a hero's live vitals (the
    # level-1 hero at 50/0); and equipment (61) is five item ids [weapon, shield,
    # armour, helmet, accessory] — every slot's id resolves to an item of the
    # matching type in the database (slot 0 weapons, slot 2 armour, slot 3
    # helmets, slot 4 accessories; a dual-wield hero carries a second weapon in
    # the shield slot). Field 1 is the (renamable) actor name — the hero's
    # stored name matches the SAVE_TITLE hero_name exactly, which is what
    # confirmed it — and is now modelled, so a Change Actor Name override on a
    # *non*-leader party member round-trips through Save/Continue too (chunk
    # 100's title only ever carried the leader's). Field 2 (the actor's
    # renamable title, Change Actor Title) was a single byte constant in the
    # one sampled save, so it was not provable from that save alone; it is now
    # inferred from a reference implementation's schema (not independently
    # confirmed against genuine RPG_RT under wine), whose
    # `SaveActor` struct documents field `0x02` as `title` (`String`) right
    # next to `0x01` `name` — and every other already-confirmed field in this
    # table matches liblcf's hex tag decimal-for-decimal (`0x1F`→31 `level`,
    # `0x20`→32 `exp`, `0x33`→51 `skill_size`, `0x34`→52 `skills`, `0x3D`→61
    # `equipped`, `0x47`→71 `current_hp`, `0x48`→72 `current_sp`, `0x51`→81
    # `status` count, `0x52`→82 `status`), so `0x02`→2 `title` follows the same
    # scheme. The other two single bytes that were constant in the sampled save
    # are also identified by liblcf as `hp_mod` (`0x21`→33) and `sp_mod`
    # (`0x22`→34) — unconfirmed stat modifiers, not the title — which is why
    # they stay undecoded here.
    SAVE_PARTY_ACTOR = lazy { {
      1 => FieldSchema.new( name: :actor_name, type: :string ),            # 名前
      2 => FieldSchema.new( name: :title, type: :string ),                 # 二つ名 (Change Actor Title)
      # A live Change Sprite Association (10630) override, confirmed against
      # genuine RPG_RT.exe under wine (cycle #170) -- NOT liblcf's own field
      # table (no network access to `generator/csv/fields.csv` this cycle),
      # purely by experiment: a fresh New Game autostart running Change
      # Sprite Association on the default party leader (actor 15, a blank-
      # charset database row) then immediately opening the Save menu wrote
      # these three fields onto that actor's own chunk-108 entry -- 11
      # ("mainchr"), 12 (4), and, only when the command's own transparency
      # param was also set, 13 (`\x03`, the same liblcf "0 or 3" convention
      # SAVE_MOVABLE field 24 uses). A second control save from the same
      # autostart page with the Change Sprite Association command removed
      # left all three fields absent. A third save, from an actor whose
      # *database* row was patched to that same non-blank graphic with no
      # Change Sprite Association command ever run, also left 11-13 entirely
      # absent -- proving these are gated on a live "the command actually
      # ran" flag (Game::Actor#sprite_changed?), not merely "the current
      # sprite happens to be non-blank" (that weaker, blank-elided condition
      # is what chunk 104's own hero-record mirror, fields 73/74, actually
      # uses instead -- see #to_lsd's own citation). Continuing the
      # Change-Sprite-Association save under genuine RPG_RT.exe rendered the
      # leader with the saved-off "mainchr" graphic, confirming these fields
      # -- not chunk 104's -- are what a genuine Continue actually restores
      # from; this directly explains cycle #169's own negative finding that
      # patching only chunk 104's fields 73/74 in a real save never changed
      # what Continue drew.
      11 => FieldSchema.new( name: :sprite_name, type: :string ),
      12 => FieldSchema.new( name: :sprite_id, type: :int ),
      13 => FieldSchema.new( name: :sprite_transparent, type: :int, default: 0 ),
      31 => FieldSchema.new( name: :level, type: :int, default: 1 ),      # レベル
      32 => FieldSchema.new( name: :exp, type: :int, default: 0 ),        # 経験値
      51 => FieldSchema.new( name: :skill_size, type: :int, default: 0 ), # 『特技』情報のデータ数
      52 => FieldSchema.new( name: :skills, type: :int16_array ),         # 習得特技 (uint16[])
      61 => FieldSchema.new( name: :equipment, type: :int16_array ),      # 装備 [武器,盾,鎧,兜,装飾]
      71 => FieldSchema.new( name: :hp, type: :int ),                     # 現在ＨＰ
      72 => FieldSchema.new( name: :mp, type: :int ),                     # 現在ＭＰ
      # A dense array, one slot per database state id (index `state_id - 1`,
      # length `state_size`), NOT a sparse list of only the afflicted ones --
      # confirmed against a genuine kk1.12 (RPG2003) save under wine: field
      # 81 read exactly 30, that game's own total state count, on every
      # actor, none of them afflicted with anything. Each slot is a
      # per-state turn counter in genuine RPG_RT (`> 0` means afflicted),
      # not a plain boolean -- see `Game::Actor#total_state_count`'s own
      # comment for why this codebase's own writer only ever puts a plain
      # `1` there. The exact "collect `state_id - 1` wherever the slot is
      # nonzero" reconstruction is first-principles reasoning from that dense
      # shape, NOT independently confirmed against genuine RPG_RT under wine.
      81 => FieldSchema.new( name: :state_size, type: :int, default: 0 ), # 『状態』情報のデータ数
      82 => FieldSchema.new( name: :states, type: :int16_array ),         # 『状態』情報 (uint16[])

      # RPG2003 Change Battle Commands (Game::Actor#battle_commands=):
      # `changed_battle_commands` (83) gates whether `battle_commands` (80)
      # overrides the database/class default at all, or is simply the
      # not-yet-touched default -- mirroring `#battle_commands`'s own
      # nil-means-"still deferring to the class/database" convention.
      80 => FieldSchema.new( name: :battle_commands, type: :int32_array, default: [] ),
      83 => FieldSchema.new( name: :changed_battle_commands, type: :bool, default: false ),

      # RPG2003 Change Class (Game::Actor#change_class / #restore_class):
      # -1, liblcf's own default, means "never changed -- still whatever the
      # actor's own database row declares", not class id 0 ("no class" is a
      # legitimate Change Class target in its own right, distinct from
      # "unset").
      90 => FieldSchema.new( name: :class_id, type: :int, default: -1 ), # 職業ID (Change Class)

      # RPG2003 battle front/back row (Game::Actor#battle_row), toggled by the
      # in-battle Row command (ADR 0053's row mechanic). liblcf's own
      # `ChunkSaveActor` enum (lsd/chunks.h) numbers this field 0x5B, right
      # after class_id (0x5A) and before the two_weapon/lock_equipment/
      # auto_battle/super_guard/battler_animation fields below -- 0
      # (RowType_front) is both liblcf's own default and the only row
      # RPG2000 ever writes.
      91 => FieldSchema.new( name: :row, type: :int, default: 0 ), # 隊列 (2003)
      # liblcf's own generator/csv/fields.csv (0x5C-0x5F): a live mirror of
      # the actor's own current class/database-derived combat toggles
      # (Game::Actor#double_hand?/#equipment_fixed?/#force_ai?/
      # #strong_defence?), confirmed present (each only when true) on a
      # genuine kk1.12 save under wine. Purely a snapshot of state this
      # codebase already derives live from the actor's own class/database
      # row -- #to_lsd writes it for byte parity, but `.from_lsd` has
      # nothing to restore *to* (there is no separate "was this overridden"
      # concept for these four, unlike class_id/battle_commands above).
      92 => FieldSchema.new( name: :two_weapon, type: :bool, default: false ),
      93 => FieldSchema.new( name: :lock_equipment, type: :bool, default: false ),
      94 => FieldSchema.new( name: :auto_battle, type: :bool, default: false ),
      95 => FieldSchema.new( name: :super_guard, type: :bool, default: false ),

      # The live Change Parameters shadow (Game::Actor#change_param's
      # @base_raw, isolated from the level curve) -- confirmed against a
      # genuine RPG_RT.exe, not just liblcf's field table: editing field 41
      # (attack_mod) on a real save and resuming changed the Equip screen's
      # displayed ATK by exactly that amount; editing field 33 (hp_mod)
      # likewise changed the Status screen's Max HP by exactly that amount.
      # liblcf's own generator table (`generator/csv/fields.csv`) marks
      # hp_mod/sp_mod's default as -1, unlike the other four (0) -- an actor
      # that has never had a Change Parameters edit at all always leaves
      # this whole field range absent, so -1 vs. 0 never actually matters to
      # this codebase's own writer (see #to_lsd's own comment), but the -1
      # default is kept here to read a genuine third-party save's own
      # "never touched" sentinel the same way liblcf itself does, rather
      # than misreading it as a real -1 HP modifier.
      33 => FieldSchema.new( name: :hp_mod, type: :int, default: -1 ),
      34 => FieldSchema.new( name: :sp_mod, type: :int, default: -1 ),
      41 => FieldSchema.new( name: :attack_mod, type: :int, default: 0 ),
      42 => FieldSchema.new( name: :defense_mod, type: :int, default: 0 ),
      43 => FieldSchema.new( name: :spirit_mod, type: :int, default: 0 ),
      44 => FieldSchema.new( name: :agility_mod, type: :int, default: 0 ),
    } }

    # https://w.atwiki.jp/rpg2kpsp/pages/37.html
    #
    # Remembered teleport/escape destination (chunk 110), indexed by map id.
    # Index 0 is reserved for the escape target.
    SAVE_TARGET = lazy { {
      1 => FieldSchema.new( name: :map_id, type: :int ),
      2 => FieldSchema.new( name: :x, type: :int, default: 0 ),
      3 => FieldSchema.new( name: :y, type: :int, default: 0 ),
      # Turn the switch on after teleporting.
      4 => FieldSchema.new( name: :switch_on, type: :bool, default: false ),
      5 => FieldSchema.new( name: :switch_id, type: :int, default: 1 ),
    } }

    # https://w.atwiki.jp/rpg2kpsp/pages/27.html
    #
    # Saved map-event state (chunk 111). Field 11 is the per-event position
    # snapshot list (each entry reuses SAVE_MOVABLE, but without the map-id chunk
    # that only the hero/vehicle entries carry). Fields 21/22 hold the lower/upper
    # tile replacements applied by the "replace chipset tiles" event command.
    # The running map's saved event state (chunk 111). Field 11 is each map
    # event's live position (a SAVE_MOVABLE) -- confirmed against a real save:
    # all 21 saved entries matched map 12's 21 defined events, id for id and at
    # in-bounds tiles (scripts/lcf_save_check.rb re-checks this). Fields 21/22 are
    # the chipset replacement tables.
    #
    # Fields 1/2 are the **camera scroll**, in 1/16 pixel: the top-left corner of
    # the view, not a tile and not a plain pixel count. They were identified by
    # experiment against the genuine RPG_RT under wine (ADR 0021): resuming a
    # save whose hero was moved to map 1 tile (30,22) drew the map's *top-left*
    # corner whichever tile the hero was put on -- because the runtime restores
    # the view from here rather than deriving it from the hero -- and writing
    # these two fields moved it:
    #
    #   | chunk 111 fields 1/2 | RPG_RT's view                     |
    #   | -------------------- | --------------------------------- |
    #   | absent               | (0, 0), the map's top-left corner  |
    #   | 320 / 240            | scrolled ~20px, not to (320, 240)  |
    #   | 5120 / 3840          | (320, 240) exactly -- 16x the pixels |
    #
    # At 5120/3840 the frame matched our own renderer (which centres the view on
    # the hero, and puts it at (320,240) for that tile) over all but 260 of
    # 307200 pixels, the residual being one animated coastline autotile. That is
    # what pins the unit: 5120/16 = 320.
    SAVE_MAP_EVENT = lazy { {
      1 => FieldSchema.new( name: :scroll_x, type: :int, default: 0 ), # 1/16 px
      2 => FieldSchema.new( name: :scroll_y, type: :int, default: 0 ), # 1/16 px
      # A live Change Encounter Rate (11740) override, or -1/absent for "no
      # override, use the map's own encounter rate" -- confirmed against
      # liblcf's own generator table (`generator/csv/fields.csv`):
      # `SaveMapInfo,encounter_steps,f,Int32,0x03,-1,...`. The "-1/absent
      # means use the map's own rate instead" semantics are NOT independently
      # confirmed against genuine RPG_RT under wine.
      3 => FieldSchema.new( name: :encounter_steps, type: :int, default: -1 ),
      # A live Change Parallax Background (11720) override, or an absent/
      # blank name for "no override, use the map's own panorama" --
      # confirmed against liblcf's own generator table
      # (`generator/csv/fields.csv`): `SaveMapInfo,parallax_name,f,String,
      # 0x20,...` through `...,parallax_vert_speed,f,Int32,0x26,...`, seven
      # fields in this exact order. The "absent/blank means use the map's own
      # panorama" semantics are NOT independently confirmed against genuine
      # RPG_RT under wine.
      32 => FieldSchema.new( name: :parallax_name, type: :string, default: '' ),
      33 => FieldSchema.new( name: :parallax_horz, type: :bool, default: false ),
      34 => FieldSchema.new( name: :parallax_vert, type: :bool, default: false ),
      35 => FieldSchema.new( name: :parallax_horz_auto, type: :bool, default: false ),
      36 => FieldSchema.new( name: :parallax_horz_speed, type: :int, default: 0 ),
      37 => FieldSchema.new( name: :parallax_vert_auto, type: :bool, default: false ),
      38 => FieldSchema.new( name: :parallax_vert_speed, type: :int, default: 0 ),
      11 => FieldSchema.new( name: :events, type: :Array2D, elements: SAVE_MOVABLE ),
      21 => FieldSchema.new( name: :chip_replacement_lower, type: :int8_array ), # uint8[144]
      22 => FieldSchema.new( name: :chip_replacement_upper, type: :int8_array ), # uint8[144]
    } }

    # Camera scroll fields of SAVE_MAP_EVENT are stored in 1/16 pixel.
    SCROLL_UNITS_PER_PIXEL = 16

    # Party inventory (chunk 109 of the save file). Confirmed against a real
    # save: gold (21) matched the on-screen 100G, and the parallel item id/count
    # arrays matched the held items looked up in the database -- 薬草 (item 1) ×3
    # and 導きの書 (item 451) ×1, after the gate crystal had been spent. Item ids
    # are int16; counts and per-item use-counts are one byte each. The turn/step
    # counters (fields 0x29/0x2A) are now decoded too, below. Fields 23-30
    # (0x17-0x1E) are the two Timer Operation countdowns -- ids and "value is
    # seconds*60+59" both confirmed against liblcf's own `ChunkSaveInventory`
    # enum, which documents them under this chunk rather than the system chunk
    # (101) `docs/TODO.md` used to guess they would need a new id in.
    #
    # party_count (1) / party (2): the actor-id roster, split the same
    # count-then-data way as item_count/item_ids (11/12) just below --
    # confirmed against liblcf's own generator/csv/fields.csv, which
    # documents field 1 as the `Vector<Int16>` *count* and field 2 as its
    # *data*, not (as this schema had it, and #to_lsd wrote to match) a
    # single self-contained int8_array crammed into field 1 alone with field
    # 2 never written at all. A single-actor party's field 1 byte happens to
    # read identically under either schema (count 1 and "array `[1]`" are the
    # same one byte), which is exactly why this went unnoticed: kk1.12's
    # three-actor roster (`party_count` 3, `party` data `[1, 2, 3]`) does not
    # share that coincidence, and a save missing field 2 that a genuine
    # RPG_RT.exe writes crashes the real engine outright on load (confirmed
    # live under wine: the same crash a prior session's own methodology note
    # a few hundred lines down in game.rb already flagged and worked around
    # without diagnosing). `#to_lsd`/`#from_lsd` (mruby-rpg2k/mrblib/game.rb)
    # updated to match.
    SAVE_INVENTORY = lazy { {
      1 => FieldSchema.new( name: :party_count, type: :int, default: 0 ),
      2 => FieldSchema.new( name: :party, type: :int16_array ),
      11 => FieldSchema.new( name: :item_count, type: :int, default: 0 ),
      12 => FieldSchema.new( name: :item_ids, type: :int16_array ),
      13 => FieldSchema.new( name: :item_counts, type: :int8_array ),
      14 => FieldSchema.new( name: :item_usage, type: :int8_array ),
      21 => FieldSchema.new( name: :gold, type: :int, default: 0 ),
      # No `default:` on these eight (matching e.g. SAVE_SYSTEM's
      # teleport_allowed) so an absent field reads back as nil rather than a
      # concrete value -- #from_lsd tells "not in this save" from "explicitly
      # false/zero" the same way it already does for the access flags.
      23 => FieldSchema.new( name: :timer1_frames, type: :int ),
      24 => FieldSchema.new( name: :timer1_active, type: :bool ),
      25 => FieldSchema.new( name: :timer1_visible, type: :bool ),
      26 => FieldSchema.new( name: :timer1_battle, type: :bool ),
      27 => FieldSchema.new( name: :timer2_frames, type: :int ),
      28 => FieldSchema.new( name: :timer2_active, type: :bool ),
      29 => FieldSchema.new( name: :timer2_visible, type: :bool ),
      30 => FieldSchema.new( name: :timer2_battle, type: :bool ),
      # Battle tallies, the "turns passed in latest battle" counter and the
      # field step counter, likewise undefaulted -- confirmed against
      # liblcf's SaveInventory struct (all plain int32_t, like gold). Field
      # 41 (`turns`) is sourced from `Game::Battle#turn` (its live `@rounds`
      # counter), captured onto `Game::State#last_battle_turns` by
      # `Scene::Map#finish_battle` right before the fought `Battle` object is
      # discarded.
      32 => FieldSchema.new( name: :battles, type: :int ),
      33 => FieldSchema.new( name: :defeats, type: :int ),
      34 => FieldSchema.new( name: :escapes, type: :int ),
      35 => FieldSchema.new( name: :victories, type: :int ),
      41 => FieldSchema.new( name: :turns, type: :int ),
      42 => FieldSchema.new( name: :steps, type: :int ),
    } }

    # One stack frame of an interpreter's own call stack (liblcf's
    # `SaveEventExecFrame`), nested inside SAVE_EVENT_EXEC_STATE's own `stack`
    # field below. Each frame carries its OWN full `commands` list (0x02,
    # `Vector<EventCommand>` -- reusing the existing `:event` schema type, the
    # same one MAP_EVENT_PAGE's own `event_commands` uses, which already
    # round-trips through `LCF.parse_event_commands`/`encode_event_commands`),
    # i.e. the exact command page being executed, not just a reference to one
    # -- a Call Event pushes a frame whose commands come from the called
    # event, so a nested call round-trips without needing to re-resolve
    # anything (see `Game::Interpreter#call_stack_snapshot`/
    # `#restore_call_stack`, mruby-rpg2k/mrblib/interpreter.rb). Field 0x01
    # (`command_size`) mirrors field 0x02's own encoded byte length exactly,
    # the same size-field convention `MAP_EVENT_PAGE`'s own
    # `event_command_size` (field 51) already established -- see that field's
    # own comment for why a stale length hangs genuine RPG_RT.exe; this
    # codebase's own writer (`Game::State#to_lsd`) recomputes it the same way.
    #
    # `event_id` (0x0C, "0 if it's common event or in other map" per liblcf's
    # own comment): cycle #192 gave each frame its own genuine value.
    # `Game::Interpreter#do_call_event` now records, at the moment it pushes
    # each frame, the concrete map-event id that frame's own `commands` list
    # actually belongs to (via `#resolve_call`/`#map_event_call`, which
    # already resolve exactly that to look the list up in the first place),
    # or 0 when the call target was a common event -- see
    # `#call_stack_snapshot`'s own comment for exactly how each frame's
    # value is derived (the outermost frame is always this whole
    # interpreter's own `#event_id`; every frame beneath it carries its own
    # Call Event's resolved target). "...or in other map" does not name a
    # distinct, reachable case here: Call Event's own command format (param0
    # 0/1/2, see `#do_call_event`'s own comment) never names a map at all,
    # only a common-event id or a same-map event id/page, so this codebase's
    # own model has no "different map" target to ever resolve into a frame
    # -- 0 covers both the common-event case and (vacuously) that one.
    # `triggered_by_decision_key` (0x0D) is still written from this whole
    # interpreter's single `#triggered_by_decision_key`, true only for the
    # outermost frame (index 0): a Call Event's own nested frame was never
    # itself started by the action key, whatever launched the outer event --
    # this part was already correct as of cycle #191 and cycle #192 left it
    # untouched.
    #
    # `subcommand_path` (0x15 count / 0x16 data, one byte per nesting level --
    # the chosen Show Choice branch id at that level, 255 once taken, per
    # liblcf's own comment on the field) is always written empty here. This
    # engine's own Show Choices (`#do_show_choices`/`#find_choice_option`)
    # resumes purely off the flat `current_command` cursor: once a branch is
    # chosen, `@index` already points inside that branch's own commands (see
    # `#choose`), so replaying from `current_command` alone reaches the right
    # code with no separate "which Case was taken" lookup needed, unlike
    # genuine RPG_RT's own jump-to-matching-Case mechanism, which is what
    # `subcommand_path` exists to drive. Verified by reading (not by a wine
    # capture) that nothing else in this engine's interpreter ever consults a
    # branch identity beyond command position. This is a genuine, deliberate
    # simplification for this engine's own internal round-trip fidelity (its
    # own Continue), not an attempt at full interop with genuine RPG_RT.exe
    # reading our `.lsd` files (or the reverse) -- a real save captured mid a
    # Show Choices prompt would need this field decoded to resume the exact
    # same way genuine RPG_RT would.
    SAVE_EVENT_EXEC_FRAME = lazy { {
      1  => FieldSchema.new( name: :command_size, type: :int, default: 0 ),
      2  => FieldSchema.new( name: :commands, type: :event, default: [] ),
      11 => FieldSchema.new( name: :current_command, type: :int, default: 0 ),
      12 => FieldSchema.new( name: :event_id, type: :int, default: 0 ),
      13 => FieldSchema.new( name: :triggered_by_decision_key, type: :bool, default: false ),
      21 => FieldSchema.new( name: :subcommand_path_size, type: :int, default: 0 ),
      22 => FieldSchema.new( name: :subcommand_path, type: :int8_array, default: [] ),
    } }

    # An interpreter's full execution state (liblcf's `SaveEventExecState`):
    # `stack` (0x01, `Array<SaveEventExecFrame>` -- see SAVE_EVENT_EXEC_FRAME
    # just above) is the genuine call stack, outermost frame first, matching
    # `Game::Interpreter#call_stack_snapshot`'s own `@call_stack + [[@list,
    # @index, event_id]]` order (this codebase's own writer/reader convention
    # for the frame's own array index within `stack`, 1-based ascending outer
    # to inner -- not confirmed against a genuine multi-frame capture, since
    # none was available; only that a single-frame `stack` round-trips against
    # this codebase's own reading of the field table). `SaveMapEvent`'s own
    # 0x6C field and `SaveCommonEvent`'s own field 1 both point at this same
    # struct (`generator/csv/fields.csv`'s `Save.foreground_event_execstate`
    # field, 0x71 at the top-level Save struct, is the same struct again).
    #
    # Everything below `stack` -- `show_message`, `abort_on_escape`,
    # `wait_movement`, the whole keyinput_* cluster, `wait_time`, and
    # `wait_key_enter` -- is declared here for read-fidelity (so a genuine
    # third-party `.lsd` carrying them decodes cleanly instead of raising on
    # an unknown field), but is schema-only: this engine's own writer
    # (`Game::State#to_lsd`) never populates them (they are always absent,
    # reading back at their liblcf defaults below), and its own reader never
    # feeds them into any live interpreter wait state. Only `stack` is
    # genuinely round-tripped end to end. See `Game::Interpreter
    # #call_stack_snapshot`'s own comment for exactly what capturing "mid a
    # blocking wait" (Show Message/Choices/Key Input/etc.) does and does not
    # preserve today -- the call-stack position survives, the UI-facing wait
    # itself does not.
    SAVE_EVENT_EXEC_STATE = lazy { {
      1  => FieldSchema.new( name: :stack, type: :Array2D, elements: SAVE_EVENT_EXEC_FRAME ),
      4  => FieldSchema.new( name: :show_message, type: :bool, default: false ),
      11 => FieldSchema.new( name: :abort_on_escape, type: :bool, default: false ),
      13 => FieldSchema.new( name: :wait_movement, type: :bool, default: false ),
      21 => FieldSchema.new( name: :keyinput_wait, type: :bool, default: false ),
      22 => FieldSchema.new( name: :keyinput_variable, type: :uint8, default: 0 ),
      23 => FieldSchema.new( name: :keyinput_all_directions, type: :bool, default: false ),
      24 => FieldSchema.new( name: :keyinput_decision, type: :int, default: 0 ),
      25 => FieldSchema.new( name: :keyinput_cancel, type: :int, default: 0 ),
      26 => FieldSchema.new( name: :keyinput_2kshift_2k3numbers, type: :int, default: 0 ),
      27 => FieldSchema.new( name: :keyinput_2kdown_2k3operators, type: :int, default: 0 ),
      28 => FieldSchema.new( name: :keyinput_2kleft_2k3shift, type: :int, default: 0 ),
      29 => FieldSchema.new( name: :keyinput_2kright, type: :int, default: 0 ),
      30 => FieldSchema.new( name: :keyinput_2kup, type: :int, default: 0 ),
      31 => FieldSchema.new( name: :wait_time, type: :int, default: 0 ),
      32 => FieldSchema.new( name: :keyinput_time_variable, type: :int, default: 0 ),
      35 => FieldSchema.new( name: :keyinput_2k3down, type: :int, default: 0 ),
      36 => FieldSchema.new( name: :keyinput_2k3left, type: :int, default: 0 ),
      37 => FieldSchema.new( name: :keyinput_2k3right, type: :int, default: 0 ),
      38 => FieldSchema.new( name: :keyinput_2k3up, type: :int, default: 0 ),
      41 => FieldSchema.new( name: :keyinput_timed, type: :bool, default: false ),
      42 => FieldSchema.new( name: :wait_key_enter, type: :bool, default: false ),
    } }

    # Saved common-event execution state (chunk 114): an Array2D indexed by
    # common-event id -- 505 entries in a real Nepheshel save (this codebase's
    # own writer only ever writes entries for a Common Event actually running
    # a Parallel Process at save time -- see `Game::State#common_event_exec`'s
    # own comment for why the full 505-entry shape is not reproduced). Each
    # entry's field 1 is that common event's own SAVE_EVENT_EXEC_STATE --
    # NOT a simple resume index like this codebase's own, older
    # `Game::State#common_event_progress` (a command-list cursor per running
    # Common Event, still used as the `.lsd`-absent/Marshal-only fallback --
    # see that attribute's own comment). Cycle #191 wires this field to a
    # genuine `Game::Interpreter` call-stack snapshot end to end (schema
    # decode plus `Game::State#to_lsd`/`.from_lsd` plus
    # `Scene::Map#new_parallel`/`#record_parallel_progress`); verified by a
    # from-scratch round trip (encode a captured snapshot, decode it back,
    # confirm a fresh interpreter resumes and finishes identically -- see
    # `scripts/rpg2k_logic_check.rb`), not against a genuine wine-saved
    # mid-Parallel-Process `.lsd`, since none was available to compare
    # byte-for-byte against.
    SAVE_COMMON_EVENT = lazy { {
      1 => FieldSchema.new( name: :execution_state, type: :Array1D, elements: SAVE_EVENT_EXEC_STATE ),
    } }

    # Foreground (map / parallel) event interpreter state (chunk 113): the
    # event that was mid-execution when the game was saved. A save taken from
    # an on-screen choice keeps that choice's option strings inside this
    # blob, which is how the section was identified. Same
    # `SaveEventExecState` struct as SAVE_COMMON_EVENT's own field 1 above --
    # see that table's own comment for liblcf's full field breakdown and this
    # cycle's own verification method.
    #
    # "Foreground" is this codebase's own single shared interpreter
    # (`Scene::Map#@interpreter`), which runs either a map event (trigger 0
    # action key / 1 touch / Auto-Start) or an Auto-Start Common Event --
    # both share the one interpreter, matching real RPG_RT's own single
    # foreground slot. The ordinary player-driven Save menu can only ever
    # open between events (`Scene::Map#try_open_menu` bails out whenever
    # `#event_busy?`), so the one reachable way a genuine save actually
    # captures this chunk with something in it is an event's own Open Save
    # Menu command (`Cmd::OPEN_SAVE_MENU`, 11910), which parks the
    # interpreter on a `:save_menu` wait rather than stopping it -- see
    # `Game::State#foreground_event_exec`'s own comment.
    SAVE_FOREGROUND_EVENT = {
      1 => FieldSchema.new( name: :execution_state, type: :Array1D, elements: SAVE_EVENT_EXEC_STATE ),
    }

    SAVE_SYSTEM = lazy { {
      # 0 map, 1 menu, 2 battle, 3 shop, 4 name input, 5 save/load,
      # 6 title, 7 game over, 8 F9 debug menu.
      1 => FieldSchema.new( name: :scene, type: :int, default: 0 ),
      11 => FieldSchema.new( name: :frame_count, type: :int ),
      # liblcf's `SaveSystem` (generator/csv/fields.csv): `graphics_name`
      # 0x15 == 21, `message_stretch` 0x16 == 22, `font_id` 0x17 == 23 --
      # these three were declared at their raw hex *digits* (15/16/17)
      # instead of the hex *value* converted to decimal, unlike every other
      # field in this table (0x1F==31, 0x29==41, 0x33==51, ... all correctly
      # converted). `Game::State#to_lsd`/`.from_lsd` read/write the same
      # wrong tags symmetrically, so a same-engine save/load round-trip
      # never caught it -- only a genuine RPG_RT save using Change System
      # Graphics (10680), or this engine's own export opened in real
      # RPG_RT, would ever disagree.
      21 => FieldSchema.new( name: :system_graphic, type: :string ),
      22 => FieldSchema.new( name: :wallpaper_type, type: :int ),
      23 => FieldSchema.new( name: :font, type: :int ),
      31 => FieldSchema.new( name: :switch_size, type: :int, default: 0 ),
      32 => FieldSchema.new( name: :switches, type: :bool_array ),
      33 => FieldSchema.new( name: :variable_size, type: :int, default: 0 ),
      34 => FieldSchema.new( name: :variables, type: :int32_array ),
      # 0 = normal, 1 = transparent. Confirmed against a genuine RPG_RT.exe
      # save under wine (cycle #153): fields 41-44, all set together by
      # Change Message Options (10120), are each written only when they
      # differ from the default given here -- a synthetic autostart Change
      # Message Options call that reproduces the exact default state (and,
      # separately, a call that changes every field then a further call that
      # resets them all back) leaves the corresponding field(s) absent
      # exactly as if the command had never run at all, while any field
      # actually left different from its default is present with that
      # value. This is a per-value comparison at save time, not an
      # ever-touched flag -- the same convention already confirmed for field
      # 61 (`bgm_stopping`, see that field's own comment below), now spot
      # checked across this whole cluster too rather than field 41 alone.
      41 => FieldSchema.new( name: :message_transparent, type: :int, default: 0 ),
      # 0 = top, 1 = middle, 2 = bottom.
      42 => FieldSchema.new( name: :message_position, type: :int, default: 2 ),
      43 => FieldSchema.new( name: :message_prevent_overlap, type: :bool, default: true ),
      44 => FieldSchema.new( name: :message_continue_events, type: :bool, default: false ),
      # Change Face Graphic (10130) state. Confirmed against a genuine
      # RPG_RT.exe save under wine (cycle #160): each field is written only
      # when it differs from its own declared default here, independently of
      # the other three -- the same per-field "omit at default" convention
      # already confirmed for the message-config cluster just above (41-44),
      # for field 61 (`bgm_stopping`), and for the 121-124 access cluster
      # further down (see that cluster's own comment for cycle #161/#162's
      # correction there). See `Game::State#to_lsd`'s own comment in game.rb
      # for the exact capture shapes tried.
      51 => FieldSchema.new( name: :face_name, type: :string, default: '' ),
      52 => FieldSchema.new( name: :face_index, type: :int, default: 0 ),
      53 => FieldSchema.new( name: :face_right_position, type: :int, default: 0 ),
      54 => FieldSchema.new( name: :face_flip, type: :bool, default: false ),
      # NOT field 55: that is liblcf's own `event_message_active`
      # (ShowMessage/ShowChoices/ShowNumberInput bookkeeping, unrelated to
      # transparency), not a player-visibility override -- see SAVE_MOVABLE's
      # field 24 for where Set Transparent Flag's state actually lives, and
      # why it was wrongly modelled here before.
      # liblcf's `SaveSystem.music_stopping` (`generator/csv/fields.csv`,
      # `0x3D`/61) -- see `Game::State#bgm_stopping`'s own doc comment in
      # game.rb for what the flag means. Confirmed present in a genuine
      # RPG_RT.exe save under wine only while the flag is actually true: a
      # synthetic autostart list (Play BGM -> Fade Out BGM -> wait out the
      # fade -> Open Save Menu) saved with chunk 101 carrying this field as
      # a single 0x01 byte, while the identical list with no Fade Out BGM at
      # all, and a third variant that faded out and then re-issued Play BGM
      # of the same track before saving (clearing the flag back to false --
      # `#play_audio`'s own `@state.bgm_stopping = false` on every BgmPlay,
      # restart or not), both omitted field 61 entirely -- so real RPG_RT
      # writes this field only when true, the same "false is simply absent"
      # convention field 41 (`message_transparent`) already follows here,
      # and the 121-124 access cluster further down uses too (with true, not
      # false, as its own "absent" default).
      61 => FieldSchema.new( name: :bgm_stopping, type: :bool, default: false ),
      # Overridden BGM/SE playback state. An empty file name means "use the
      # database value".
      71 => FieldSchema.new( name: :title_bgm, type: :Array1D, elements: BGM ),
      72 => FieldSchema.new( name: :battle_bgm, type: :Array1D, elements: BGM ),
      73 => FieldSchema.new( name: :battle_end_bgm, type: :Array1D, elements: BGM ),
      74 => FieldSchema.new( name: :inn_bgm, type: :Array1D, elements: BGM ),
      75 => FieldSchema.new( name: :current_bgm, type: :Array1D, elements: BGM ),
      # liblcf's own generator/csv/fields.csv: `before_vehicle_music`
      # (0x4C == 76) and `before_battle_music` (0x4D == 77), the track RPG_RT
      # restores on disembark/after the fight -- the two gaps in this
      # otherwise-contiguous 71-82 BGM-slot run. Confirmed present on a
      # genuine kk1.12 save under wine (taken outside any vehicle/battle):
      # both decode as a BGM struct whose own `file` (field 1) is the
      # literal string "(OFF)" -- RPG_RT's own placeholder name for "no
      # track", rather than either field being absent outright. Wired into
      # `Game::State#to_lsd`/`.from_lsd` via `Game::State#pre_vehicle_bgm`/
      # `#pre_battle_bgm`, promoted off `Scene::Map`'s own transient
      # `@pre_vehicle_bgm`/`@pre_battle_bgm` instance variables (see that
      # class's own citation in game.rb) so the restore point survives a
      # genuine Save/Continue too, not just the current visit.
      76 => FieldSchema.new( name: :before_vehicle_music, type: :Array1D, elements: BGM ),
      77 => FieldSchema.new( name: :before_battle_music, type: :Array1D, elements: BGM ),
      78 => FieldSchema.new( name: :stored_bgm, type: :Array1D, elements: BGM ),
      79 => FieldSchema.new( name: :boat_bgm, type: :Array1D, elements: BGM ),
      80 => FieldSchema.new( name: :ship_bgm, type: :Array1D, elements: BGM ),
      81 => FieldSchema.new( name: :airship_bgm, type: :Array1D, elements: BGM ),
      82 => FieldSchema.new( name: :gameover_bgm, type: :Array1D, elements: BGM ),
      91 => FieldSchema.new( name: :cursor_se, type: :Array1D, elements: SE ),
      92 => FieldSchema.new( name: :decision_se, type: :Array1D, elements: SE ),
      93 => FieldSchema.new( name: :cancel_se, type: :Array1D, elements: SE ),
      94 => FieldSchema.new( name: :buzzer_se, type: :Array1D, elements: SE ),
      95 => FieldSchema.new( name: :battle_start_se, type: :Array1D, elements: SE ),
      96 => FieldSchema.new( name: :escape_se, type: :Array1D, elements: SE ),
      97 => FieldSchema.new( name: :enemy_attack_se, type: :Array1D, elements: SE ),
      98 => FieldSchema.new( name: :enemy_damaged_se, type: :Array1D, elements: SE ),
      99 => FieldSchema.new( name: :ally_damaged_se, type: :Array1D, elements: SE ),
      100 => FieldSchema.new( name: :evasion_se, type: :Array1D, elements: SE ),
      101 => FieldSchema.new( name: :enemy_death_se, type: :Array1D, elements: SE ),
      102 => FieldSchema.new( name: :item_se, type: :Array1D, elements: SE ),
      # Transition effects, each a single raw byte (not a BER integer). A value
      # of 0xff means "use the database value"; a real Save<N>.lsd stores 0xff
      # here, which is invalid BER, confirming these are :uint8 rather than :int.
      111 => FieldSchema.new( name: :teleport_erase_transition, type: :uint8 ),
      112 => FieldSchema.new( name: :teleport_show_transition, type: :uint8 ),
      113 => FieldSchema.new( name: :battle_start_erase_transition, type: :uint8 ),
      114 => FieldSchema.new( name: :battle_start_show_transition, type: :uint8 ),
      115 => FieldSchema.new( name: :battle_end_erase_transition, type: :uint8 ),
      116 => FieldSchema.new( name: :battle_end_show_transition, type: :uint8 ),
      # Control Teleport/Escape/Save/Menu Access (11820/11840/11930/11960).
      # All four turn out to be ONE uniform "omit at true default" cluster --
      # confirmed against genuine RPG_RT.exe under wine, probing each with a
      # synthetic autostart event issuing the matching Control command then
      # Open Save Menu with no Wait in between (the same shape cycle #160
      # used for fields 51-54). Cycle #161 tested 123/124 fully (present at
      # false right after an explicit DISABLE, absent again once a further
      # ENABLE put them back to their own true default) but only ever tested
      # 121 with an ENABLE-then-DISABLE round trip that ends at false -- a
      # test that cannot tell "written unconditionally" apart from "written
      # because false is the non-default value" -- and never independently
      # probed 122 at all, so it wrongly concluded 121/122 were an
      # "unconditional write" pair, sharing 122's convention with 121 only
      # "by analogy". Cycle #162 ran the missing test for both: an ENABLE-only
      # probe leaving each flag at **true** came back with the field
      # **absent**, matching 123/124's own pattern exactly and revealing that
      # genuine RPG_RT.exe's actual default for Teleport/Escape access is
      # **allowed**, not forbidden -- the codebase's own prior assumption
      # (`Game::State#initialize` used to set both false) was backwards. No
      # `default:` is given here for any of the four, deliberately:
      # `Game::State.from_lsd` (game.rb) tells "not in this save" (nil) from
      # "explicitly false" for all four the same way (`unless
      # sys.xxx_allowed.nil?`), so each field's own true-default constructor
      # value lives in `Game::State#initialize`, not here -- adding `default:
      # true` here would make an absent field decode as the concrete value
      # `true` instead of `nil`, collapsing that distinction (see
      # SAVE_INVENTORY's own near-identical comment on its eight undefaulted
      # timer/tally fields, which already cites this exact field as its
      # template). #to_lsd's own comment in game.rb records the write-side
      # "omit at true" gating this cluster uses.
      121 => FieldSchema.new( name: :teleport_allowed, type: :bool ),
      122 => FieldSchema.new( name: :escape_allowed, type: :bool ),
      123 => FieldSchema.new( name: :save_allowed, type: :bool ),
      124 => FieldSchema.new( name: :menu_allowed, type: :bool ),
      # Cycle #165 surfaced this field as declared but completely unplumbed
      # (`Game::State#to_lsd`/`.from_lsd` never read or wrote it) and cycle
      # #166 confirmed the underlying command it names -- Change Battle
      # Background (13210), decoded correctly by `Interpreter#
      # do_change_battle_bg` -- genuinely fires and visibly changes the live
      # battle backdrop when issued from a troop's own battle-event page
      # (verified against genuine RPG_RT.exe: troop 103's real "light"
      # backdrop swap). **Cycle #167 completed the open question and closed
      # it: this override does NOT survive past the battle it was issued in.**
      # Evidence: reused cycles #130-165's own proven-safe splice technique
      # (Map0478 event 2's genuine autostart script, spliced onto a scratch
      # Map0012.lmu copy) extended to all three of that event's real pages
      # (not just page 2 in isolation, which cycle #166 found loops forever
      # on Victory) so the fight could be won cleanly and reach an ordinary
      # save-capable map state, then appended a trailing Open Save Menu
      # (11910) command (same "genuine content + appended Open Save Menu, no
      # Wait" idiom cycle #155's picture probes already used safely) to save
      # immediately after Victory -- sidestepping the demo save's own
      # `save_allowed: false` baked into `Save01_clean.lsd`, which blocks the
      # ordinary in-game System menu's own Save entry regardless of anything
      # the battle does. Ran this twice under wine: once against troop 103
      # unmodified (baseline) and once with cycle #166's own proven-safe
      # troop-page-injection technique added to troop 103's own `RPG_RT.ldb`
      # entry (a new page, condition copied from the troop's own page 2
      # shape, running Change Battle Background("light")) -- the backdrop
      # visibly changed to the pink/white `Backdrop/light.png` gradient mid-
      # fight in the second run (screenshot evidence), confirming the change
      # genuinely fired, yet the resulting genuine `Save01.lsd`'s chunk 101
      # came back with field 125 **absent in both captures** (`LCF::
      # SaveData#key?(125)` false either way). This is a real, symmetric A/B
      # result, not an inconclusive one: the only variable between the two
      # runs was whether Change Battle Background fired, and the save
      # chunk's own shape did not differ on that field. This codebase's own
      # existing behavior -- `@battle_background` scoped entirely to the
      # live `Scene::Battle` instance, discarded when the fight ends, never
      # touching `Game::State` -- therefore already matches genuine RPG_RT.exe
      # and needs no change. Left genuinely open (not this field's own
      # concern): what field 125 actually is, if anything -- this schema's
      # `:battle_background` name was always a guess from the field's
      # position in the table, now disproven as this specific command's
      # persistence slot; no alternative candidate has been identified.
      #
      # A new candidate, from a different save entirely: a genuine kk1.12
      # (RPG2003) `Save01.lsd` captured during ordinary map exploration --
      # no battle in progress, no Change Battle Background ever issued that
      # session -- carries field 125 *present*, decoding (Shift_JIS) as
      # "草原" ("grassland/plains"), a plausible stock battle-backdrop name.
      # liblcf's own generator/csv/fields.csv independently names this exact
      # field (0x7D) `background`, a bare `String`, with no further
      # description. Together these suggest field 125 is simply the current
      # map's own resolved encounter background (or another background
      # concept entirely unrelated to Change Battle Background's own live
      # override) snapshotted for the save, present whenever *some*
      # background applies -- not gated on a live override surviving past a
      # fight the way cycle #167's own probe assumed. Not followed up
      # further this cycle (no wine session running to test the "is it the
      # map's own default backdrop" hypothesis directly); left for whoever
      # picks this back up, alongside cycle #167's own note above.
      #
      # Wired into `Game::State#to_lsd` off the same `Game::Backdrop.name_for`
      # map-tree walk `Scene::Battle#encounter_backdrop` uses, plus a
      # `Game::ChipSet`/terrain lookup built straight from the optional `db`/
      # `map_tree` arguments (see `#to_lsd`'s own citation in game.rb) --
      # `Game::ChipSet` already lives in the `Game` namespace, not
      # `Scene::Map`-only as this comment previously assumed, so no new
      # scene-layer dependency was needed after all. Not accounted for: a
      # live Change Map Tileset override (`Scene::Map`'s own `@tileset_id`),
      # which this codebase does not persist anywhere yet.
      125 => FieldSchema.new( name: :battle_background, type: :string ),
       131 => FieldSchema.new( name: :save_count, type: :int ),
      # The file slot this save was written to. Confirmed against genuine
      # RPG_RT.exe under wine (cycle #161): saving to File 1 omits this field
      # entirely (matching the `default: 1` below), while saving to File 2 /
      # File 3 writes it present with the exact chosen slot number -- the
      # same "omit at default" convention as the cluster just above. See
      # `Game::State#to_lsd`'s own comment in game.rb for the exact capture
      # shapes tried; this codebase's own `#to_lsd` used to hardcode this
      # field to 1 unconditionally regardless of the real destination slot.
       132 => FieldSchema.new( name: :save_slot, type: :int, default: 1 ),
      # liblcf's `SaveSystem.atb_mode` (0x8C == 140): the RPG2003 wait/active
      # toggle. 0 = wait (the command menu pauses the fight), 1 = active
      # (gauges keep filling while a menu is open and a ready non-controllable
      # combatant interrupts it). This is a *save-system* runtime field, not a
      # Battle Commands database field -- liblcf's BattleCommands has no wait
      # field at all, correcting the premise ADR 0054 recorded -- and it is
      # what the field menu's Wait command (id 8) flips. RPG2000 saves never
      # carry it (the chunk is 2003-only), so an absent chunk reads 0 (wait).
      140 => FieldSchema.new( name: :atb_mode, type: :int, default: 0 ),
    } }

    # Fields shown on the file-select screen (chunk 100 of the save file). The
    # wiki lists them inline at the top of the save-data page.
    SAVE_TITLE = lazy { {
      1 => FieldSchema.new( name: :timestamp, type: :double ),
      11 => FieldSchema.new( name: :hero_name, type: :string ),
      12 => FieldSchema.new( name: :hero_level, type: :int ),
      13 => FieldSchema.new( name: :hero_hp, type: :int ),
      21 => FieldSchema.new( name: :face1_name, type: :string ),
      22 => FieldSchema.new( name: :face1_index, type: :int, default: 0 ),
      23 => FieldSchema.new( name: :face2_name, type: :string ),
      24 => FieldSchema.new( name: :face2_index, type: :int, default: 0 ),
      25 => FieldSchema.new( name: :face3_name, type: :string ),
      26 => FieldSchema.new( name: :face3_index, type: :int, default: 0 ),
      27 => FieldSchema.new( name: :face4_name, type: :string ),
      28 => FieldSchema.new( name: :face4_index, type: :int, default: 0 ),
    } }

    # liblcf's SaveScreen (generator/csv/fields.csv), the screen-tint subset
    # only -- flash/shake/pan/weather/battle-animation are a separate, larger
    # save-state surface this codebase does not yet model at all in
    # Game::Screen, and are left out here too.
    SAVE_SCREEN = lazy { {
      1 => FieldSchema.new( name: :tint_finish_red, type: :int, default: 100 ),
      2 => FieldSchema.new( name: :tint_finish_green, type: :int, default: 100 ),
      3 => FieldSchema.new( name: :tint_finish_blue, type: :int, default: 100 ),
      4 => FieldSchema.new( name: :tint_finish_sat, type: :int, default: 100 ),
      11 => FieldSchema.new( name: :tint_current_red, type: :double, default: 100.0 ),
      12 => FieldSchema.new( name: :tint_current_green, type: :double, default: 100.0 ),
      13 => FieldSchema.new( name: :tint_current_blue, type: :double, default: 100.0 ),
      14 => FieldSchema.new( name: :tint_current_sat, type: :double, default: 100.0 ),
      15 => FieldSchema.new( name: :tint_time_left, type: :int, default: 0 ),
      # liblcf's own generator/csv/fields.csv (SaveScreen): the live Pan
      # Screen offset, confirmed present on a genuine kk1.12 save under
      # wine (field 42/pan_y nonzero, field 41/pan_x absent -- elided at
      # its own default 0, a vertical-only pan). `Game::Screen` already
      # tracks this (`#pan_offset`) for the Marshal save format; only the
      # `.lsd` write was missing.
      41 => FieldSchema.new( name: :pan_x, type: :int, default: 0 ),
      42 => FieldSchema.new( name: :pan_y, type: :int, default: 0 ),
      # liblcf's own fields 0x2B-0x2F (43-47): the last (or currently
      # playing) battle animation's id/target/frame/active/global-scope --
      # confirmed present (id/target/frame, all nonzero) on the same
      # genuine kk1.12 save even though it was taken on the map, not
      # mid-battle, meaning genuine RPG_RT leaves these as stale leftover
      # values rather than resetting them once the animation finishes
      # (`battleanim_active`, field 46, was itself absent/false in that
      # capture). `Game::Screen` has no equivalent "last played battle
      # animation" state to source these from at all, so left undecoded --
      # a larger gap than the pan fields above, for a future cycle.
    } }

    # https://w.atwiki.jp/rpg2kpsp/pages/13.html documents the LcfSaveData chunk
    # map. Chunks 109 (inventory) and 114 (common-event state), still marked
    # unanalysed on that wiki, were identified against a real Save01.lsd (see
    # ADR 0011). Chunk 102 (screen effects) is now handled for its tint fields
    # only (see SAVE_SCREEN above). Chunk 112 is liblcf's own `SavePanorama`
    # (generator/csv/fields.csv, top-level Save field 0x70) -- not "a one-byte
    # flag" as an earlier guess here had it (that byte is simply an empty
    # nested struct's own terminator: a genuine kk1.12 save under wine carried
    # chunk 112 present but empty, `\x00`, no fields of its own set at all).
    # SavePanorama's own field layout has not been identified, and with no
    # capture yet showing it populated there is nothing to confirm one
    # against -- left out along with 200 (a non-standard high-id extension
    # chunk) until one is. A second genuine capture, histoire203's own Save01
    # (774 maps against kk1.12's 128), agrees with kk1.12 on both counts,
    # chunk for chunk: 112 present but the same empty one-byte terminator,
    # 200 present at the identical 5 bytes -- the same shape from an
    # unrelated, much larger database, not merely a kk1.12 coincidence.
    SAVE_DATA = FieldSchema.new(
      name: :Save, type: :Array1D,
      elements: {
        100 => FieldSchema.new( name: :title, type: :Array1D, elements: SAVE_TITLE ),
        101 => FieldSchema.new( name: :system, type: :Array1D, elements: SAVE_SYSTEM ),
        102 => FieldSchema.new( name: :screen, type: :Array1D, elements: SAVE_SCREEN ),
        103 => FieldSchema.new( name: :pictures, type: :Array2D, elements: SAVE_PICTURE ),
        104 => FieldSchema.new( name: :hero, type: :Array1D, elements: SAVE_MOVABLE ),
        105 => FieldSchema.new( name: :boat, type: :Array1D, elements: SAVE_MOVABLE ),
        106 => FieldSchema.new( name: :ship, type: :Array1D, elements: SAVE_MOVABLE ),
        107 => FieldSchema.new( name: :airship, type: :Array1D, elements: SAVE_MOVABLE ),
        108 => FieldSchema.new( name: :actors, type: :Array2D, elements: SAVE_PARTY_ACTOR ),
        109 => FieldSchema.new( name: :inventory, type: :Array1D, elements: SAVE_INVENTORY ),
        110 => FieldSchema.new( name: :targets, type: :Array2D, elements: SAVE_TARGET ),
        111 => FieldSchema.new( name: :map_events, type: :Array1D, elements: SAVE_MAP_EVENT ),
        113 => FieldSchema.new( name: :foreground_event, type: :Array1D, elements: SAVE_FOREGROUND_EVENT ),
        114 => FieldSchema.new( name: :common_events, type: :Array2D, elements: SAVE_COMMON_EVENT ),
      }
    )
  end
end

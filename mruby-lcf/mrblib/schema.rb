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
    COMMON_EVENT = {
      1 => {
        name: :name, type: :string, default: ''
      },
      11 => {
        name: :start_term, type: :int, default: 5, enums: {
          3 => :auto_start,
          4 => :parallel,
          5 => :called,
        }
      },
      12 => {
        name: :need_flag, type: :bool, default: false
      },
      13 => {
        name: :switch_id, type: :int, default: 1
      },
      21 => {
        name: :event_size, type: :int
      },
      22 => {
        name: :event, type: :event
      },
    }

    BGM = {
      1 => { name: :file, type: :string },
      2 => { name: :fade_in, type: :int, default: 0 },
      3 => { name: :volume, type: :int, default: 100 },
      4 => { name: :pitch, type: :int, default: 100 },
      5 => { name: :balance, type: :int, default: 50 },
    }

    SE = {
      1 => { name: :file, type: :string },
      3 => { name: :volume, type: :int, default: 100 },
      4 => { name: :pitch, type: :int, default: 100 },
      5 => { name: :balance, type: :int, default: 50 },
    }

    # A single "skill learned at level" entry (used by actors and classes).
    LEARNING = {
      1 => { name: :level, type: :int, default: 1 },
      2 => { name: :skill_id, type: :int, default: 1 },
    }

    # Battler-animation attachment (使用時アニメ) shared by skills and items.
    # The アイテム and 特殊技能 pages document different fields of the same
    # object; this is their union. The weapon/movement fields (3, 4, 7-9, 12,
    # 13) are from the item page, the basic-CBA field (14) from the skill page.
    BATTLER_ANIMATION = {
      3 => { name: :weapon_cba, type: :int, default: 0 },        # 武器CBAの選択 (2003)
      4 => { name: :weapon, type: :int, default: 0 },            # 武器 (2003)
      5 => { name: :movement, type: :int, default: 0 },          # 移動の選択
      6 => { name: :after_image, type: :bool, default: false },  # 残像の選択
      7 => { name: :attack_times, type: :int, default: 0 },      # 攻撃の回数 (2003)
      8 => { name: :ranged_weapon, type: :bool, default: false },# 遠距離武器/使う (2003)
      9 => { name: :flying_animation, type: :int, default: 0 },  # 飛行中のアニメの選択 (2003)
      12 => { name: :speed, type: :int, default: 0 },            # 速度 (2003)
      13 => { name: :extension, type: :int, default: 1 },        # 拡張 (2003)
      14 => { name: :battle_animation_id, type: :int, default: 3 }, # 基本CBAの選択
    }

    DATABASE = {
      name: :DataBase, type: :Array1D,
      elements: {
        11 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E4%B8%BB%E4%BA%BA%E5%85%AC
          name: :player, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :title, type: :string, default: '' },
            3 => { name: :charset_name, type: :string, default: '' },
            4 => { name: :charset_index, type: :int, default: 0 },
            5 => { name: :semi_transparent, type: :bool, default: false },
            7 => { name: :initial_level, type: :int, default: 1 },
            8 => { name: :max_level, type: :int, default: -> { LCF.level_max } },
            9 => { name: :has_critical_rate, type: :bool, default: true },
            10 => { name: :critical_rate, type: :int, default: 30 },

            15 => { name: :faceset_name, type: :string, default: '' },
            16 => { name: :faceset_index, type: :int, default: 0 },

            21 => { name: :double_hand, type: :bool, default: false },       # 二刀流
            22 => { name: :equipment_fixed, type: :bool, default: false },   # 装備固定
            23 => { name: :force_ai, type: :bool, default: false },          # 強制AI
            24 => { name: :strong_defence, type: :bool, default: false },    # 強力防御

            # `order:` names only the first six raw shorts -- a level-1-only
            # view real code never actually reads for a multi-level curve
            # (see Game::Actor#base_stats's own comment): the full raw array
            # is stat-major (six max_level-sized blocks, one per stat here),
            # confirmed against a genuine RPG_RT.exe, not row-major.
            31 => { name: :status, type: :int16_array, order: [:max_hp, :max_mp, :atk, :def, :int, :agi] },

            41 => { name: :exp_basic, type: :int, default: -> { LCF.exp_default } },
            42 => { name: :exp_increase, type: :int, default: -> { LCF.exp_default } },
            43 => { name: :exp_correction, type: :int, default: -> { LCF.exp_default } },

            51 => { name: :initial_equipment, type: :int16_array, order: [:weapon, :shield, :armor, :helmet, :accessory] },

            56 => { name: :unarmed_animation, type: :int, default: 0 },      # 素手戦闘アニメID
            57 => { name: :class_id, type: :int, default: 0 },               # 職業ID (2003)
            59 => { name: :battle_x, type: :int, default: 0 },               # 手動配置X (2003)
            60 => { name: :battle_y, type: :int, default: 0 },               # 手動配置Y (2003)
            62 => { name: :battler_animation, type: :int, default: 0 },      # id into chunk 32's battleranimations (2003)
            63 => { name: :skills, type: :Array2D, elements: LEARNING },     # 習得する特殊技能
            66 => { name: :custom_battle_command, type: :bool, default: false }, # 独自戦闘コマンド有効 (2000)
            67 => { name: :custom_battle_command_name, type: :string },      # 独自戦闘コマンド名称 (2000)

            71 => { name: :state_ranks_size, type: :int, default: 0 },       # 状態有効度データ数
            72 => { name: :state_ranks, type: :int8_array },                 # 状態有効度 (byte[])
            73 => { name: :attribute_ranks_size, type: :int, default: 0 },   # 属性有効度データ数
            74 => { name: :attribute_ranks, type: :int8_array },             # 属性有効度 (byte[])

            80 => { name: :battle_commands, type: :int32_array },            # 戦闘コマンド (int[7], 2003)
          }
        },
        12 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E7%89%B9%E6%AE%8A%E6%8A%80%E8%83%BD
          name: :skill, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :description, type: :string, default: '' },
            3 => { name: :using_message1, type: :string, default: '' },
            4 => { name: :using_message2, type: :string, default: '' },
            7 => { name: :failure_message, type: :int, default: 0 },
            8 => { name: :type, type: :int, default: 0 },
            9 => { name: :sp_type, type: :int, default: 0 },
            10 => { name: :sp_percent, type: :int, default: 1 },
            11 => { name: :sp_cost, type: :int, default: 0 },
            12 => { name: :scope, type: :int, default: 0 },
            13 => { name: :switch_id, type: :int, default: 1 },              # ONにするスイッチ (種別: スイッチ)
            14 => { name: :animation_id, type: :int, default: 1 },
            16 => { name: :sound_effect, type: :Array1D, elements: SE },     # 効果音 (種別: テレポート/エスケープ/スイッチ)
            18 => { name: :occasion_field, type: :bool, default: true },     # 使用可能な場面/フィールド
            19 => { name: :occasion_battle, type: :bool, default: false },   # 使用可能な場面/バトル
            20 => { name: :reverse_state_effect, type: :bool, default: false },
            21 => { name: :physical_rate, type: :int, default: 0 },
            22 => { name: :magical_rate, type: :int, default: 3 },
            23 => { name: :variance, type: :int, default: 4 },
            24 => { name: :power, type: :int, default: 0 },
            25 => { name: :hit, type: :int, default: 100 },
            31 => { name: :affect_hp, type: :bool, default: false },
            32 => { name: :affect_sp, type: :bool, default: false },
            33 => { name: :affect_attack, type: :bool, default: false },
            34 => { name: :affect_defense, type: :bool, default: false },
            35 => { name: :affect_spirit, type: :bool, default: false },
            36 => { name: :affect_agility, type: :bool, default: false },
            37 => { name: :absorb_damage, type: :bool, default: false },
            38 => { name: :ignore_defense, type: :bool, default: false },
            41 => { name: :state_effects_size, type: :int, default: 0 },
            42 => { name: :state_effects, type: :int8_array },              # bool[]
            43 => { name: :attribute_effects_size, type: :int, default: 0 },
            44 => { name: :attribute_effects, type: :int8_array },          # bool[]
            45 => { name: :affect_attr_defence, type: :bool, default: false },
            49 => { name: :battler_animation_data_size, type: :int, default: 0 },
            50 => { name: :battler_animation_data, type: :Array2D, elements: BATTLER_ANIMATION },
          }
        },
        13 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%82%A2%E3%82%A4%E3%83%86%E3%83%A0
          name: :item, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :description, type: :string, default: '' },
            3 => { name: :type, type: :int, default: 0 },
            5 => { name: :price, type: :int, default: 0 },
            6 => { name: :uses, type: :int, default: 1 },
            11 => { name: :atk_points1, type: :int, default: 0 },
            12 => { name: :def_points1, type: :int, default: 0 },
            13 => { name: :spi_points1, type: :int, default: 0 },
            14 => { name: :agi_points1, type: :int, default: 0 },
            15 => { name: :two_handed, type: :int, default: 0 },
            16 => { name: :sp_cost, type: :int, default: 0 },
            17 => { name: :hit, type: :int, default: 0 },
            18 => { name: :critical_hit, type: :int, default: 0 },
            20 => { name: :animation_id, type: :int, default: 1 },
            21 => { name: :preemptive, type: :bool, default: false },
            22 => { name: :dual_attack, type: :bool, default: false },
            23 => { name: :attack_all, type: :bool, default: false },
            24 => { name: :ignore_evasion, type: :bool, default: false },
            25 => { name: :prevent_critical, type: :bool, default: false },  # 必殺(痛恨の一撃)防止 (盾/鎧/兜/装飾品)
            26 => { name: :raise_evasion, type: :bool, default: false },     # 物理攻撃の回避率アップ
            27 => { name: :half_sp_cost, type: :bool, default: false },      # MP消費量半分
            28 => { name: :no_terrain_damage, type: :bool, default: false }, # 地形ダメージ無効
            29 => { name: :cursed, type: :bool, default: false },
            31 => { name: :scope, type: :int, default: 0 },
            32 => { name: :recover_hp_rate, type: :int, default: 0 },
            33 => { name: :recover_hp, type: :int, default: 0 },
            34 => { name: :recover_sp_rate, type: :int, default: 0 },
            35 => { name: :recover_sp, type: :int, default: 0 },
            37 => { name: :occasion_field1, type: :bool, default: false },
            38 => { name: :ko_only, type: :bool, default: false },
            41 => { name: :max_hp_points, type: :int, default: 0 },
            42 => { name: :max_sp_points, type: :int, default: 0 },
            43 => { name: :atk_points2, type: :int, default: 0 },
            44 => { name: :def_points2, type: :int, default: 0 },
            45 => { name: :spi_points2, type: :int, default: 0 },
            46 => { name: :agi_points2, type: :int, default: 0 },
            51 => { name: :using_message, type: :int, default: 0 },
            53 => { name: :skill_id, type: :int, default: 1 },
            55 => { name: :switch_id, type: :int, default: 1 },
            57 => { name: :occasion_field2, type: :bool, default: true },
            58 => { name: :occasion_battle, type: :bool, default: false },
            61 => { name: :actor_set_size, type: :int, default: 0 },
            62 => { name: :actor_set, type: :int8_array },                  # bool[]
            63 => { name: :state_set_size, type: :int, default: 0 },
            64 => { name: :state_set, type: :int8_array },                  # bool[]
            65 => { name: :attribute_set_size, type: :int, default: 0 },
            66 => { name: :attribute_set, type: :int8_array },              # bool[]
            67 => { name: :state_chance, type: :int, default: 0 },
            68 => { name: :reverse_state_effect, type: :bool, default: false },
            69 => { name: :animation_data_size, type: :int, default: 0 },
            70 => { name: :animation_data, type: :Array2D, elements: BATTLER_ANIMATION },
            71 => { name: :use_skill, type: :bool, default: false },
            72 => { name: :class_set_size, type: :int, default: 0 },
            73 => { name: :class_set, type: :int8_array },                  # bool[]
          }
        },
        14 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%95%B5%E3%82%AD%E3%83%A3%E3%83%A9
          name: :enemy, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :battler_name, type: :string, default: '' },
            3 => { name: :battler_hue, type: :int, default: 0 },
            4 => { name: :max_hp, type: :int, default: 10 },
            5 => { name: :max_sp, type: :int, default: 10 },
            6 => { name: :attack, type: :int, default: 10 },
            7 => { name: :defense, type: :int, default: 10 },
            8 => { name: :spirit, type: :int, default: 10 },
            9 => { name: :agility, type: :int, default: 10 },
            10 => { name: :transparent, type: :bool, default: false },
            11 => { name: :exp, type: :int, default: 0 },
            12 => { name: :gold, type: :int, default: 0 },
            13 => { name: :drop_id, type: :int, default: 0 },
            14 => { name: :drop_prob, type: :int, default: 100 },
            21 => { name: :critical_hit, type: :bool, default: false },
            22 => { name: :critical_hit_chance, type: :int, default: 30 },
            26 => { name: :miss, type: :bool, default: false },
            28 => { name: :levitate, type: :bool, default: false },
            31 => { name: :state_ranks_size, type: :int, default: 0 },
            32 => { name: :state_ranks, type: :int8_array },               # byte[]
            33 => { name: :attribute_ranks_size, type: :int, default: 0 },
            34 => { name: :attribute_ranks, type: :int8_array },           # byte[]
            42 => {
              name: :actions, type: :Array2D,
              elements: {
                1 => { name: :kind, type: :int, default: 0 },
                2 => { name: :basic, type: :int, default: 0 },
                3 => { name: :skill_id, type: :int, default: 1 },
                4 => { name: :enemy_id, type: :int, default: 1 },
                5 => { name: :condition_type, type: :int, default: 0 },
                6 => { name: :condition_param1, type: :int, default: 0 },
                7 => { name: :condition_param2, type: :int, default: 0 },
                8 => { name: :switch_id, type: :int, default: 1 },
                9 => { name: :switch_on, type: :bool, default: false },
                10 => { name: :switch_on_id, type: :int, default: 1 },
                11 => { name: :switch_off, type: :bool, default: false },
                12 => { name: :switch_off_id, type: :int, default: 1 },
                13 => { name: :rating, type: :int, default: 50 },
              }
            },
          }
        },
        15 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%95%B5%E3%82%B0%E3%83%AB%E3%83%BC%E3%83%97
          name: :enemy_group, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => {
              name: :members, type: :Array2D,
              elements: {
                1 => { name: :enemy_id, type: :int, default: 1 },
                2 => { name: :x, type: :int, default: 0 },
                3 => { name: :y, type: :int, default: 0 },
                4 => { name: :invisible, type: :bool, default: false },
              }
            },
            4 => { name: :terrain_data_size, type: :int, default: 0 },
            5 => { name: :terrain_set, type: :int8_array },                # bool[]
            # ランダムに出現 (Appear Randomly): rolled once at battle start,
            # see Game::Troop#apply_appear_randomly (mruby-rpg2k/mrblib/game.rb).
            6 => { name: :appear_randomly, type: :bool, default: false },
            11 => {
              name: :pages, type: :Array2D,
              elements: {
                2 => {
                  name: :condition, type: :Array1D,
                  elements: {
                    1 => { name: :flags, type: :int, default: 0 },
                    2 => { name: :switch_a_id, type: :int, default: 1 },
                    3 => { name: :switch_b_id, type: :int, default: 1 },
                    4 => { name: :variable_id, type: :int, default: 1 },
                    5 => { name: :variable_value, type: :int, default: 0 },
                    6 => { name: :turn_a, type: :int, default: 0 },
                    7 => { name: :turn_b, type: :int, default: 0 },
                    8 => { name: :fatigue_min, type: :int, default: 0 },
                    9 => { name: :fatigue_max, type: :int, default: 100 },
                    10 => { name: :enemy_id, type: :int, default: 0 },
                    11 => { name: :enemy_hp_min, type: :int, default: 0 },
                    12 => { name: :enemy_hp_max, type: :int, default: 100 },
                    13 => { name: :actor_id, type: :int, default: 1 },
                    14 => { name: :actor_hp_min, type: :int, default: 0 },
                    15 => { name: :actor_hp_max, type: :int, default: 100 },
                    16 => { name: :turn_enemy_id, type: :int, default: 0 },
                    17 => { name: :turn_enemy_a, type: :int, default: 0 },
                    18 => { name: :turn_enemy_b, type: :int, default: 0 },
                    19 => { name: :turn_actor_id, type: :int, default: 1 },
                    20 => { name: :turn_actor_a, type: :int, default: 0 },
                    21 => { name: :turn_actor_b, type: :int, default: 0 },
                    22 => { name: :command_actor_id, type: :int, default: 1 },
                    23 => { name: :command_id, type: :int, default: 1 },
                  }
                },
                11 => { name: :event_size, type: :int, default: 4 },
                12 => { name: :event, type: :event },
              }
            },
          }
        },
        16 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E5%9C%B0%E5%BD%A2
          name: :terrain, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :damage, type: :int, default: 0 },
            3 => { name: :encounter_rate, type: :int, default: 100 },
            4 => { name: :background_name, type: :string, default: '' },
            5 => { name: :boat_pass, type: :bool, default: false },
            6 => { name: :ship_pass, type: :bool, default: false },
            7 => { name: :airship_pass, type: :bool, default: true },
            9 => { name: :airship_land, type: :bool, default: true },
            11 => { name: :bush_depth, type: :int, default: 0 },
            # RPG2003 field 0x0F is a full `Sound` struct (filename + volume +
            # tempo + balance, liblcf's own `generator/csv/fields.csv`:
            # `Terrain,footstep,f,Sound,0x0F,...`), not a bare filename --
            # the same shape every other Sound-typed database field here
            # already uses (see `SE` above). Confirmed against EasyRPG's
            # actual C++ source: `src/generated/lcf/rpg/terrain.h` declares
            # `Sound footstep;`.
            15 => { name: :footstep, type: :Array1D, elements: SE },
            16 => { name: :on_damage_se, type: :bool, default: false },
            17 => { name: :background_type, type: :int, default: 0 },
            21 => { name: :background_a_name, type: :string, default: '' },
            22 => { name: :background_a_scrollh, type: :bool, default: false },
            23 => { name: :background_a_scrollv, type: :bool, default: false },
            24 => { name: :background_a_scrollh_speed, type: :int, default: 0 },
            25 => { name: :background_a_scrollv_speed, type: :int, default: 0 },
            30 => { name: :background_b, type: :bool, default: false },
            31 => { name: :background_b_name, type: :string, default: '' },
            32 => { name: :background_b_scrollh, type: :bool, default: false },
            33 => { name: :background_b_scrollv, type: :bool, default: false },
            34 => { name: :background_b_scrollh_speed, type: :int, default: 0 },
            35 => { name: :background_b_scrollv_speed, type: :int, default: 0 },
            40 => { name: :special_flags, type: :int, default: 0 },
            41 => { name: :special_back_party, type: :int, default: 15 },
            42 => { name: :special_back_enemies, type: :int, default: 10 },
            43 => { name: :special_lateral_party, type: :int, default: 10 },
            44 => { name: :special_lateral_enemies, type: :int, default: 5 },
            45 => { name: :grid_location, type: :int, default: 0 },
            46 => { name: :grid_top_y, type: :int, default: 0 },
            47 => { name: :grid_elongation, type: :int, default: 375 },
            48 => { name: :grid_inclination, type: :int, default: 16400 },
          }
        },
        17 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E5%B1%9E%E6%80%A7
          name: :property, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :type, type: :int, default: 0 },      # 0: weapon, 1: magic
            11 => { name: :a_rate, type: :int, default: 300 },
            12 => { name: :b_rate, type: :int, default: 200 },
            13 => { name: :c_rate, type: :int, default: 100 },
            14 => { name: :d_rate, type: :int, default: 50 },
            15 => { name: :e_rate, type: :int, default: 0 },
          }
        },
        18 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E7%8A%B6%E6%85%8B
          name: :situation, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :type, type: :int, default: 0 },      # 0: battle only, 1: also on map
            3 => { name: :color, type: :int, default: 6 },
            4 => { name: :priority, type: :int, default: 50 },
            5 => { name: :restriction, type: :int, default: 0 },
            11 => { name: :a_rate, type: :int, default: 100 },
            12 => { name: :b_rate, type: :int, default: 80 },
            13 => { name: :c_rate, type: :int, default: 60 },
            14 => { name: :d_rate, type: :int, default: 30 },
            15 => { name: :e_rate, type: :int, default: 0 },
            21 => { name: :hold_turn, type: :int, default: 0 },
            22 => { name: :auto_release_prob, type: :int, default: 0 },
            23 => { name: :release_by_attack, type: :int, default: 0 },
            30 => { name: :affect_type, type: :int, default: 2 },   # 0 halve/1 double/2 no change
            31 => { name: :affect_attack, type: :bool, default: false },
            32 => { name: :affect_defense, type: :bool, default: false },
            33 => { name: :affect_spirit, type: :bool, default: false },
            34 => { name: :affect_agility, type: :bool, default: false },
            35 => { name: :reduce_hit_ratio, type: :int, default: 100 },
            36 => { name: :avoid_attacks, type: :bool, default: false },      # 2003
            37 => { name: :reflect_magic, type: :bool, default: false },      # 2003
            38 => { name: :cursed, type: :bool, default: false },             # 2003
            39 => { name: :battler_animation_id, type: :int, default: 6 },    # 2003
            41 => { name: :restrict_skill, type: :bool, default: false },
            42 => { name: :restrict_skill_level, type: :int, default: 0 },
            43 => { name: :restrict_magic, type: :bool, default: false },
            44 => { name: :restrict_magic_level, type: :int, default: 0 },
            45 => { name: :hp_change_type, type: :int, default: 0 },          # 2003
            46 => { name: :sp_change_type, type: :int, default: 0 },          # 2003
            51 => { name: :message_actor, type: :string, default: '' },       # 2000
            52 => { name: :message_enemy, type: :string, default: '' },       # 2000
            53 => { name: :message_already, type: :string, default: '' },     # 2000
            54 => { name: :message_affected, type: :string, default: '' },    # 2000
            55 => { name: :message_recovery, type: :string, default: '' },    # 2000
            61 => { name: :hp_change_max, type: :int, default: 0 },
            62 => { name: :hp_change_val, type: :int, default: 0 },
            63 => { name: :hp_change_map_steps, type: :int, default: 0 },
            64 => { name: :hp_change_map_val, type: :int, default: 0 },
            65 => { name: :sp_change_max, type: :int, default: 0 },
            66 => { name: :sp_change_val, type: :int, default: 0 },
            67 => { name: :sp_change_map_steps, type: :int, default: 0 },
            68 => { name: :sp_change_map_val, type: :int, default: 0 },
          }
        },
        19 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%88%A6%E9%97%98%E3%82%A2%E3%83%8B%E3%83%A1
          name: :battle_anime, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :animation_name, type: :string, default: '' },
            3 => { name: :large, type: :int, default: 0 },     # 2003; 0: 480x480, 1: 640x640
            6 => {
              name: :timings, type: :Array2D,
              elements: {
                1 => { name: :frame, type: :int, default: 0 },
                2 => { name: :se, type: :Array1D, elements: SE },
                3 => { name: :flash_scope, type: :int, default: 0 },   # 0 none/1 target/2 screen
                4 => { name: :flash_red, type: :int, default: 31 },
                5 => { name: :flash_green, type: :int, default: 31 },
                6 => { name: :flash_blue, type: :int, default: 31 },
                7 => { name: :flash_power, type: :int, default: 0 },
                8 => { name: :screen_shaking, type: :int, default: 0 }, # 2003
              }
            },
            9 => { name: :scope, type: :int, default: 0 },     # 0: single, 1: all
            10 => { name: :position, type: :int, default: 1 }, # 0 head/1 center/2 feet
            11 => { name: :grid, type: :bool, default: true },
            12 => {
              name: :frames, type: :Array2D,
              elements: {
                1 => {
                  name: :cells, type: :Array2D,
                  elements: {
                    1 => { name: :visible, type: :bool, default: true },
                    2 => { name: :cell_id, type: :int, default: 0 },
                    3 => { name: :x, type: :int, default: 0 },
                    4 => { name: :y, type: :int, default: 0 },
                    5 => { name: :zoom, type: :int, default: 100 },
                    6 => { name: :tone_red, type: :int, default: 100 },
                    7 => { name: :tone_green, type: :int, default: 100 },
                    8 => { name: :tone_blue, type: :int, default: 100 },
                    9 => { name: :tone_gray, type: :int, default: 100 },
                    10 => { name: :transparency, type: :int, default: 0 },
                  }
                },
              }
            },
          }
        },
        20 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%83%81%E3%83%83%E3%83%97%E3%82%BB%E3%83%83%E3%83%88
          name: :chipset, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :chipset_name, type: :string, default: '' },
            3 => { name: :terrain_data, type: :int16_array },        # 地形ID (short[162])
            4 => { name: :passable_data_lower, type: :int8_array },  # 下層通行 (byte[162])
            5 => { name: :passable_data_upper, type: :int8_array },  # 上層通行 (byte[144])
            11 => { name: :animation_type, type: :int, default: 0 }, # 水アニメパターン
            12 => { name: :animation_speed, type: :int, default: 0 }, # 水アニメ速度
          }
        },
        21 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E7%94%A8%E8%AA%9E
          name: :term, type: :Array1D,
          elements: {
            # Battle messages
            1 => { name: :encounter, type: :string, default: '' },
            2 => { name: :special_combat, type: :string, default: '' },
            3 => { name: :escape_success, type: :string, default: '' },
            4 => { name: :escape_failure, type: :string, default: '' },
            5 => { name: :victory, type: :string, default: '' },
            6 => { name: :defeat, type: :string, default: '' },
            7 => { name: :exp_received, type: :string, default: '' },
            8 => { name: :gold_received_a, type: :string, default: '' },
            9 => { name: :gold_received_b, type: :string, default: '' },
            10 => { name: :item_received, type: :string, default: '' },
            11 => { name: :attacking, type: :string, default: '' },
            12 => { name: :actor_critical, type: :string, default: '' },
            13 => { name: :enemy_critical, type: :string, default: '' },
            14 => { name: :defending, type: :string, default: '' },
            15 => { name: :observing, type: :string, default: '' },
            16 => { name: :focus, type: :string, default: '' },
            17 => { name: :autodestruction, type: :string, default: '' },
            18 => { name: :enemy_escape, type: :string, default: '' },
            19 => { name: :enemy_transform, type: :string, default: '' },
            20 => { name: :enemy_damaged, type: :string, default: '' },
            21 => { name: :enemy_undamaged, type: :string, default: '' },
            22 => { name: :actor_damaged, type: :string, default: '' },
            23 => { name: :actor_undamaged, type: :string, default: '' },
            24 => { name: :skill_failure_a, type: :string, default: '' },
            25 => { name: :skill_failure_b, type: :string, default: '' },
            26 => { name: :skill_failure_c, type: :string, default: '' },
            27 => { name: :dodge, type: :string, default: '' },
            28 => { name: :use_item, type: :string, default: '' },
            29 => { name: :hp_recovery, type: :string, default: '' },
            30 => { name: :parameter_increase, type: :string, default: '' },
            31 => { name: :parameter_decrease, type: :string, default: '' },
            32 => { name: :enemy_hp_absorbed, type: :string, default: '' },
            33 => { name: :actor_hp_absorbed, type: :string, default: '' },
            34 => { name: :resistance_increase, type: :string, default: '' },
            35 => { name: :resistance_decrease, type: :string, default: '' },
            36 => { name: :level_up, type: :string, default: '' },
            37 => { name: :skill_learned, type: :string, default: '' },
            38 => { name: :battle_start, type: :string, default: '' },  # 2003
            39 => { name: :miss, type: :string, default: '' },          # 2003

            # Shop A
            41 => { name: :shop_greeting1, type: :string, default: '' },
            42 => { name: :shop_regreeting1, type: :string, default: '' },
            43 => { name: :shop_buy1, type: :string, default: '' },
            44 => { name: :shop_sell1, type: :string, default: '' },
            45 => { name: :shop_leave1, type: :string, default: '' },
            46 => { name: :shop_buy_select1, type: :string, default: '' },
            47 => { name: :shop_buy_number1, type: :string, default: '' },
            48 => { name: :shop_purchased1, type: :string, default: '' },
            49 => { name: :shop_sell_select1, type: :string, default: '' },
            50 => { name: :shop_sell_number1, type: :string, default: '' },
            51 => { name: :shop_sold1, type: :string, default: '' },

            # Shop B
            54 => { name: :shop_greeting2, type: :string, default: '' },
            55 => { name: :shop_regreeting2, type: :string, default: '' },
            56 => { name: :shop_buy2, type: :string, default: '' },
            57 => { name: :shop_sell2, type: :string, default: '' },
            58 => { name: :shop_leave2, type: :string, default: '' },
            59 => { name: :shop_buy_select2, type: :string, default: '' },
            60 => { name: :shop_buy_number2, type: :string, default: '' },
            61 => { name: :shop_purchased2, type: :string, default: '' },
            62 => { name: :shop_sell_select2, type: :string, default: '' },
            63 => { name: :shop_sell_number2, type: :string, default: '' },
            64 => { name: :shop_sold2, type: :string, default: '' },

            # Shop C
            67 => { name: :shop_greeting3, type: :string, default: '' },
            68 => { name: :shop_regreeting3, type: :string, default: '' },
            69 => { name: :shop_buy3, type: :string, default: '' },
            70 => { name: :shop_sell3, type: :string, default: '' },
            71 => { name: :shop_leave3, type: :string, default: '' },
            72 => { name: :shop_buy_select3, type: :string, default: '' },
            73 => { name: :shop_buy_number3, type: :string, default: '' },
            74 => { name: :shop_purchased3, type: :string, default: '' },
            75 => { name: :shop_sell_select3, type: :string, default: '' },
            76 => { name: :shop_sell_number3, type: :string, default: '' },
            77 => { name: :shop_sold3, type: :string, default: '' },

            # Inn A
            80 => { name: :inn_a_greeting_1, type: :string, default: '' },
            81 => { name: :inn_a_greeting_2, type: :string, default: '' },
            82 => { name: :inn_a_greeting_3, type: :string, default: '' },
            83 => { name: :inn_a_accept, type: :string, default: '' },
            84 => { name: :inn_a_cancel, type: :string, default: '' },

            # Inn B
            85 => { name: :inn_b_greeting_1, type: :string, default: '' },
            86 => { name: :inn_b_greeting_2, type: :string, default: '' },
            87 => { name: :inn_b_greeting_3, type: :string, default: '' },
            88 => { name: :inn_b_accept, type: :string, default: '' },
            89 => { name: :inn_b_cancel, type: :string, default: '' },

            # Item / currency labels
            92 => { name: :possessed_items, type: :string, default: '' },
            93 => { name: :equipped_items, type: :string, default: '' },
            95 => { name: :gold, type: :string, default: '' },

            # Battle command menu
            101 => { name: :battle_fight, type: :string, default: '' },
            102 => { name: :battle_auto, type: :string, default: '' },
            103 => { name: :battle_escape, type: :string, default: '' },
            104 => { name: :battle_attack, type: :string, default: '' },
            105 => { name: :battle_defend, type: :string, default: '' },
            106 => { name: :battle_item, type: :string, default: '' },
            107 => { name: :battle_skill, type: :string, default: '' },
            108 => { name: :battle_equipment, type: :string, default: '' },
            110 => { name: :battle_save, type: :string, default: '' },
            112 => { name: :battle_end_game, type: :string, default: '' },

            # Title menu
            114 => { name: :new_game, type: :string, default: '' },
            115 => { name: :continue, type: :string, default: '' },
            117 => { name: :shutdown, type: :string, default: '' },

            # Main menu (2003)
            118 => { name: :status, type: :string, default: '' },
            119 => { name: :row, type: :string, default: '' },
            120 => { name: :order, type: :string, default: '' },
            121 => { name: :wait_on, type: :string, default: '' },
            122 => { name: :wait_off, type: :string, default: '' },

            # Status terms
            123 => { name: :level, type: :string, default: '' },
            124 => { name: :hp, type: :string, default: '' },
            125 => { name: :mp, type: :string, default: '' },
            126 => { name: :normal_status, type: :string, default: '' },
            127 => { name: :exp_short, type: :string, default: '' },
            128 => { name: :level_short, type: :string, default: '' },
            129 => { name: :hp_short, type: :string, default: '' },
            130 => { name: :mp_short, type: :string, default: '' },
            131 => { name: :mp_cost, type: :string, default: '' },
            132 => { name: :attack, type: :string, default: '' },
            133 => { name: :defense, type: :string, default: '' },
            134 => { name: :mind, type: :string, default: '' },
            135 => { name: :agility, type: :string, default: '' },
            136 => { name: :weapon, type: :string, default: '' },
            137 => { name: :shield, type: :string, default: '' },
            138 => { name: :armor, type: :string, default: '' },
            139 => { name: :helmet, type: :string, default: '' },
            140 => { name: :accessory, type: :string, default: '' },

            # Save / load
            146 => { name: :save_file_select, type: :string, default: '' },
            147 => { name: :load_file_select, type: :string, default: '' },
            148 => { name: :file, type: :string, default: '' },
            151 => { name: :end_game_confirm, type: :string, default: '' },
            152 => { name: :yes, type: :string, default: '' },
            153 => { name: :no, type: :string, default: '' },
          }
        },
        22 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%82%B7%E3%82%B9%E3%83%86%E3%83%A0
          name: :system, type: :Array1D,
          elements: {
            10 => { name: :maker_version, type: :int },                    # 使用ツクールバージョン
            11 => { name: :boat_name, type: :string, default: '' },
            12 => { name: :ship_name, type: :string, default: '' },
            13 => { name: :airship_name, type: :string, default: '' },
            14 => { name: :boat_index, type: :int, default: 0 },
            15 => { name: :ship_index, type: :int, default: 0 },
            16 => { name: :airship_index, type: :int, default: 0 },
            17 => { name: :title, type: :string, default: '' },            # タイトルグラフィック
            18 => { name: :gameover_name, type: :string, default: '' },
            # System graphic that supplies the window skin (background, frame
            # border and selection cursor).
            19 => { name: :system_graphic, type: :string },                # システムグラフィック
            20 => { name: :system2_name, type: :string, default: '' },     # 2003
            21 => { name: :party_size, type: :int, default: 0 },
            22 => { name: :party, type: :int16_array },                    # 初期パーティ (short[])
            26 => { name: :menu_commands_size, type: :int, default: 0 },   # 2003
            27 => { name: :menu_commands, type: :int16_array },            # 2003

            # BGM
            31 => { name: :title_music, type: :Array1D, elements: BGM },
            32 => { name: :battle_music, type: :Array1D, elements: BGM },
            33 => { name: :battle_end_music, type: :Array1D, elements: BGM },
            34 => { name: :inn_music, type: :Array1D, elements: BGM },
            35 => { name: :boat_music, type: :Array1D, elements: BGM },
            36 => { name: :ship_music, type: :Array1D, elements: BGM },
            37 => { name: :airship_music, type: :Array1D, elements: BGM },
            38 => { name: :gameover_music, type: :Array1D, elements: BGM },

            # Sound effects
            41 => { name: :cursor_se, type: :Array1D, elements: SE },
            42 => { name: :decision_se, type: :Array1D, elements: SE },
            43 => { name: :cancel_se, type: :Array1D, elements: SE },
            44 => { name: :buzzer_se, type: :Array1D, elements: SE },
            45 => { name: :battle_se, type: :Array1D, elements: SE },
            46 => { name: :escape_se, type: :Array1D, elements: SE },
            47 => { name: :enemy_attack_se, type: :Array1D, elements: SE },
            48 => { name: :enemy_damaged_se, type: :Array1D, elements: SE },
            49 => { name: :actor_damaged_se, type: :Array1D, elements: SE },
            50 => { name: :dodge_se, type: :Array1D, elements: SE },
            51 => { name: :enemy_death_se, type: :Array1D, elements: SE },
            52 => { name: :item_se, type: :Array1D, elements: SE },

            # Transitions
            61 => { name: :transition_out, type: :int, default: 0 },
            62 => { name: :transition_in, type: :int, default: 0 },
            63 => { name: :battle_start_fadeout, type: :int, default: 0 },
            64 => { name: :battle_start_fadein, type: :int, default: 0 },
            65 => { name: :battle_end_fadeout, type: :int, default: 0 },
            66 => { name: :battle_end_fadein, type: :int, default: 0 },

            # System graphic settings
            71 => { name: :message_stretch, type: :int, default: 0 },
            72 => { name: :font_id, type: :int, default: 0 },

            # Battle animation editor leftovers
            81 => { name: :selected_condition, type: :int, default: 1 },
            82 => { name: :selected_hero, type: :int, default: 1 },

            # Battle test
            84 => { name: :battle_test_background, type: :string, default: '' },
            85 => {
              name: :battle_test_data, type: :Array2D,
              elements: {
                1 => { name: :actor_id, type: :int, default: 1 },
                2 => { name: :level, type: :int, default: 1 },
                11 => { name: :weapon_id, type: :int, default: 0 },
                12 => { name: :shield_id, type: :int, default: 0 },
                13 => { name: :armor_id, type: :int, default: 0 },
                14 => { name: :helmet_id, type: :int, default: 0 },
                15 => { name: :accessory_id, type: :int, default: 0 },
              }
            },

            91 => { name: :saved_times, type: :int, default: 0 },

            # Battle test position (2003)
            94 => { name: :battle_test_terrain, type: :int, default: 0 },
            95 => { name: :battle_test_formation, type: :int, default: 0 },
            96 => { name: :battle_test_condition, type: :int, default: 0 },

            # Whether 使用可能キャラ item/equipment restriction is decided per
            # Actor (0, the default) or per Class (1) -- a single global
            # RPG2003 toggle (Game::Party#item_usable_by?'s own source).
            97 => { name: :equipment_setting, type: :int, default: 0 },

            # Decorative window (2003)
            99 => { name: :show_frame, type: :bool, default: false },
            100 => { name: :frame_name, type: :string, default: '' },
            101 => { name: :invert_animations, type: :bool, default: false },

            111 => { name: :show_title, type: :bool, default: true },
          }
        },
        23 => {
          name: :switch, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
          }
        },
        24 => {
          name: :variable, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
          }
        },
         25 => {
           # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E3%82%B3%E3%83%A2%E3%83%B3%E3%82%A4%E3%83%99%E3%83%B3%E3%83%88
           name: :common_event, type: :Array2D,
           elements: COMMON_EVENT
         },
         # RPG2003-only database sections (chunks 26/27/28 sit between the 2000
         # common-events table and the 2003 battle-commands list; 31 sits between
         # the 2003 Classes table and the Battler-Animation table). They are
         # present-but-empty in the only 2003 test bed (mtf-meido-action), so the
         # record layout is not yet transcribed from the RPG_RT specification.
         # Declared as bare Array2D tables -- every top-level database section is a
         # record table, so this is structurally correct and preserves any real
         # bytes that a non-empty project writes, while making the sections
         # nameable instead of raising on access.
         26 => { name: :section_26, type: :Array2D, elements: {} },
         27 => { name: :section_27, type: :Array2D, elements: {} },
         28 => { name: :section_28, type: :Array2D, elements: {} },
         29 => {
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
          elements: {
            # Where a living party member's battle sprite is positioned in the
            # alternative/gauge layouts (BattleCommands::Placement in liblcf):
            # 0 manual (the actor's own database `battle_x`/`battle_y`, see
            # chunk 11 fields 59/60), 1 automatic (a grid formula keyed by
            # party size/index and the encounter's terrain -- EasyRPG's
            # `CalculateBaseGridPosition`, `src/game_battle.cpp` -- not yet
            # implemented here). Confirmed against liblcf's own
            # generator/csv/fields.csv (0x02) and enums.csv, not guessed.
            2 => { name: :placement, type: :int, default: 0 },
            # RPG2003's battle-screen presentation choice (BattleType in
            # liblcf): 0 traditional (RPG2000-style status window only), 1
            # alternative (actor sprites), 2 gauge (actor sprites + HP/SP
            # gauges). RPG2000's editor has no such option, so an RPG2000
            # database never sets this and correctly reads back as 0.
            7 => { name: :battle_type, type: :int, default: 0 },
            # RPG2003-only BattleCommands field (chunk 9). A single byte (0 in the
            # mtf-meido-action test bed); the RPG_RT semantic is not yet
            # transcribed from the specification, so it is declared as a plain int
            # to keep the value round-tripping and nameable rather than guessed.
            9 => { name: :section_flags_9, type: :int, default: 0 },
            10 => {
              name: :commands, type: :Array2D,
              elements: {
                1 => { name: :name, type: :string, default: '' },
                # 0 attack, 1 skill, 2 subskill (a single named skill used as
                # its own shortcut), 3 defense, 4 item, 5 escape, 6 special.
                2 => { name: :type, type: :int, default: 0 },
              }
            },
            # RPG2003's "Death Handler": when set, a wandering-monster
            # encounter's party wipe runs common event `death_event` and/or
            # teleports the party instead of the ordinary Game Over screen --
            # confirmed against liblcf's own generator/csv/fields.csv (not
            # guessed), which also carries a `death_handler_unused` boolean
            # at 0x04 the editor always writes alongside this one but real
            # RPG_RT never reads, so it is deliberately left out of this
            # schema. See Game::Party#death_handler? (mruby-rpg2k/mrblib/
            # game.rb), which also gates this on `Player::IsRPG2k3()`
            # (EasyRPG's `Game_Battle::HasDeathHandler`, src/game_battle.cpp)
            # the same way every other RPG2003-only flag in this codebase is.
            15 => { name: :death_handler, type: :bool, default: false },
            16 => { name: :death_event, type: :int, default: 1 },
            # RPG2003-only BattleCommands field (chunk 24). A single byte (1 in the
            # mtf-meido-action test bed); the RPG_RT semantic is not yet
            # transcribed from the specification, so it is declared as a plain int
            # to keep the value round-tripping and nameable rather than guessed.
            24 => { name: :section_flags_24, type: :int, default: 0 },
            # `death_teleport_face` follows the same 1-based up/right/down/
            # left-with-0-meaning-"keep the current facing" layout as the
            # Teleport event command's own facing parameter (liblcf's
            # `BattleCommands_Facing` enum, generator/csv/enums.csv: 0
            # retain, 1 up, 2 right, 3 down, 4 left) -- see Interpreter
            # #teleport_facing, reused as-is for this field.
            25 => { name: :death_teleport, type: :bool, default: false },
            26 => { name: :death_teleport_id, type: :int, default: 1 },
            27 => { name: :death_teleport_x, type: :int, default: 0 },
            28 => { name: :death_teleport_y, type: :int, default: 0 },
            29 => { name: :death_teleport_face, type: :int, default: 0 },
          }
        },
        30 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E8%81%B7%E6%A5%AD
          name: :job, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            21 => { name: :double_hand, type: :bool, default: false },       # 二刀流
            22 => { name: :equipment_fixed, type: :bool, default: false },   # 装備固定
            23 => { name: :force_ai, type: :bool, default: false },          # 強制AI
            24 => { name: :strong_defence, type: :bool, default: false },    # 強力防御
            # 能力値 -- stat-major: six max_level-sized blocks (max_hp, max_mp,
            # atk, def, int, agi), read the same way as the actor row's own
            # field 31 above (Game::Actor#base_stats/#curve_row), confirmed
            # against a genuine RPG_RT.exe.
            31 => { name: :parameters, type: :int16_array },
            41 => { name: :exp_basic, type: :int, default: -> { LCF.exp_default } },
            42 => { name: :exp_increase, type: :int, default: -> { LCF.exp_default } },
            43 => { name: :exp_correction, type: :int, default: 0 },
            62 => { name: :battler_animation, type: :int, default: 1 },      # id into chunk 32's battleranimations
            63 => { name: :skills, type: :Array2D, elements: LEARNING },
            71 => { name: :state_ranks_size, type: :int, default: 0 },
            72 => { name: :state_ranks, type: :int8_array },
            73 => { name: :attribute_ranks_size, type: :int, default: 0 },
            74 => { name: :attribute_ranks, type: :int8_array },
             80 => { name: :battle_commands, type: :int32_array },
           }
         },
         # RPG2003-only database section (chunk 31) between the 2003 Classes
         # table and the Battler-Animation table. Present-but-empty in the only
         # 2003 test bed (mtf-meido-action); declared as a bare Array2D table --
         # structurally correct and preserves any real bytes a non-empty project
         # writes, matching the 26/27/28 sections above.
         31 => { name: :section_31, type: :Array2D, elements: {} },
         32 => {
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
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :speed, type: :int, default: 20 },
            10 => {
              # Id-keyed by Pose (see above), not a densely-packed list -- a
              # given entry may define anywhere from 0 to 12 of the 12 poses.
              name: :poses, type: :Array2D,
              elements: {
                1 => { name: :name, type: :string, default: '' },
                2 => { name: :battler_name, type: :string, default: '' },   # 戦闘(武器)グラフィック
                3 => { name: :battler_index, type: :int, default: 0 },      # グラフィック/位置
                # 0 character (a normal 4-direction charset sheet), 1 battle
                # (a CBA-style battle sheet).
                4 => { name: :animation_type, type: :int, default: 0 },
                5 => { name: :battle_animation_id, type: :int, default: 1 },
              }
            },
            11 => {
              # Per-weapon pose overrides -- out of scope for now, not needed
              # for base pose rendering; left as originally transcribed.
              name: :weapon_data, type: :Array2D,
              elements: {
                1 => { name: :name, type: :string, default: '' },
                2 => { name: :battler_name, type: :string, default: '' },   # 戦闘(武器)グラフィック
                3 => { name: :battler_position, type: :int, default: 0 },   # グラフィック/位置
              }
            },
          }
        },
      },
    }

    MAP_TREE = [
      {
        name: :map_properties, type: :Array2D,
        elements: {
          1 => { name: :name, type: :string },
          2 => { name: :parent_map_id, type: :int },
          # Editor-only node depth / management data.
          3 => { name: :indentation, type: :int },
          # 0 = root, 1 = normal map, 2 = area.
          4 => { name: :type, type: :int, default: 1 },
          # Editor-only scrollbar positions (RPG Maker's map-editor viewport),
          # stored as signed ints — not booleans.
          5 => { name: :scrollbar_x, type: :int, default: 0 },
          6 => { name: :scrollbar_y, type: :int, default: 0 },
          7 => { name: :node_extracted, type: :bool, default: false },
          11 => { name: :bgm_type, type: :int, default: 0 },
          12 => { name: :bgm, type: :Array1D, elements: BGM },
          21 => { name: :backdrop_type, type: :int, default: 0 },
          22 => { name: :backdrop_file, type: :string },
          31 => { name: :teleport, type: :int, default: 1 },
          32 => { name: :escape, type: :int, default: 1 },
          33 => { name: :save, type: :int, default: 1 },
          41 => { name: :enemy_groups, type: :Array2D, elements: {1 => { name: :enemy_group_id, type: :int, default: 1 }}},
          44 => { name: :encount_steps, type: :int, default: 25 },
          # Area bounds, only used by area nodes (type == 2): [X1, Y1, X2 + 1, Y2 + 1].
          51 => { name: :area, type: :int16_array, order: [:left, :top, :right, :bottom] },
        }
      },
      {
        name: :tree,
        type: :Tree,
      },
      {
        name: :initial,
        type: :Array1D,
        elements: {
          1 => { name: :initial_map_id, type: :int },
          2 => { name: :initial_x, type: :int },
          3 => { name: :initial_y, type: :int },

          11 => { name: :boat_map_id, type: :int },
          12 => { name: :boat_x, type: :int },
          13 => { name: :boat_y, type: :int },

          21 => { name: :ship_map_id, type: :int },
          22 => { name: :ship_x, type: :int },
          23 => { name: :ship_y, type: :int },

          31 => { name: :airship_map_id, type: :int },
          32 => { name: :airship_x, type: :int },
          33 => { name: :airship_y, type: :int },
        },
      },
    ]

    # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%9E%E3%83%83%E3%83%97
    #
    # Conditions that must hold for an event page to be active.
    MAP_EVENT_PAGE_CONDITION = {
      # Bit flags selecting which of the conditions below are enabled.
      1 => { name: :flags, type: :int, default: 0 },
      2 => { name: :switch_a_id, type: :int, default: 1 },
      3 => { name: :switch_b_id, type: :int, default: 1 },
      4 => { name: :variable_id, type: :int, default: 1 },
      5 => { name: :variable_value, type: :int, default: 0 },
      6 => { name: :item_id, type: :int, default: 1 },
      7 => { name: :actor_id, type: :int, default: 1 },
      # Genuine RPG2000 condition (flags bit 0x20): the page is active once
      # Timer1 has counted down to timer_sec seconds or below -- see
      # Game::EventPage::TIMER.
      8 => { name: :timer_sec, type: :int, default: 0 },
      # RPG2003-only: a second timer condition (flags bit 0x40, gated on
      # Player::IsRPG2k3Commands() in EasyRPG) and the variable comparison
      # operator, both now read by Game::EventPage -- see its own TIMER2 /
      # compare_operator handling there.
      9 => { name: :timer2_sec, type: :int, default: 0 },
      # 0 == 1 >= 2 <= 3 > 4 < 5 != (liblcf's EventPageCondition::Comparison
      # enum). Default 1 (>=), not 0 (==): liblcf's generated
      # eventpagecondition.h declares `int32_t compare_operator = 1;`, and an
      # absent chunk field reads as its schema default -- an RPG2000 database
      # (which never writes this RPG2003-only field at all) or an RPG2003
      # page whose editor dropdown was left at its own default both need the
      # ordinary ">=" reading, not "==", once EventPage actually consults
      # this field.
      10 => { name: :compare_operator, type: :int, default: 1 },
    }

    MOVE_ROUTE = {
      11 => { name: :command_size, type: :int, default: 0 },
      12 => { name: :commands, type: :move_commands, default: [] },
      21 => { name: :repeat, type: :bool, default: true },
      22 => { name: :skippable, type: :bool, default: false },
    }

    MAP_EVENT_PAGE = {
      2 => { name: :condition, type: :Array1D, elements: MAP_EVENT_PAGE_CONDITION },
      21 => { name: :charset_name, type: :string, default: '' },
      22 => { name: :charset_index, type: :int, default: 0 },
      # 2 = down, 4 = left, 6 = right, 8 = up.
      23 => { name: :direction, type: :int, default: 2 },
      24 => { name: :pattern, type: :int, default: 1 },
      25 => { name: :translucent, type: :bool, default: false },
      31 => { name: :move_type, type: :int, default: 0 },
      32 => { name: :move_frequency, type: :int, default: 3 },
      # Start condition: 0 = action key, 1 = touch by player, ...
      33 => { name: :trigger, type: :int, default: 0 },
      # Layer / priority: 0 = below, 1 = same, 2 = above the player.
      34 => { name: :layer, type: :int, default: 0 },
      35 => { name: :overlap_forbidden, type: :bool, default: false },
      36 => { name: :animation_type, type: :int, default: 0 },
      37 => { name: :move_speed, type: :int, default: 3 },
      41 => { name: :move_route, type: :Array1D, elements: MOVE_ROUTE },
      51 => { name: :event_command_size, type: :int, default: 0 },
      52 => { name: :event_commands, type: :event },
    }

    MAP_EVENT = {
      1 => { name: :name, type: :string, default: '' },
      2 => { name: :x, type: :int, default: 0 },
      3 => { name: :y, type: :int, default: 0 },
      5 => { name: :pages, type: :Array2D, elements: MAP_EVENT_PAGE },
    }

    MAP_UNIT = {
      name: :Map, type: :Array1D,
      elements: {
        1 => { name: :chipset_id, type: :int, default: 1 },
        2 => { name: :width, type: :int, default: 20 },
        3 => { name: :height, type: :int, default: 15 },
        # 0 = none, 1 = vertical, 2 = horizontal, 3 = both.
        11 => { name: :scroll_type, type: :int, default: 0 },
        31 => { name: :parallax_flag, type: :bool, default: false },
        32 => { name: :parallax_name, type: :string, default: '' },
        33 => { name: :parallax_loop_x, type: :bool, default: false },
        34 => { name: :parallax_loop_y, type: :bool, default: false },
        35 => { name: :parallax_autoloop_x, type: :bool, default: false },
        36 => { name: :parallax_sx, type: :int, default: 0 },
        37 => { name: :parallax_autoloop_y, type: :bool, default: false },
        38 => { name: :parallax_sy, type: :int, default: 0 },
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
        40 => { name: :generator_flag, type: :bool, default: false },
        41 => { name: :generator_mode, type: :int, default: 0 },
        42 => { name: :top_level, type: :bool, default: false },
        48 => { name: :generator_tiles, type: :int, default: 0 },
        49 => { name: :generator_width, type: :int, default: 4 },
        50 => { name: :generator_height, type: :int, default: 1 },
        51 => { name: :generator_surround, type: :bool, default: true },
        52 => { name: :generator_upper_wall, type: :bool, default: true },
        53 => { name: :generator_floor_b, type: :bool, default: true },
        54 => { name: :generator_floor_c, type: :bool, default: true },
        55 => { name: :generator_extra_b, type: :bool, default: true },
        56 => { name: :generator_extra_c, type: :bool, default: true },
        # Nine room slots. x/y are liblcf `uint32_t` vectors, read here as
        # signed 32-bit — the values are map coordinates, so the two readings
        # only differ above 2^31, which no map reaches. The tile ids are
        # shorts: reading chunk 62 as int16 yields real RPG2000 tile ids
        # (49 lower-layer, 10000/10001/10006/10007 upper-layer) where an int32
        # reading gives nonsense, which is what pins the width down.
        60 => { name: :generator_x, type: :int32_array },
        61 => { name: :generator_y, type: :int32_array },
        62 => { name: :generator_tile_ids, type: :int16_array },
        # width * height signed shorts, one tile id per cell.
        71 => { name: :lower_layer, type: :int16_array },
        72 => { name: :upper_layer, type: :int16_array },
        81 => { name: :events, type: :Array2D, elements: MAP_EVENT },
        # The 2k3e ("RPG2003 English release") save counter, a second counter
        # beside the ordinary one below. BER-encoded like every other int —
        # mtf-meido-action's first map holds 593.
        90 => { name: :save_count_2k3e, type: :int, default: 0 },
        91 => { name: :save_count, type: :int, default: 0 },
      }
    }

    # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%82%BB%E3%83%BC%E3%83%96%E3%83%87%E3%83%BC%E3%82%BF
    #
    # Snapshot of a hero or vehicle on the map. Vehicles reuse the same layout.
    SAVE_MOVABLE = {
      11 => { name: :map_id, type: :int },
      12 => { name: :x, type: :int },
      13 => { name: :y, type: :int },
      # liblcf's `SaveMapEventBase.facing` (generator/csv/fields.csv, 0x16 ==
      # 22): 0 = up, 1 = right, 2 = down, 3 = left, matching `Game_Character::
      # Direction`'s own enum order (src/game_character.h) -- *not* this
      # runtime's numpad convention (2/4/6/8). `Game::CharSet::DIR_ROW`
      # (numpad -> row index) is numerically the same up/right/down/left
      # table, so it doubles as the encoder here; `EventGraphic.
      # numpad_direction` is the decoder, the same conversion the database-
      # side event-page facing field already needs.
      22 => { name: :direction, type: :int },
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
      24 => { name: :transparency, type: :int, default: 0 },
      35 => { name: :animation_type, type: :int },
      37 => { name: :move_speed, type: :int },
      # SaveMapEventBase's own move-route cursor: how far into a page's
      # move_type CUSTOM route this event had gotten (Game::MoveRoute#index),
      # sourced from EasyRPG's liblcf generator/csv/fields.csv (0x2B == 43).
      # liblcf also has a SaveMapEvent.original_move_route_index (0x66/102),
      # tracking the route in force *before* a Set Move Route override --
      # left undecoded, since this codebase's own Game::State
      # #map_event_route_index has no separate "original vs current route"
      # concept to source it from, only the single live cursor field 43
      # already covers. No `default:` (matching e.g. SAVE_INVENTORY's
      # turns/steps counters), so an absent field reads back as nil rather
      # than 0 -- Game::State.from_lsd tells "no saved cursor, restart the
      # route from the top" from "explicitly at command 0" the same way.
      43 => { name: :move_route_index, type: :int },
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
      73 => { name: :charset_name, type: :string },
      74 => { name: :charset_index, type: :int },
    }

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
    SAVE_PICTURE = {
      1 => { name: :name, type: :string },              # ピクチャグラフィックのファイル名
      2 => { name: :show_x, type: :double, default: 0.0 },
      3 => { name: :show_y, type: :double, default: 0.0 },
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
      4 => { name: :current_x, type: :double, default: 0.0 },
      5 => { name: :current_y, type: :double, default: 0.0 },
      7 => { name: :current_zoom, type: :double, default: 100.0 },
      8 => { name: :current_transparency, type: :double, default: 0.0 },
      11 => { name: :current_tone_red, type: :double, default: 100.0 },
      12 => { name: :current_tone_green, type: :double, default: 100.0 },
      13 => { name: :current_tone_blue, type: :double, default: 100.0 },
      14 => { name: :current_tone_saturation, type: :double, default: 100.0 },
      # 表示するか (0 非表示 / 1 表示) -- a name inferred from the field id's
      # own position in this table (between the current_* and finish_*
      # clusters), never confirmed against a genuine RPG_RT.exe capture that
      # actually carries it. Cycle #159 looked for it in the one new scenario
      # this cycle's own genuine-wine evidence could reach (a picture shown
      # then Erase Picture'd, then saved) and still did not find it present
      # -- an erased id's own chunk 103 entry keeps every other field
      # (2/3/4/5/7/8/11-14/31/32/33/34/41-44) but field 9 stayed absent there
      # too, the same as every other capture cycles #154/#155 already tried
      # (a never-touched slot, an at-rest shown picture, one pushed off every
      # visual default, and one mid-Move-Picture). Five distinct genuine
      # capture shapes across three cycles have now never once observed this
      # field present -- consistent with it being unused by any ordinary
      # RPG2000 Show/Move/Erase Picture sequence, though still not proof no
      # scenario ever writes it (RPG2003's own picture flag set, e.g., was
      # never tried). Left as `default: false` (matching a picture that was
      # never shown) since nothing in this codebase reads or writes it.
      9 => { name: :visible, type: :bool, default: false },
      # The picture's resting/target position -- see this table's own
      # comment above for why these are named finish_*, not current_*.
      31 => { name: :finish_x, type: :double, default: 0.0 }, # 表示位置Ｘ (中心)
      32 => { name: :finish_y, type: :double, default: 0.0 }, # 表示位置Ｙ (中心)
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
      33 => { name: :zoom, type: :int, default: 100 },        # 拡大率
      34 => { name: :transparency, type: :int, default: 0 },  # 透明度
      41 => { name: :tone_red, type: :int, default: 100 },        # 色調：赤(R)
      42 => { name: :tone_green, type: :int, default: 100 },      # 色調：緑(G)
      43 => { name: :tone_blue, type: :int, default: 100 },       # 色調：青(B)
      44 => { name: :tone_saturation, type: :int, default: 100 }, # 色調：彩度(S)
      # How many frames remain in an in-flight Move Picture; 0 (the default,
      # covering both a still picture and an old save missing this field
      # entirely) means #restore_pictures does not start a fresh move on load.
      51 => { name: :time_left, type: :int, default: 0 },
    }

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
    # confirmed against EasyRPG's `liblcf` (`generator/csv/fields.csv`), whose
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
    SAVE_PARTY_ACTOR = {
      1 => { name: :actor_name, type: :string },            # 名前
      2 => { name: :title, type: :string },                 # 二つ名 (Change Actor Title)
      31 => { name: :level, type: :int, default: 1 },      # レベル
      32 => { name: :exp, type: :int, default: 0 },        # 経験値
      51 => { name: :skill_size, type: :int, default: 0 }, # 『特技』情報のデータ数
      52 => { name: :skills, type: :int16_array },         # 習得特技 (uint16[])
      61 => { name: :equipment, type: :int16_array },      # 装備 [武器,盾,鎧,兜,装飾]
      71 => { name: :hp, type: :int },                     # 現在ＨＰ
      72 => { name: :mp, type: :int },                     # 現在ＭＰ
      81 => { name: :state_size, type: :int, default: 0 }, # 『状態』情報のデータ数
      82 => { name: :states, type: :int16_array },         # 『状態』情報 (uint16[])

      # RPG2003 Change Battle Commands (Game::Actor#battle_commands=):
      # `changed_battle_commands` (83) gates whether `battle_commands` (80)
      # overrides the database/class default at all, or is simply the
      # not-yet-touched default -- mirroring `#battle_commands`'s own
      # nil-means-"still deferring to the class/database" convention.
      80 => { name: :battle_commands, type: :int32_array, default: [] },
      83 => { name: :changed_battle_commands, type: :bool, default: false },

      # RPG2003 Change Class (Game::Actor#change_class / #restore_class):
      # -1, liblcf's own default, means "never changed -- still whatever the
      # actor's own database row declares", not class id 0 ("no class" is a
      # legitimate Change Class target in its own right, distinct from
      # "unset").
      90 => { name: :class_id, type: :int, default: -1 }, # 職業ID (Change Class)

      # RPG2003 battle front/back row (Game::Actor#battle_row), toggled by the
      # in-battle Row command (ADR 0053's row mechanic). liblcf's own
      # `ChunkSaveActor` enum (lsd/chunks.h) numbers this field 0x5B, right
      # after class_id (0x5A) and before the two_weapon/lock_equipment/
      # auto_battle/super_guard/battler_animation fields this schema does not
      # declare yet -- 0 (RowType_front) is both liblcf's own default and the
      # only row RPG2000 ever writes.
      91 => { name: :row, type: :int, default: 0 }, # 隊列 (2003)

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
      33 => { name: :hp_mod, type: :int, default: -1 },
      34 => { name: :sp_mod, type: :int, default: -1 },
      41 => { name: :attack_mod, type: :int, default: 0 },
      42 => { name: :defense_mod, type: :int, default: 0 },
      43 => { name: :spirit_mod, type: :int, default: 0 },
      44 => { name: :agility_mod, type: :int, default: 0 },
    }

    # https://w.atwiki.jp/rpg2kpsp/pages/37.html
    #
    # Remembered teleport/escape destination (chunk 110), indexed by map id.
    # Index 0 is reserved for the escape target.
    SAVE_TARGET = {
      1 => { name: :map_id, type: :int },
      2 => { name: :x, type: :int, default: 0 },
      3 => { name: :y, type: :int, default: 0 },
      # Turn the switch on after teleporting.
      4 => { name: :switch_on, type: :bool, default: false },
      5 => { name: :switch_id, type: :int, default: 1 },
    }

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
    SAVE_MAP_EVENT = {
      1 => { name: :scroll_x, type: :int, default: 0 }, # 1/16 px
      2 => { name: :scroll_y, type: :int, default: 0 }, # 1/16 px
      # A live Change Encounter Rate (11740) override, or -1/absent for "no
      # override, use the map's own encounter rate" -- confirmed against
      # liblcf's own generator table (`generator/csv/fields.csv`):
      # `SaveMapInfo,encounter_steps,f,Int32,0x03,-1,...`, matching
      # `Game_Map::PrepareSave`/`SetEncounterSteps` (`src/game_map.cpp`).
      3 => { name: :encounter_steps, type: :int, default: -1 },
      # A live Change Parallax Background (11720) override, or an absent/
      # blank name for "no override, use the map's own panorama" --
      # confirmed against liblcf's own generator table
      # (`generator/csv/fields.csv`): `SaveMapInfo,parallax_name,f,String,
      # 0x20,...` through `...,parallax_vert_speed,f,Int32,0x26,...`, seven
      # fields matching `Game_Map::Parallax::ChangeBG`/`GetParallaxParams`
      # (`src/game_map.cpp`) exactly.
      32 => { name: :parallax_name, type: :string, default: '' },
      33 => { name: :parallax_horz, type: :bool, default: false },
      34 => { name: :parallax_vert, type: :bool, default: false },
      35 => { name: :parallax_horz_auto, type: :bool, default: false },
      36 => { name: :parallax_horz_speed, type: :int, default: 0 },
      37 => { name: :parallax_vert_auto, type: :bool, default: false },
      38 => { name: :parallax_vert_speed, type: :int, default: 0 },
      11 => { name: :events, type: :Array2D, elements: SAVE_MOVABLE },
      21 => { name: :chip_replacement_lower, type: :int8_array }, # uint8[144]
      22 => { name: :chip_replacement_upper, type: :int8_array }, # uint8[144]
    }

    # Camera scroll fields of SAVE_MAP_EVENT are stored in 1/16 pixel.
    SCROLL_UNITS_PER_PIXEL = 16

    # Party inventory (chunk 109 of the save file). Confirmed against a real
    # save: gold (21) matched the on-screen 100G, and the parallel item id/count
    # arrays matched the held items looked up in the database -- 薬草 (item 1) ×3
    # and 導きの書 (item 451) ×1, after the gate crystal had been spent. Item ids
    # are int16; counts and per-item use-counts are one byte each. Field 1 is the
    # party roster (actor ids); the sole entry `[1]` is actor 1, whose database
    # charset matches the saved hero. The turn/step counters (fields 0x29/0x2A)
    # are now decoded too, below. Fields 23-30 (0x17-0x1E) are the two Timer
    # Operation countdowns -- ids and "value is seconds*60+59" both confirmed
    # against liblcf's own `ChunkSaveInventory` enum, which documents them
    # under this chunk rather than the system chunk (101) `docs/TODO.md` used
    # to guess they would need a new id in.
    SAVE_INVENTORY = {
      1 => { name: :party, type: :int8_array },
      11 => { name: :item_count, type: :int, default: 0 },
      12 => { name: :item_ids, type: :int16_array },
      13 => { name: :item_counts, type: :int8_array },
      14 => { name: :item_usage, type: :int8_array },
      21 => { name: :gold, type: :int, default: 0 },
      # No `default:` on these eight (matching e.g. SAVE_SYSTEM's
      # teleport_allowed) so an absent field reads back as nil rather than a
      # concrete value -- #from_lsd tells "not in this save" from "explicitly
      # false/zero" the same way it already does for the access flags.
      23 => { name: :timer1_frames, type: :int },
      24 => { name: :timer1_active, type: :bool },
      25 => { name: :timer1_visible, type: :bool },
      26 => { name: :timer1_battle, type: :bool },
      27 => { name: :timer2_frames, type: :int },
      28 => { name: :timer2_active, type: :bool },
      29 => { name: :timer2_visible, type: :bool },
      30 => { name: :timer2_battle, type: :bool },
      # Battle tallies, the "turns passed in latest battle" counter and the
      # field step counter, likewise undefaulted -- confirmed against
      # liblcf's SaveInventory struct (all plain int32_t, like gold). Field
      # 41 (`turns`) is sourced from `Game::Battle#turn` (its live `@rounds`
      # counter), captured onto `Game::State#last_battle_turns` by
      # `Scene::Map#finish_battle` right before the fought `Battle` object is
      # discarded.
      32 => { name: :battles, type: :int },
      33 => { name: :defeats, type: :int },
      34 => { name: :escapes, type: :int },
      35 => { name: :victories, type: :int },
      41 => { name: :turns, type: :int },
      42 => { name: :steps, type: :int },
    }

    # Saved common-event execution state (chunk 114): an Array2D indexed by
    # common-event id -- 505 entries in a real Nepheshel save. Each entry's
    # field 1 is that event's interpreter execution state, kept as an opaque blob
    # (like SAVE_MAP_EVENT's tile replacements) until its grammar is documented.
    SAVE_COMMON_EVENT = {
      1 => { name: :execution_state, type: :int8_array },
    }

    # Foreground (map / parallel) event interpreter state (chunk 113): the event
    # that was mid-execution when the game was saved. A save taken from an
    # on-screen choice keeps that choice's option strings inside this blob, which
    # is how the section was identified; its inner grammar is left opaque for now.
    SAVE_FOREGROUND_EVENT = {
      1 => { name: :execution_state, type: :int8_array },
    }

    SAVE_SYSTEM = {
      # 0 map, 1 menu, 2 battle, 3 shop, 4 name input, 5 save/load,
      # 6 title, 7 game over, 8 F9 debug menu.
      1 => { name: :scene, type: :int, default: 0 },
      11 => { name: :frame_count, type: :int },
      # liblcf's `SaveSystem` (generator/csv/fields.csv): `graphics_name`
      # 0x15 == 21, `message_stretch` 0x16 == 22, `font_id` 0x17 == 23 --
      # these three were declared at their raw hex *digits* (15/16/17)
      # instead of the hex *value* converted to decimal, unlike every other
      # field in this table (0x1F==31, 0x29==41, 0x33==51, ... all correctly
      # converted). `Game::State#to_lsd`/`.from_lsd` read/write the same
      # wrong tags symmetrically, so a same-engine save/load round-trip
      # never caught it -- only a genuine RPG_RT save using Change System
      # Graphics (10680), or this engine's own export opened in real
      # RPG_RT/EasyRPG, would ever disagree.
      21 => { name: :system_graphic, type: :string },
      22 => { name: :wallpaper_type, type: :int },
      23 => { name: :font, type: :int },
      31 => { name: :switch_size, type: :int, default: 0 },
      32 => { name: :switches, type: :bool_array },
      33 => { name: :variable_size, type: :int, default: 0 },
      34 => { name: :variables, type: :int32_array },
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
      41 => { name: :message_transparent, type: :int, default: 0 },
      # 0 = top, 1 = middle, 2 = bottom.
      42 => { name: :message_position, type: :int, default: 2 },
      43 => { name: :message_prevent_overlap, type: :bool, default: true },
      44 => { name: :message_continue_events, type: :bool, default: false },
      # Change Face Graphic (10130) state. Confirmed against a genuine
      # RPG_RT.exe save under wine (cycle #160): each field is written only
      # when it differs from its own declared default here, independently of
      # the other three -- the same per-field "omit at default" convention
      # already confirmed for the message-config cluster just above (41-44)
      # and for field 61 (`bgm_stopping`) -- not the unconditional-write
      # convention fields 121-124 use. See `Game::State#to_lsd`'s own comment
      # in game.rb for the exact capture shapes tried.
      51 => { name: :face_name, type: :string, default: '' },
      52 => { name: :face_index, type: :int, default: 0 },
      53 => { name: :face_right_position, type: :int, default: 0 },
      54 => { name: :face_flip, type: :bool, default: false },
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
      # not the unconditional-write convention fields 121-124 use.
      61 => { name: :bgm_stopping, type: :bool, default: false },
      # Overridden BGM/SE playback state. An empty file name means "use the
      # database value".
      71 => { name: :title_bgm, type: :Array1D, elements: BGM },
      72 => { name: :battle_bgm, type: :Array1D, elements: BGM },
      73 => { name: :battle_end_bgm, type: :Array1D, elements: BGM },
      74 => { name: :inn_bgm, type: :Array1D, elements: BGM },
      75 => { name: :current_bgm, type: :Array1D, elements: BGM },
      78 => { name: :stored_bgm, type: :Array1D, elements: BGM },
      79 => { name: :boat_bgm, type: :Array1D, elements: BGM },
      80 => { name: :ship_bgm, type: :Array1D, elements: BGM },
      81 => { name: :airship_bgm, type: :Array1D, elements: BGM },
      82 => { name: :gameover_bgm, type: :Array1D, elements: BGM },
      91 => { name: :cursor_se, type: :Array1D, elements: SE },
      92 => { name: :decision_se, type: :Array1D, elements: SE },
      93 => { name: :cancel_se, type: :Array1D, elements: SE },
      94 => { name: :buzzer_se, type: :Array1D, elements: SE },
      95 => { name: :battle_start_se, type: :Array1D, elements: SE },
      96 => { name: :escape_se, type: :Array1D, elements: SE },
      97 => { name: :enemy_attack_se, type: :Array1D, elements: SE },
      98 => { name: :enemy_damaged_se, type: :Array1D, elements: SE },
      99 => { name: :ally_damaged_se, type: :Array1D, elements: SE },
      100 => { name: :evasion_se, type: :Array1D, elements: SE },
      101 => { name: :enemy_death_se, type: :Array1D, elements: SE },
      102 => { name: :item_se, type: :Array1D, elements: SE },
      # Transition effects, each a single raw byte (not a BER integer). A value
      # of 0xff means "use the database value"; a real Save<N>.lsd stores 0xff
      # here, which is invalid BER, confirming these are :uint8 rather than :int.
      111 => { name: :teleport_erase_transition, type: :uint8 },
      112 => { name: :teleport_show_transition, type: :uint8 },
      113 => { name: :battle_start_erase_transition, type: :uint8 },
      114 => { name: :battle_start_show_transition, type: :uint8 },
      115 => { name: :battle_end_erase_transition, type: :uint8 },
      116 => { name: :battle_end_show_transition, type: :uint8 },
      121 => { name: :teleport_allowed, type: :bool },
      122 => { name: :escape_allowed, type: :bool },
      123 => { name: :save_allowed, type: :bool },
      124 => { name: :menu_allowed, type: :bool },
      125 => { name: :battle_background, type: :string },
       131 => { name: :save_count, type: :int },
       132 => { name: :save_slot, type: :int, default: 1 },
      # liblcf's `SaveSystem.atb_mode` (0x8C == 140): the RPG2003 wait/active
      # toggle. 0 = wait (the command menu pauses the fight), 1 = active
      # (gauges keep filling while a menu is open and a ready non-controllable
      # combatant interrupts it). This is a *save-system* runtime field, not a
      # Battle Commands database field -- liblcf's BattleCommands has no wait
      # field at all, correcting the premise ADR 0054 recorded -- and it is
      # what the field menu's Wait command (id 8) flips. RPG2000 saves never
      # carry it (the chunk is 2003-only), so an absent chunk reads 0 (wait).
      140 => { name: :atb_mode, type: :int, default: 0 },
    }

    # Fields shown on the file-select screen (chunk 100 of the save file). The
    # wiki lists them inline at the top of the save-data page.
    SAVE_TITLE = {
      1 => { name: :timestamp, type: :double },
      11 => { name: :hero_name, type: :string },
      12 => { name: :hero_level, type: :int },
      13 => { name: :hero_hp, type: :int },
      21 => { name: :face1_name, type: :string },
      22 => { name: :face1_index, type: :int, default: 0 },
      23 => { name: :face2_name, type: :string },
      24 => { name: :face2_index, type: :int, default: 0 },
      25 => { name: :face3_name, type: :string },
      26 => { name: :face3_index, type: :int, default: 0 },
      27 => { name: :face4_name, type: :string },
      28 => { name: :face4_index, type: :int, default: 0 },
    }

    # liblcf's SaveScreen (generator/csv/fields.csv), the screen-tint subset
    # only -- flash/shake/pan/weather/battle-animation are a separate, larger
    # save-state surface this codebase does not yet model at all in
    # Game::Screen, and are left out here too.
    SAVE_SCREEN = {
      1 => { name: :tint_finish_red, type: :int, default: 100 },
      2 => { name: :tint_finish_green, type: :int, default: 100 },
      3 => { name: :tint_finish_blue, type: :int, default: 100 },
      4 => { name: :tint_finish_sat, type: :int, default: 100 },
      11 => { name: :tint_current_red, type: :double, default: 100.0 },
      12 => { name: :tint_current_green, type: :double, default: 100.0 },
      13 => { name: :tint_current_blue, type: :double, default: 100.0 },
      14 => { name: :tint_current_sat, type: :double, default: 100.0 },
      15 => { name: :tint_time_left, type: :int, default: 0 },
    }

    # https://w.atwiki.jp/rpg2kpsp/pages/13.html documents the LcfSaveData chunk
    # map. Chunks 109 (inventory) and 114 (common-event state), still marked
    # unanalysed on that wiki, were identified against a real Save01.lsd (see
    # ADR 0011). Chunk 102 (screen effects) is now handled for its tint fields
    # only (see SAVE_SCREEN above). Chunk 112 (a one-byte flag) and 200 (a
    # non-standard high-id extension chunk) are still left out until confirmed.
    SAVE_DATA = {
      name: :Save, type: :Array1D,
      elements: {
        100 => { name: :title, type: :Array1D, elements: SAVE_TITLE },
        101 => { name: :system, type: :Array1D, elements: SAVE_SYSTEM },
        102 => { name: :screen, type: :Array1D, elements: SAVE_SCREEN },
        103 => { name: :pictures, type: :Array2D, elements: SAVE_PICTURE },
        104 => { name: :hero, type: :Array1D, elements: SAVE_MOVABLE },
        105 => { name: :boat, type: :Array1D, elements: SAVE_MOVABLE },
        106 => { name: :ship, type: :Array1D, elements: SAVE_MOVABLE },
        107 => { name: :airship, type: :Array1D, elements: SAVE_MOVABLE },
        108 => { name: :actors, type: :Array2D, elements: SAVE_PARTY_ACTOR },
        109 => { name: :inventory, type: :Array1D, elements: SAVE_INVENTORY },
        110 => { name: :targets, type: :Array2D, elements: SAVE_TARGET },
        111 => { name: :map_events, type: :Array1D, elements: SAVE_MAP_EVENT },
        113 => { name: :foreground_event, type: :Array1D, elements: SAVE_FOREGROUND_EVENT },
        114 => { name: :common_events, type: :Array2D, elements: SAVE_COMMON_EVENT },
      }
    }
  end

  class File
    def initialize io = nil
      # No stream builds an empty, writable file from scratch: an empty root of
      # the schema's type, ready to populate via #[]= and serialise with #to_lcf
      # / #save_to. Multi-section (Array-schema) files are not yet buildable.
      if io.nil?
        raise 'section-based file construction not implemented' if schema.is_a? Array
        @root = LCF.const_get(schema[:type]).new('', schema)
        return
      end
      @io = io
      h_len = LCF.read_ber io
      h = io.read h_len
      raise "Invalid header: #{h} (expected: #{header})" if h != header
      if schema.is_a? Array
        sections = LCF::Sections.new
        schema.each { |s| sections.add s[:name], LCF.read_section(io, s) }
        @root = sections
      else
        @root = LCF.const_get(schema[:type]).new io, schema
      end
    end

    def header; raise end
    def schema; raise end

    # Whether the root chunk list ends with a trailing 0x00 terminator.
    # `.lsd` (SaveData) and `.ldb` (Database) do not -- confirmed by a
    # byte-exact round-trip of a genuine RPG_RT.ldb and Save01.lsd with no
    # appended byte -- so this defaults to false. `.lmu` (MapUnit) is the one
    # exception: overridden below.
    def terminate_root?; false end

    # Serialise the whole file back to bytes: the BER-length-prefixed header
    # string followed by the root object's own serialisation. The inverse of
    # #initialize; a file read and written back without edits reproduces it
    # byte-for-byte. Multi-section (Array-schema) files are not yet writable.
    def to_lcf
      raise 'section-based file serialization not implemented' if schema.is_a? Array
      root = @root.is_a?(LCF::Array1D) ? @root.to_lcf(terminate_root?) : @root.to_lcf
      LCF.write_ber(header.bytesize) + LCF.binstr(header) + LCF.binstr(root)
    end

    # Write #to_lcf to a path (binary). Uses ::File since LCF::File shadows it.
    def save_to path
      ::File.open(path, 'wb') { |f| f.write to_lcf }
    end

    def method_missing sym, *args
      # Use __send__ rather than send: some mruby builds do not expose Kernel#send
      # on objects that define their own method_missing (Array1D / Sections),
      # which routes `send` into method_missing and breaks field access.
      @root.__send__ sym, *args
    end

    def respond_to_missing? sym, include_private = false
      @root.respond_to?(sym) || super
    end
  end

  class Database < File
    def header; "LcfDataBase" end
    def schema; LCF::Schema::DATABASE end

    # RPG Maker 2003 databases carry a Classes (職業) section, chunk 30, that
    # RPG2000 never writes. Its presence is the file-level signal that a project
    # was authored in 2003, independent of the compile-time LCF::MODE default.
    def rpg2003?
      @root.key? 30
    end

    # Editor edition that wrote this database: 2003 or 2000.
    def maker
      rpg2003? ? 2003 : 2000
    end
  end

  class MapTree < File
    def header; "LcfMapTree" end
    def schema; LCF::Schema::MAP_TREE end
  end

  class MapUnit < File
    def header; "LcfMapUnit" end
    def schema; LCF::Schema::MAP_UNIT end

    # Unlike .lsd/.ldb, a genuine .lmu carries a trailing 0x00 root
    # terminator -- confirmed by round-tripping real Nepheshel Map*.lmu
    # files: every one came out exactly one byte short without this, and
    # byte-identical to the original with it. Confirmed to matter at
    # runtime too: a genuine RPG_RT.exe hangs on a black screen loading a
    # map file written without this byte, and loads it correctly once
    # appended.
    def terminate_root?; true end
  end

  class SaveData < File
    def header; "LcfSaveData" end
    def schema; LCF::Schema::SAVE_DATA end
  end
end

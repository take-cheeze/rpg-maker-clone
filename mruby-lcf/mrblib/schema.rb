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
            8 => { name: :max_level, type: :int, default: -> { LCF.max_level } },
            9 => { name: :has_critical_rate, type: :bool, default: true },
            10 => { name: :critical_rate, type: :int, default: 30 },

            15 => { name: :faceset_name, type: :string, default: '' },
            16 => { name: :faceset_index, type: :int, default: 0 },

            21 => { name: :double_hand, type: :bool, default: false },       # 二刀流
            22 => { name: :equipment_fixed, type: :bool, default: false },   # 装備固定
            23 => { name: :force_ai, type: :bool, default: false },          # 強制AI
            24 => { name: :strong_defence, type: :bool, default: false },    # 強力防御

            31 => { name: :status, type: :int16_array, order: [:max_hp, :max_mp, :atk, :def, :int, :agi] },

            41 => { name: :exp_basic, type: :int, default: -> { LCF.exp_default } },
            42 => { name: :exp_increase, type: :int, default: -> { LCF.exp_default } },
            43 => { name: :exp_correction, type: :int, default: -> { LCF.exp_default } },

            51 => { name: :initial_equipment, type: :int16_array, order: [:weapon, :shield, :armor, :helmet, :accessory] },

            56 => { name: :unarmed_animation, type: :int, default: 0 },      # 素手戦闘アニメID
            57 => { name: :class_id, type: :int, default: 0 },               # 職業ID (2003)
            59 => { name: :battle_x, type: :int, default: 0 },               # 手動配置X (2003)
            60 => { name: :battle_y, type: :int, default: 0 },               # 手動配置Y (2003)
            62 => { name: :battler_animation, type: :int, default: 0 },      # 戦闘アニメ (2003)
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
            15 => { name: :footstep, type: :string, default: '' },
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
        30 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E8%81%B7%E6%A5%AD
          name: :job, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            21 => { name: :double_hand, type: :bool, default: false },       # 二刀流
            22 => { name: :equipment_fixed, type: :bool, default: false },   # 装備固定
            23 => { name: :force_ai, type: :bool, default: false },          # 強制AI
            24 => { name: :strong_defence, type: :bool, default: false },    # 強力防御
            31 => { name: :parameters, type: :int16_array },                 # 能力値 (short[6][level])
            41 => { name: :exp_basic, type: :int, default: -> { LCF.exp_default } },
            42 => { name: :exp_increase, type: :int, default: -> { LCF.exp_default } },
            43 => { name: :exp_correction, type: :int, default: 0 },
            62 => { name: :battler_animation, type: :int, default: 1 },
            63 => { name: :skills, type: :Array2D, elements: LEARNING },
            71 => { name: :state_ranks_size, type: :int, default: 0 },
            72 => { name: :state_ranks, type: :int8_array },
            73 => { name: :attribute_ranks_size, type: :int, default: 0 },
            74 => { name: :attribute_ranks, type: :int8_array },
            80 => { name: :battle_commands, type: :int32_array },
          }
        },
        32 => {
          # https://wikiwiki.jp/viprpg-dev/200X%E5%85%B1%E9%80%9A/%E8%A7%A3%E6%9E%90%E3%81%BE%E3%81%A8%E3%82%81/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9/%E6%88%A6%E9%97%98%E3%82%A2%E3%83%8B%E3%83%A1%EF%BC%92
          name: :battle_anime2, type: :Array2D,
          elements: {
            1 => { name: :name, type: :string, default: '' },
            2 => { name: :attack_motion, type: :int, default: 0 },     # 攻撃モーション (2003)
            10 => {
              # 基本と拡張 — object list, 33 elements by default (2003).
              name: :base_data, type: :Array2D,
              elements: {
                1 => { name: :name, type: :string, default: '' },
                2 => { name: :battler_name, type: :string, default: '' },   # 戦闘(武器)グラフィック
                3 => { name: :battler_position, type: :int, default: 0 },   # グラフィック/位置
                # 戦闘アニメ. The wiki table's type/default cells are garbled
                # (形式 "0" / 省略時 "空文字列"); it holds the battle-animation id.
                4 => { name: :animation_id, type: :int, default: 0 },
                5 => { name: :extension, type: :int, default: 1 },          # 拡張
              }
            },
            11 => {
              # 武器 — object list, 33 elements by default (2003).
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
      8 => { name: :timer_sec, type: :int, default: 0 },
      # RPG2003-only: a second timer condition and the variable comparison
      # operator (0 = >=). The RPG2000 runtime always compares with >=, so these
      # are carried for schema completeness rather than consumed by EventPage.
      9 => { name: :timer2_sec, type: :int, default: 0 },
      10 => { name: :compare_operator, type: :int, default: 0 },
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
        # width * height signed shorts, one tile id per cell.
        71 => { name: :lower_layer, type: :int16_array },
        72 => { name: :upper_layer, type: :int16_array },
        81 => { name: :events, type: :Array2D, elements: MAP_EVENT },
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
      # 0 = down, 1 = right, 2 = up, 3 = left.
      22 => { name: :direction, type: :int },
      35 => { name: :animation_type, type: :int },
      37 => { name: :move_speed, type: :int },
      73 => { name: :charset_name, type: :string },
      75 => { name: :charset_index, type: :int },
    }

    # https://w.atwiki.jp/rpg2kpsp/pages/21.html
    #
    # Runtime state of a "show picture" command (chunk 103 of the save file),
    # one entry per picture number. The rpg2kpsp analysis only labels a subset
    # of the fields; the position/movement slots (2-5, 8, 11-14, 31, 32) hold
    # `double` coordinates whose exact meaning is undocumented, so only the
    # named fields are transcribed here.
    SAVE_PICTURE = {
      1 => { name: :name, type: :string },              # ピクチャグラフィックのファイル名
      9 => { name: :visible, type: :bool, default: false }, # 表示するか (0 非表示 / 1 表示)
      33 => { name: :zoom, type: :int },                # 拡大率
      34 => { name: :transparency, type: :int },        # 透明度
      41 => { name: :tone_red, type: :int },            # 色調：赤(R)
      42 => { name: :tone_green, type: :int },          # 色調：緑(G)
      43 => { name: :tone_blue, type: :int },           # 色調：青(B)
      44 => { name: :tone_saturation, type: :int },     # 色調：彩度(S)
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
    # the shield slot). Field 1 is the (renamable) name — the hero's stored name
    # matches the SAVE_TITLE hero_name exactly — but it is left unmodelled here
    # because the runtime resolves names from the database and reserve actors
    # store only a placeholder. Fields 2/33/34 are single bytes that are constant
    # in the sampled save, so their meaning is not yet provable.
    SAVE_PARTY_ACTOR = {
      31 => { name: :level, type: :int, default: 1 },      # レベル
      32 => { name: :exp, type: :int, default: 0 },        # 経験値
      51 => { name: :skill_size, type: :int, default: 0 }, # 『特技』情報のデータ数
      52 => { name: :skills, type: :int16_array },         # 習得特技 (uint16[])
      61 => { name: :equipment, type: :int16_array },      # 装備 [武器,盾,鎧,兜,装飾]
      71 => { name: :hp, type: :int },                     # 現在ＨＰ
      72 => { name: :mp, type: :int },                     # 現在ＭＰ
      81 => { name: :state_size, type: :int, default: 0 }, # 『状態』情報のデータ数
      82 => { name: :states, type: :int16_array },         # 『状態』情報 (uint16[])
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
    # the chipset replacement tables. A real save also carries two leading int
    # fields (1, 2) -- the map scroll/pan position -- left undecoded until
    # differential saves pin the units down.
    SAVE_MAP_EVENT = {
      11 => { name: :events, type: :Array2D, elements: SAVE_MOVABLE },
      21 => { name: :chip_replacement_lower, type: :int8_array }, # uint8[144]
      22 => { name: :chip_replacement_upper, type: :int8_array }, # uint8[144]
    }

    # Party inventory (chunk 109 of the save file). Confirmed against a real
    # save: gold (21) matched the on-screen 100G, and the parallel item id/count
    # arrays matched the held items looked up in the database -- 薬草 (item 1) ×3
    # and 導きの書 (item 451) ×1, after the gate crystal had been spent. Item ids
    # are int16; counts and per-item use-counts are one byte each. Field 1 is the
    # party roster (actor ids); the sole entry `[1]` is actor 1, whose database
    # charset matches the saved hero. The step/turn counters are left out until
    # confirmed.
    SAVE_INVENTORY = {
      1 => { name: :party, type: :int8_array },
      11 => { name: :item_count, type: :int, default: 0 },
      12 => { name: :item_ids, type: :int16_array },
      13 => { name: :item_counts, type: :int8_array },
      14 => { name: :item_usage, type: :int8_array },
      21 => { name: :gold, type: :int, default: 0 },
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
      15 => { name: :system_graphic, type: :string },
      16 => { name: :wallpaper_type, type: :int },
      17 => { name: :font, type: :int },
      31 => { name: :switch_size, type: :int, default: 0 },
      32 => { name: :switches, type: :bool_array },
      33 => { name: :variable_size, type: :int, default: 0 },
      34 => { name: :variables, type: :int32_array },
      # 0 = normal, 1 = transparent.
      41 => { name: :message_transparent, type: :int, default: 0 },
      # 0 = top, 1 = middle, 2 = bottom.
      42 => { name: :message_position, type: :int, default: 2 },
      43 => { name: :message_prevent_overlap, type: :bool, default: true },
      44 => { name: :message_continue_events, type: :bool, default: false },
      51 => { name: :face_name, type: :string, default: '' },
      52 => { name: :face_index, type: :int, default: 0 },
      53 => { name: :face_right_position, type: :int, default: 0 },
      54 => { name: :face_flip, type: :bool, default: false },
      55 => { name: :transparent, type: :bool, default: false },
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

    # https://w.atwiki.jp/rpg2kpsp/pages/13.html documents the LcfSaveData chunk
    # map. Chunks 109 (inventory) and 114 (common-event state), still marked
    # unanalysed on that wiki, were identified against a real Save01.lsd (see
    # ADR 0011). Chunk 102 (screen effects), 112 (a one-byte flag) and 200 (a
    # non-standard high-id extension chunk) are still left out until confirmed.
    SAVE_DATA = {
      name: :Save, type: :Array1D,
      elements: {
        100 => { name: :title, type: :Array1D, elements: SAVE_TITLE },
        101 => { name: :system, type: :Array1D, elements: SAVE_SYSTEM },
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
    def initialize io
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

    # Serialise the whole file back to bytes: the BER-length-prefixed header
    # string followed by the root object's own serialisation. The inverse of
    # #initialize; a file read and written back without edits reproduces it
    # byte-for-byte. The top-level chunk list runs to EOF with no terminator
    # (matching a real .lsd), so the root Array1D is serialised with
    # terminate=false. Multi-section (Array-schema) files are not yet writable.
    def to_lcf
      raise 'section-based file serialization not implemented' if schema.is_a? Array
      root = @root.is_a?(LCF::Array1D) ? @root.to_lcf(false) : @root.to_lcf
      out = String.new << LCF.write_ber(header.bytesize)
      out << LCF.binstr(header) << LCF.binstr(root)
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
  end

  class SaveData < File
    def header; "LcfSaveData" end
    def schema; LCF::Schema::SAVE_DATA end
  end
end

# frozen_string_literal: true

# The closed build's unregistration list: the names static_dispatch_unregistered.rb
# lists, plus those no Ruby test, scripts/ or tools/ file references either
# (static_dispatch_registrations.rb --closed-only). Only the closed build reads
# it (static_dispatch_unregistered_for). Regenerate with
# `MRBC=... ruby tools/bc2cpp/static_dispatch_registrations.rb --closed-only --write`.
require 'set'

STATIC_DISPATCH_UNREGISTERED_CLOSED = Set[
  "Game::Actor#exp_to_next",
  "Game::Battle#force_flee?",
  "Game::Battle#pop_ready",
  "Game::Battle#run_round",
  "Game::CommonEvent.singleton#eligible",
  "Game::Party#actor_by_id",
  "Game::Party#item_effective?",
  "Game::Party#skill_effective?",
  "Game::Party#unsupported_field_skill?",
  "Game::Screen#fade_transition",
  "Game::State#timer_display_text",
  "Game::State#timer_frames",
  "Game::State#timer_frames=",
  "Game::State#timer_running=",
  "Game::State#timer_visible",
  "Game::State#timer_visible=",
  "Game::TextReveal#visible_lines",
  "Game::Transition.singleton#block_grid",
  "LCF::Array2D#same_schema?",
  "RPG2k::Scene::EquipMenu#equip_delta",
  "RPG2k::Scene::EquipMenu#item_stat_sum",
  "RPG2k::Scene::Map#invalidate_tile_cache",
  "RPG2k::Scene::Map::LRUBitmapCache#bitmap_bytes",
  "RPG2k::Scene::Map::LRUBitmapCache#evict_lru_until_within_budget",
].freeze

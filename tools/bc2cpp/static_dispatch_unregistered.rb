# frozen_string_literal: true

# Compiled entry points whose mrb_define_method registration is deliberately
# NOT emitted: every one is proven, by tools/bc2cpp/static_dispatch_
# registrations.rb, to be a name no runtime method-table lookup can ever reach
# -- every real caller is a direct `Owner_name_impl(...)` call in generated
# C++.
#
# Read by bc2cpp.rb's emit_owner_registrations (generated registration for
# BC2CPP_WIRED_EMBEDDINGS owners), by scripts/bc2cpp/prune_static_dispatch_registrations.rb
# (the hand-written register.cxx lines). A later change that adds a dynamic reference
# to any name here would ship a NoMethodError, so no such reference may be added. Regenerate with
# `MRBC=... ruby tools/bc2cpp/static_dispatch_registrations.rb --write`.
require 'set'
require_relative 'static_dispatch_unregistered_closed'

STATIC_DISPATCH_UNREGISTERED = Set[
  "RPG2k::Scene::EquipMenu#item_stat_sum",
  "RPG2k::Scene::Map::LRUBitmapCache#bitmap_bytes",
  "RPG2k::Scene::Map::LRUBitmapCache#evict_lru_until_within_budget",
].freeze

# The list for a build: only the closed build drops the closed-only names.
def static_dispatch_unregistered_for(build_name)
  build_name == 'closed' ? STATIC_DISPATCH_UNREGISTERED_CLOSED : STATIC_DISPATCH_UNREGISTERED
end

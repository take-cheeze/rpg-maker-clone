- RPG Maker 2000 item menu: **seeds** (database item type 8) are now usable
  alongside medicines and skill books. Choosing a seed prompts for an ally and
  permanently raises that ally's base stats, then consumes one seed. The boosts
  come from the item's `max_hp_points` / `max_sp_points` and the **`*_points2`**
  stat set (attack/defence/spirit/agility) — the set RPG2000 seeds use, distinct
  from the `*_points1` equipment bonuses (confirmed directly against genuine
  RPG_RT.exe under wine: a real shipped seed item duplicated with its
  `*_points1` field additionally set produced an identical stat gain either
  way, ruling that field out) — and are applied through
  `Game::Actor#change_param`, so the
  RPG2000 stat caps hold. `Game::Party#use_item` gains a `use_seed` branch, and
  `field_usable?` / `item_effective?` account for seeds (a seed with no boost is
  ineffective and not consumed), with two new checks in
  `scripts/rpg2k_logic_check.rb`. Switch (type 9) item use remains a follow-up.
